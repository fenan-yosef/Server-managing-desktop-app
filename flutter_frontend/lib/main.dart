import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter + Python IPC demo',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Process? _proc;
  final List<String> _logs = [];
  StreamSubscription<String>? _outSub;

  void _log(String s) {
    setState(() {
      _logs.add(s);
    });
  }

  Future<void> _startBackend() async {
    if (_proc != null) return;

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
        _log('Trying to start: ${[executable, ...args].join(' ')}');
        final proc = await Process.start(
          executable,
          args,
          runInShell: true,
          mode: ProcessStartMode.detachedWithStdio,
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
          _log('Backend started: ${executable}');
          return;
        }
      } catch (e) {
        _log('Start failed: $e');
      }
    }
    _log(
      'Unable to start backend; ensure backend/backend_cli.py or backend_cli.exe is available.',
    );
  }

  void _attachListeners(Process proc) {
    _outSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log('OUT: $line'));
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _log('ERR: $line'));
    proc.exitCode.then((code) {
      _log('Backend exited with code $code');
      _proc = null;
      _outSub?.cancel();
      _outSub = null;
    });
  }

  void _send(String msg) {
    if (_proc == null) {
      _log('No backend process');
      return;
    }
    _proc!.stdin.writeln(msg);
    _log('SENT: $msg');
  }

  Future<void> _stopBackend() async {
    if (_proc == null) return;
    try {
      _proc!.stdin.writeln('quit');
    } catch (e) {
      // fallback
      _proc!.kill(ProcessSignal.sigkill);
    }
  }

  @override
  void dispose() {
    _stopBackend();
    _outSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter ↔ Python IPC demo')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              children: [
                ElevatedButton(
                  onPressed: _startBackend,
                  child: const Text('Start Backend'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _send('ping'),
                  child: const Text('Ping'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _send('time'),
                  child: const Text('Time'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _stopBackend,
                  child: const Text('Stop Backend'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (c, i) => Padding(
                    padding: const EdgeInsets.all(6.0),
                    child: Text(_logs[i]),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
