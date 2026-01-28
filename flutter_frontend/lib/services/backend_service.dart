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
    if (_proc != null || _socket != null) return;

    // First try to connect to existing backend socket
    try {
      onLog?.call('Trying socket connect to 127.0.0.1:8765');
      final s = await Socket.connect(
        '127.0.0.1',
        8765,
        timeout: const Duration(milliseconds: 2000),
      );
      onLog?.call('Connected to backend socket');
      _socket = s;
      _attachSocketListeners(s);
      return;
    } catch (e) {
      onLog?.call('Socket connect failed: $e');
    }

    // Try a few startup options so this sample works during development
    // and after packaging.
    List<List<String>> candidates = [
      // packaged exe next to frontend
      ['backend_cli.exe'],
      // run via python interpreter (dev)
      ['python', '..\\backend\\backend_cli.py'],
      ['python3', '..\\backend\\backend_cli.py'],
    ];

    for (final cmd in candidates) {
      try {
        final executable = cmd.first;
        final args = cmd.length > 1 ? cmd.sublist(1) : <String>[];
        onLog?.call('Trying to start: ${[executable, ...args].join(' ')}');
        final proc = await Process.start(
          executable,
          args,
          runInShell: true,
          mode: ProcessStartMode.normal,
        );

        // If we started an executable but it already exited immediately, skip
        if (await proc.exitCode.timeout(
              const Duration(milliseconds: 200),
              onTimeout: () => -1,
            ) ==
            -1) {
          // still running
          _proc = proc;
          _attachListeners(proc);
          onLog?.call('Backend started: ${executable}');
          return;
        }
      } catch (e) {
        onLog?.call('Start failed: $e');
      }
    }
    onLog?.call(
      'Unable to start backend; ensure backend/backend_cli.py or backend_cli.exe is available.',
    );
  }

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

  void _attachListeners(Process proc) {
    _outSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => onLog?.call('OUT: $line'));
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => onLog?.call('ERR: $line'));
    proc.exitCode.then((code) {
      onLog?.call('Backend exited with code $code');
      _proc = null;
      _outSub?.cancel();
      _outSub = null;
    });
  }

  Future<void> stopBackend() async {
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
