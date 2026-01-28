import 'dart:async';
import 'dart:convert';
import 'dart:io';

class BackendService {
  Process? _proc;
  Socket? _socket;
  final List<String> _logs = [];
  StreamSubscription<String>? _outSub;

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  void Function(String)? onLog;

  BackendService({this.onLog});

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
      onLog?.call('Connected to existing backend');
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
        onLog?.call('Connected to backend socket');
        _socket = s;
        _attachSocketListeners(s);
        return;
      } catch (_) {
        onLog?.call('Waiting for backend socket...');
      }
    }
    throw 'Failed to connect to backend socket after spawn';
  }

  Future<void> _spawnProcess() async {
    onLog?.call('Current Directory: ${Directory.current.path}');

    // Try to discover a project virtualenv by walking up the directory tree.
    final List<List<String>> candidates = [];
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final venvPath =
          '${dir.path}${Platform.pathSeparator}.venv${Platform.pathSeparator}Scripts${Platform.pathSeparator}python.exe';
      final backendPath =
          '${dir.path}${Platform.pathSeparator}backend${Platform.pathSeparator}backend_cli.py';
      if (File(venvPath).existsSync() && File(backendPath).existsSync()) {
        onLog?.call('Discovered venv python: $venvPath');
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
        onLog?.call(
          'Starting backend candidate: $executable ${args.join(' ')}',
        );

        // Check if executable exists if it's a relative path
        if (executable.contains(Platform.pathSeparator) ||
            executable.contains('/') ||
            executable.contains('\\')) {
          final exists = await File(executable).exists();
          if (!exists) {
            onLog?.call('Executable not found: $executable');
            continue;
          }
        }

        final proc = await Process.start(
          executable,
          args,
          runInShell: true,
          mode: ProcessStartMode.normal,
          workingDirectory:
              Directory.current.path, // ensure we are in frontend root
        );

        // Listen to stdout/stderr immediately to catch startup errors
        proc.stdout
            .transform(utf8.decoder)
            .listen((line) => onLog?.call('[BACKEND OUT] $line'));
        proc.stderr
            .transform(utf8.decoder)
            .listen((line) => onLog?.call('[BACKEND ERR] $line'));

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
            onLog?.call('Backend exited with code $code');
            _proc = null;
            _socket?.destroy();
            _socket = null;
          });
          onLog?.call('Backend process started successfully.');
          return;
        } else {
          onLog?.call('Backend process exited immediately with code $exitCode');
          _proc = null; // Clean up
        }
      } catch (e) {
        onLog?.call('Failed to start candidate $cmd: $e');
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
            onLog?.call('SOCK IN: ${obj}');
            final id = obj['id'];
            if (id != null && _pending.containsKey(id)) {
              _pending.remove(id)!.complete(obj);
            }
          } catch (e) {
            onLog?.call('SOCK PARSE ERR: $e');
          }
        }
      },
      onDone: () {
        onLog?.call('Socket closed');
        _socket = null;
      },
      onError: (e) {
        onLog?.call('Socket error: $e');
        _socket = null;
      },
    );
  }

  Future<dynamic> sendCommand(String cmd, [dynamic params]) async {
    if (_socket == null) throw 'no socket';
    final id = _nextId++;
    final msg = {'id': id, 'cmd': cmd, 'params': params};
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final data = json.encode(msg) + '\n';
    _socket!.add(utf8.encode(data));
    onLog?.call('SOCK OUT: $msg');
    return completer.future.timeout(const Duration(seconds: 5));
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
    _outSub?.cancel();
  }
}
