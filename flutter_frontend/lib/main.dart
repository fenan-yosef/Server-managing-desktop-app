import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
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

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  Process? _proc;
  Socket? _socket;
  final List<String> _logs = [];
  StreamSubscription<String>? _outSub;

  int _nextId = 1;
  final Map<int, Completer<dynamic>> _pending = {};

  late TabController _tabController;

  // Login
  final _hostController = TextEditingController(text: 'localhost');
  final _portController = TextEditingController(text: '22');
  final _userController = TextEditingController();
  final _keyController = TextEditingController();
  final _passController = TextEditingController();
  String _loginStatus = 'Disconnected';

  // Explorer
  final _pathController = TextEditingController(text: '/');
  List<Map<String, dynamic>> _explorerEntries = [];

  // Backup
  final _remoteController = TextEditingController(text: '/var/data');
  final _localController = TextEditingController(text: 'backups');
  String _mode = 'rsync (resumable)';
  double _progress = 0.0;
  final List<String> _backupLogs = [];

  // Jobs
  List<Map<String, dynamic>> _jobs = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _keyController.dispose();
    _passController.dispose();
    _pathController.dispose();
    _remoteController.dispose();
    _localController.dispose();
    _stopBackend();
    _outSub?.cancel();
    super.dispose();
  }

  void _log(String s) {
    setState(() {
      _logs.add(s);
    });
  }

  Future<void> _startBackend() async {
    if (_proc != null || _socket != null) return;

    // First try to connect to existing backend socket
    try {
      _log('Trying socket connect to 127.0.0.1:8765');
      final s = await Socket.connect(
        '127.0.0.1',
        8765,
        timeout: const Duration(milliseconds: 2000),
      );
      _log('Connected to backend socket');
      _socket = s;
      _attachSocketListeners(s);
      return;
    } catch (e) {
      _log('Socket connect failed: $e');
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
        _log('Trying to start: ${[executable, ...args].join(' ')}');
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
            _log('SOCK IN: ${obj}');
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

  Future<dynamic> _sendSocketCommand(String cmd, [dynamic params]) async {
    if (_socket == null) throw 'no socket';
    final id = _nextId++;
    final msg = {'id': id, 'cmd': cmd, 'params': params};
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final data = json.encode(msg) + '\n';
    _socket!.add(utf8.encode(data));
    _log('SOCK OUT: $msg');
    return completer.future.timeout(const Duration(seconds: 5));
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
    if (_socket != null) {
      // send as simple echo command over socket
      _sendSocketCommand('echo', msg)
          .then((r) => _log('SOCK RESP: $r'))
          .catchError((e) => _log('SOCK ERR: $e'));
      return;
    }
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Server Backup (Flutter)'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Login'),
            Tab(text: 'Explorer'),
            Tab(text: 'Backup'),
            Tab(text: 'Jobs'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildLoginTab(),
          _buildExplorerTab(),
          _buildBackupTab(),
          _buildJobsTab(),
        ],
      ),
    );
  }

  Widget _buildLoginTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: _hostController,
            decoration: const InputDecoration(labelText: 'Host'),
          ),
          TextField(
            controller: _portController,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: _userController,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keyController,
                  decoration: const InputDecoration(labelText: 'SSH Key'),
                ),
              ),
              IconButton(onPressed: _browseKey, icon: const Icon(Icons.folder)),
            ],
          ),
          TextField(
            controller: _passController,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
          ),
          Row(
            children: [
              ElevatedButton(onPressed: _connect, child: const Text('Connect')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _disconnect,
                child: const Text('Disconnect'),
              ),
            ],
          ),
          Text(_loginStatus),
        ],
      ),
    );
  }

  Future<void> _browseKey() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      _keyController.text = result.files.single.path!;
    }
  }

  Future<void> _connect() async {
    final host = _hostController.text;
    final port = int.tryParse(_portController.text) ?? 22;
    final user = _userController.text;
    final pass = _passController.text;
    final key = _keyController.text;
    try {
      final result = await _sendSocketCommand('connect', {
        'host': host,
        'port': port,
        'username': user,
        'key_path': key,
        'password': pass,
      });
      setState(() {
        _loginStatus = 'Connected';
      });
      _log('Connected');
    } catch (e) {
      setState(() {
        _loginStatus = 'Connection failed: $e';
      });
      _log('Connection failed: $e');
    }
  }

  Future<void> _disconnect() async {
    try {
      await _sendSocketCommand('disconnect', {});
      setState(() {
        _loginStatus = 'Disconnected';
      });
      _log('Disconnected');
    } catch (e) {
      _log('Disconnect error: $e');
    }
  }

  Widget _buildExplorerTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathController,
                  decoration: const InputDecoration(labelText: 'Path'),
                  onSubmitted: (_) => _refreshExplorer(),
                ),
              ),
              IconButton(
                onPressed: _refreshExplorer,
                icon: const Icon(Icons.refresh),
              ),
              IconButton(
                onPressed: _upExplorer,
                icon: const Icon(Icons.arrow_upward),
              ),
              ElevatedButton(
                onPressed: _useForBackup,
                child: const Text('Use as Source'),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _explorerEntries.length,
              itemBuilder: (c, i) {
                final entry = _explorerEntries[i];
                return ListTile(
                  leading: Icon(
                    entry['is_dir'] ? Icons.folder : Icons.insert_drive_file,
                  ),
                  title: Text(entry['name']),
                  subtitle: Text(
                    entry['is_dir'] ? 'DIR' : '${entry['size']} bytes',
                  ),
                  onTap: () => _selectEntry(entry),
                );
              },
            ),
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: _mkdir,
                child: const Text('New Folder'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _rename, child: const Text('Rename')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _delete, child: const Text('Delete')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _upload, child: const Text('Upload')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _download,
                child: const Text('Download'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _refreshExplorer() async {
    final path = _pathController.text;
    try {
      final result = await _sendSocketCommand('list_dir', {'path': path});
      setState(() {
        _explorerEntries = List<Map<String, dynamic>>.from(
          result['result'].map(
            (e) => {'name': e[0], 'is_dir': e[1], 'size': e[2]},
          ),
        );
      });
    } catch (e) {
      _log('List dir failed: $e');
    }
  }

  void _upExplorer() {
    final path = _pathController.text;
    final newPath = path == '/'
        ? '/'
        : (path.substring(0, path.lastIndexOf('/')) ?? '/');
    _pathController.text = newPath;
    _refreshExplorer();
  }

  void _selectEntry(Map<String, dynamic> entry) {
    if (entry['is_dir']) {
      final current = _pathController.text;
      final newPath = current == '/'
          ? '/${entry['name']}'
          : '$current/${entry['name']}';
      _pathController.text = newPath;
      _refreshExplorer();
    }
  }

  void _useForBackup() {
    final item = _explorerEntries.firstWhere(
      (e) => e['is_dir'],
      orElse: () => {},
    );
    if (item.isNotEmpty) {
      _remoteController.text = '${_pathController.text}/${item['name']}';
      _tabController.animateTo(2); // go to backup tab
    }
  }

  Future<void> _mkdir() async {
    final name = await _showInputDialog('New Folder Name', 'new_folder');
    if (name != null) {
      final path = '${_pathController.text}/$name';
      try {
        await _sendSocketCommand('make_dir', {'path': path});
        _refreshExplorer();
      } catch (e) {
        _log('Mkdir failed: $e');
      }
    }
  }

  Future<void> _rename() async {
    final item = _explorerEntries.firstWhere((e) => true, orElse: () => {});
    if (item.isNotEmpty) {
      final newName = await _showInputDialog('New Name', item['name']);
      if (newName != null) {
        final oldPath = '${_pathController.text}/${item['name']}';
        final newPath = '${_pathController.text}/$newName';
        try {
          await _sendSocketCommand('rename', {
            'old_path': oldPath,
            'new_path': newPath,
          });
          _refreshExplorer();
        } catch (e) {
          _log('Rename failed: $e');
        }
      }
    }
  }

  Future<void> _delete() async {
    final item = _explorerEntries.firstWhere((e) => true, orElse: () => {});
    if (item.isNotEmpty) {
      final confirmed = await _showConfirmDialog('Delete ${item['name']}?');
      if (confirmed) {
        final path = '${_pathController.text}/${item['name']}';
        try {
          await _sendSocketCommand('delete', {'path': path});
          _refreshExplorer();
        } catch (e) {
          _log('Delete failed: $e');
        }
      }
    }
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      final file = result.files.single;
      final localPath = file.path!;
      final remotePath = '${_pathController.text}/${file.name}';
      try {
        await _sendSocketCommand('upload', {
          'local_path': localPath,
          'remote_path': remotePath,
        });
        _refreshExplorer();
      } catch (e) {
        _log('Upload failed: $e');
      }
    }
  }

  Future<void> _download() async {
    final item = _explorerEntries.firstWhere(
      (e) => !e['is_dir'],
      orElse: () => {},
    );
    if (item.isNotEmpty) {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save As',
        fileName: item['name'],
      );
      if (result != null) {
        final remotePath = '${_pathController.text}/${item['name']}';
        try {
          await _sendSocketCommand('download', {
            'remote_path': remotePath,
            'local_path': result,
          });
        } catch (e) {
          _log('Download failed: $e');
        }
      }
    }
  }

  Widget _buildBackupTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: _remoteController,
            decoration: const InputDecoration(
              labelText: 'Remote source (Linux)',
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _localController,
                  decoration: const InputDecoration(
                    labelText: 'Local backup root',
                  ),
                ),
              ),
              IconButton(
                onPressed: _browseLocal,
                icon: const Icon(Icons.folder),
              ),
            ],
          ),
          DropdownButton<String>(
            value: _mode,
            items: [
              'rsync (resumable)',
              'tar.gz (single archive)',
            ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) => setState(() => _mode = v!),
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: _startBackup,
                child: const Text('Start Backup'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _pauseBackup,
                child: const Text('Pause'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _resumeBackup,
                child: const Text('Resume'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _cancelBackup,
                child: const Text('Cancel'),
              ),
            ],
          ),
          LinearProgressIndicator(value: _progress / 100),
          Expanded(
            child: ListView.builder(
              itemCount: _backupLogs.length,
              itemBuilder: (c, i) => Text(_backupLogs[i]),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _browseLocal() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      _localController.text = result;
    }
  }

  Future<void> _startBackup() async {
    final remote = _remoteController.text;
    final local = _localController.text;
    final mode = _mode.startsWith('rsync') ? 'rsync' : 'tar';
    _addBackupLog('Starting backup from $remote to $local with $mode');
    // TODO: implement start_backup command
  }

  void _pauseBackup() {
    _addBackupLog('Pause not implemented');
  }

  void _resumeBackup() {
    _addBackupLog('Resume not implemented');
  }

  void _cancelBackup() {
    _addBackupLog('Cancel not implemented');
  }

  void _addBackupLog(String msg) {
    setState(() {
      _backupLogs.add(msg);
    });
  }

  Widget _buildJobsTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _jobs.length,
              itemBuilder: (c, i) {
                final job = _jobs[i];
                return ListTile(
                  title: Text(job['job_id']),
                  subtitle: Text(
                    '${job['status']} | ${job['phase']} | ${job['progress']}% | ${job['mode']}',
                  ),
                );
              },
            ),
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: _refreshJobs,
                child: const Text('Refresh'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _resumeJob,
                child: const Text('Resume Selected'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _deleteJob,
                child: const Text('Delete Selected'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _refreshJobs() async {
    try {
      final result = await _sendSocketCommand('list_jobs', {});
      setState(() {
        _jobs = List<Map<String, dynamic>>.from(result['result']);
      });
    } catch (e) {
      _log('List jobs failed: $e');
    }
  }

  void _resumeJob() {
    // TODO: implement
  }

  void _deleteJob() {
    // TODO: implement
  }

  Future<String?> _showInputDialog(String title, String initial) async {
    String? result;
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          onChanged: (v) => result = v,
          controller: TextEditingController(text: initial),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, result),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return result;
  }

  Future<bool> _showConfirmDialog(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Confirm'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
