import 'dart:async';
import 'dart:convert';
import 'dart:io';

class BackendService {
  Process? _proc;
  Socket? _socket;
  final List<String> _logs = [];
  IOSink? _logSink;

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  void Function(String)? onLog;

  BackendService({this.onLog});

  void _log(String message) {
    final stamp = DateTime.now().toIso8601String();
    final line = '[$stamp] $message';
    _logs.add(line);
    onLog?.call(line);
    // Always print to terminal when available.
    // ignore: avoid_print
    print(line);
    try {
      _logSink ??= File(
        '${Directory.current.path}${Platform.pathSeparator}backend_service.log',
      ).openWrite(mode: FileMode.append);
      _logSink!.writeln(line);
      _logSink!.flush();
    } catch (_) {}
  }

  Future<void> startBackend() async {
    // 1. If socket is already connected, we are good.
    if (_socket != null) return;

    // 2. Try to connect to existing backend (if running from previous session or standalone)
    try {
      final s = await Socket.connect(
        '127.0.0.1',
        8765,
        timeout: const Duration(milliseconds: 500),
      );
      _log('Connected to existing backend');
      _socket = s;
      _attachSocketListeners(s);
      return;
    } catch (_) {}

    // 3. If process isn't running, start it
    if (_proc == null) {
      await _spawnProcess();
    }

    // 4. Loop until socket connects (wait for backend to initialize)
    for (var i = 0; i < 20; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 500));
        final s = await Socket.connect(
          '127.0.0.1',
          8765,
          timeout: const Duration(milliseconds: 1000),
        );
        _log('Connected to backend socket');
        _socket = s;
        _attachSocketListeners(s);
        return;
      } catch (_) {
        _log('Waiting for backend socket...');
      }
    }
    throw 'Failed to connect to backend socket after spawn';
  }

  Future<void> _spawnProcess() async {
    _log('Current Directory: ${Directory.current.path}');

    // Try to discover a project virtualenv by walking up the directory tree.
    final List<List<String>> candidates = [];
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final venvPath =
          '${dir.path}${Platform.pathSeparator}.venv${Platform.pathSeparator}Scripts${Platform.pathSeparator}python.exe';
      final backendPath =
          '${dir.path}${Platform.pathSeparator}backend${Platform.pathSeparator}backend_cli.py';
      if (File(venvPath).existsSync() && File(backendPath).existsSync()) {
        _log('Discovered venv python: $venvPath');
        candidates.add([venvPath, backendPath]);
        break;
      }
      // move up
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }

    // Add reasonable fallbacks (relative to common CWD choices)
    candidates.addAll([
      ['.venv\\Scripts\\python.exe', 'backend\\backend_cli.py'],
      ['..\\.venv\\Scripts\\python.exe', '..\\backend\\backend_cli.py'],
      ['python', 'backend\\backend_cli.py'],
      ['python', '..\\backend\\backend_cli.py'],
      ['backend_cli.exe'],
      ['python3', 'backend\\backend_cli.py'],
      ['python3', '..\\backend\\backend_cli.py'],
    ]);

    for (final cmd in candidates) {
      try {
        final executable = cmd.first;
        final args = cmd.length > 1 ? cmd.sublist(1) : <String>[];
        _log('Starting backend candidate: $executable ${args.join(' ')}');

        // Check if executable exists if it's a relative path
        if (executable.contains(Platform.pathSeparator) ||
            executable.contains('/') ||
            executable.contains('\\')) {
          final exists = await File(executable).exists();
          if (!exists) {
            _log('Executable not found: $executable');
            continue;
          }
        }

        // Compute a working directory so the backend can import project modules
        var workDir = Directory.current.path;
        try {
          if (args.isNotEmpty) {
            final candidate = File(args[0]);
            if (candidate.existsSync()) {
              // backend_cli.py is usually in <repo>/backend/backend_cli.py
              // set working dir to repo root (parent of backend)
              workDir = candidate.parent.parent.path;
            } else if (candidate.absolute.existsSync()) {
              workDir = candidate.absolute.parent.parent.path;
            }
          }
        } catch (_) {}
        _log('Using workingDirectory: $workDir');

        final proc = await Process.start(
          executable,
          args,
          runInShell: true,
          mode: ProcessStartMode.normal,
          workingDirectory: workDir,
        );

        // Listen to stdout/stderr immediately to catch startup errors
        proc.stdout
            .transform(utf8.decoder)
            .listen((line) => _log('[BACKEND OUT] $line'));
        proc.stderr
            .transform(utf8.decoder)
            .listen((line) => _log('[BACKEND ERR] $line'));

        // Check if it crashes immediately (increased timeout)
        final exitCode = await proc.exitCode.timeout(
          const Duration(milliseconds: 1000),
          onTimeout: () => -1,
        );

        if (exitCode == -1) {
          // still running
          _proc = proc;
          // output listeners are already attached above, but we need to track exit
          proc.exitCode.then((code) {
            _log('Backend exited with code $code');
            _proc = null;
            _socket?.destroy();
            _socket = null;
          });
          _log('Backend process started successfully.');
          return;
        } else {
          _log('Backend process exited immediately with code $exitCode');
          _proc = null; // Clean up
        }
      } catch (e) {
        _log('Failed to start candidate $cmd: $e');
      }
    }
    throw 'Could not spawn any backend candidate. Check logs for details.';
  }

  // Old _attachListeners is now integrated into _spawnProcess
  // leaving _attachSocketListeners as is
  void _attachSocketListeners(Socket s) {
    var buffer = '';
    s.listen(
      (bytes) {
        final text = utf8.decode(bytes);
        buffer += text;
        while (buffer.contains('\n')) {
          final idx = buffer.indexOf('\n');
          final line = buffer.substring(0, idx).trim();
          buffer = buffer.substring(idx + 1);
          if (line.isEmpty) continue;
          try {
            final obj = json.decode(line);
            _log('SOCK IN: $obj');
            final id = obj['id'];
            if (id != null && _pending.containsKey(id)) {
              _pending.remove(id)!.complete(obj);
            }
          } catch (e) {
            _log('SOCK PARSE ERR: $e');
          }
        }
      },
      onDone: () {
        _log('Socket closed');
        _socket = null;
      },
      onError: (e) {
        _log('Socket error: $e');
        _socket = null;
      },
    );
  }

  Future<dynamic> sendCommand(
    String cmd, [
    dynamic params,
    Duration timeout = const Duration(seconds: 5),
  ]) async {
    if (_socket == null) throw 'no socket';
    final id = _nextId++;
    final msg = {'id': id, 'cmd': cmd, 'params': params};
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final data = '${json.encode(msg)}\n';
    _socket!.add(utf8.encode(data));
    _log('SOCK OUT: $msg');
    // Allow long-running commands to opt into a longer timeout.
    return completer.future.timeout(timeout);
  }

  Future<void> stopBackend() async {
    _socket?.destroy(); // Close socket immediately
    _socket = null;

    if (_proc == null) return;
    try {
      _proc!.stdin.writeln('quit');
    } catch (e) {
      // fallback
      _proc!.kill(ProcessSignal.sigkill);
    }
  }

  void dispose() {
    stopBackend();
    _logSink?.flush();
    _logSink?.close();
  }
}
