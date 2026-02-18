import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'services/backend_service.dart';
import 'tabs/explorer_tab.dart';
import 'tabs/backup_tab.dart';
import 'tabs/jobs_tab.dart';
import 'utils/dialogs.dart';
import 'services/login_history.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BackendService _backend = BackendService();
  final List<String> _logs = [];

  final LoginHistoryStore _loginHistoryStore = LoginHistoryStore();
  List<LoginProfile> _recentLogins = [];

  bool _isBusy = false;
  String? _busyLabel;

  int _selectedIndex = 0;

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
  final _remoteController = TextEditingController();
  final _localController = TextEditingController();
  String _mode = 'rsync (resumable)';
  double _progress = 0.0;
  final List<String> _backupLogs = [];
  bool _obscurePasswordAdd = true;
  bool _obscurePasswordEdit = true;
  final List<BackupServerConfig> _batchServers = [];
  int _perHostLimit = 1;

  // Jobs
  List<Map<String, dynamic>> _jobs = [];

  @override
  void initState() {
    super.initState();
    _backend.onLog = (msg) => setState(() => _logs.add(msg));
    // Do not start backend here. It starts on 'Connect'.
    _loadRecentLogins();
    _batchServers.add(_newServerConfig());
  }

  Future<void> _loadRecentLogins() async {
    final loaded = await _loginHistoryStore.load();
    if (!mounted) return;
    setState(() => _recentLogins = loaded);
  }

  BackupServerConfig _newServerConfig() {
    return BackupServerConfig(
      hostController: TextEditingController(text: _hostController.text),
      portController: TextEditingController(text: _portController.text),
      userController: TextEditingController(text: _userController.text),
      passwordController: TextEditingController(),
      keyController: TextEditingController(text: _keyController.text),
      remotePathController: TextEditingController(text: '/'),
    );
  }

  void _addBatchServer() {
    _showServerDialog();
  }

  Future<void> _editBatchServer(int index) async {
    if (index < 0 || index >= _batchServers.length) return;
    final cfg = _batchServers[index];

    final hostC = TextEditingController(text: cfg.hostController.text);
    final portC = TextEditingController(text: cfg.portController.text);
    final userC = TextEditingController(text: cfg.userController.text);
    final keyC = TextEditingController(text: cfg.keyController.text);
    final passC = TextEditingController(text: cfg.passwordController.text);
    final remoteC = TextEditingController(text: cfg.remotePathController.text);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Container(
            width: 520,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Edit Server',
                  style: Theme.of(ctx).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: hostC,
                        decoration: const InputDecoration(labelText: 'Host'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: portC,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: userC,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: keyC,
                        decoration: const InputDecoration(
                          labelText: 'SSH Key (Optional)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () => _browseKey(keyC),
                      icon: const Icon(Icons.folder),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passC,
                  decoration: InputDecoration(
                    labelText: 'Password (Optional)',
                    suffixIcon: IconButton(
                      onPressed: () => setState(
                        () => _obscurePasswordEdit = !_obscurePasswordEdit,
                      ),
                      icon: Icon(
                        _obscurePasswordEdit
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                  obscureText: _obscurePasswordEdit,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: remoteC,
                  decoration: const InputDecoration(labelText: 'Remote Path'),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed == true) {
      setState(() {
        cfg.hostController.text = hostC.text;
        cfg.portController.text = portC.text;
        cfg.userController.text = userC.text;
        cfg.keyController.text = keyC.text;
        cfg.passwordController.text = passC.text;
        cfg.remotePathController.text = remoteC.text;
      });
    }

    hostC.dispose();
    portC.dispose();
    userC.dispose();
    keyC.dispose();
    passC.dispose();
  }

  Future<void> _showServerDialog() async {
    final hostC = TextEditingController(text: _hostController.text);
    final portC = TextEditingController(text: _portController.text);
    final userC = TextEditingController(text: _userController.text);
    final keyC = TextEditingController(text: _keyController.text);
    final passC = TextEditingController(text: _passController.text);
    final labelC = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Container(
            width: 520,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Add Server',
                  style: Theme.of(ctx).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: labelC,
                  decoration: const InputDecoration(labelText: 'Profile Name'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: hostC,
                        decoration: const InputDecoration(labelText: 'Host'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: portC,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: userC,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: keyC,
                        decoration: const InputDecoration(
                          labelText: 'SSH Key (Optional)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () => _browseKey(keyC),
                      icon: const Icon(Icons.folder),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passC,
                  decoration: InputDecoration(
                    labelText: 'Password (Optional)',
                    suffixIcon: IconButton(
                      onPressed: () => setState(
                        () => _obscurePasswordAdd = !_obscurePasswordAdd,
                      ),
                      icon: Icon(
                        _obscurePasswordAdd
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                  obscureText: _obscurePasswordAdd,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed == true) {
      final updated = await _loginHistoryStore.addOrUpdate(
        _recentLogins,
        host: hostC.text,
        port: int.tryParse(portC.text) ?? 22,
        username: userC.text,
        password: passC.text,
        keyPath: keyC.text,
        label: labelC.text.isNotEmpty ? labelC.text : null,
      );
      if (!mounted) return;
      setState(() => _recentLogins = updated);
    } else {
      hostC.dispose();
      portC.dispose();
      userC.dispose();
      keyC.dispose();
      passC.dispose();
      labelC.dispose();
    }
  }

  void _removeBatchServer(int index) {
    if (index < 0 || index >= _batchServers.length) return;
    final cfg = _batchServers.removeAt(index);
    cfg.dispose();
    setState(() {});
  }

  void _applySavedToBatchServer(int index, LoginProfile profile) {
    if (index < 0 || index >= _batchServers.length) return;
    final cfg = _batchServers[index];
    setState(() {
      cfg.hostController.text = profile.host;
      cfg.portController.text = profile.port.toString();
      cfg.userController.text = profile.username;
      cfg.passwordController.text = profile.password ?? '';
      cfg.keyController.text = profile.keyPath;
    });
  }

  Future<void> _saveBatchServerToHistory(int index) async {
    if (index < 0 || index >= _batchServers.length) return;
    final cfg = _batchServers[index];
    final updated = await _loginHistoryStore.addOrUpdate(
      _recentLogins,
      host: cfg.hostController.text,
      port: int.tryParse(cfg.portController.text) ?? 22,
      username: cfg.userController.text,
      password: cfg.passwordController.text,
      keyPath: cfg.keyController.text,
    );
    if (!mounted) return;
    setState(() => _recentLogins = updated);
  }

  Future<T> _runBusy<T>(String label, Future<T> Function() action) async {
    if (mounted) {
      setState(() {
        _isBusy = true;
        _busyLabel = label;
      });
    }
    try {
      return await action();
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _busyLabel = null;
        });
      }
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _keyController.dispose();
    _passController.dispose();
    _pathController.dispose();
    _remoteController.dispose();
    _localController.dispose();
    for (final cfg in _batchServers) {
      cfg.dispose();
    }
    _backend.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    await _runBusy('Connecting…', () async {
      setState(() => _loginStatus = 'Connecting...');
      try {
        // 1. Start the backend process & socket
        await _backend.startBackend();

        // 2. Perform SSH login
        final host = _hostController.text;
        final port = int.tryParse(_portController.text) ?? 22;
        final user = _userController.text;
        final pass = _passController.text;
        final key = _keyController.text;

        final connRes = await _backend.sendCommand('connect', {
          'host': host,
          'port': port,
          'username': user,
          'key_path': key,
          'password': pass,
        });
        // Backend may return an object with an 'error' key; treat that as failure
        if (connRes is Map && connRes.containsKey('error')) {
          throw connRes['error'] ?? 'connection error';
        }

        final updated = await _loginHistoryStore.addOrUpdate(
          _recentLogins,
          host: host,
          port: port,
          username: user,
          password: pass,
          keyPath: key,
        );

        setState(() {
          _recentLogins = updated;
          _loginStatus = 'Connected';
        });

        // Automatically load the root directory after connecting
        await _refreshExplorer();
      } catch (e) {
        // Show a dialog with the connection error so the user can't continue silently
        try {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Connection Failed'),
              content: Text(e.toString()),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        } catch (_) {}
        setState(() {
          _loginStatus = 'Disconnected';
          _passController.clear(); // Clear password on failure for security
        });
      }
    });
  }

  Future<void> _disconnect() async {
    await _runBusy('Disconnecting…', () async {
      try {
        await _backend.sendCommand('disconnect', {});
      } catch (e) {
        // ignore
      } finally {
        // Always stop the backend on disconnect/logout
        await _backend.stopBackend();
        setState(() {
          _loginStatus = 'Disconnected';
        });
      }
    });
  }

  Future<void> _refreshExplorer() async {
    await _runBusy('Loading folder…', () async {
      final path = _pathController.text;
      try {
        final result = await _backend.sendCommand('list_dir', {'path': path});
        setState(() {
          _explorerEntries = List<Map<String, dynamic>>.from(
            result['result'].map(
              (e) => {'name': e[0], 'is_dir': e[1], 'size': e[2]},
            ),
          );
        });
      } catch (e) {
        // ignore
      }
    });
  }

  Future<void> _openFileInternal(String remotePath) async {
    await _runBusy('Loading file…', () async {
      try {
        final res = await _backend.sendCommand('read_file', {
          'remote_path': remotePath,
        });
        final content = res['result'] ?? '';
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(remotePath),
            content: SizedBox(
              width: 700,
              child: SingleChildScrollView(
                child: SelectableText(content.toString()),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      } catch (e) {
        // ignore
      }
    });
  }

  Future<void> _openFileExternal(String remotePath) async {
    await _runBusy('Downloading file…', () async {
      try {
        final fileName = remotePath
            .split('/')
            .where((s) => s.isNotEmpty)
            .toList()
            .last;
        final dir = await Directory.systemTemp.createTemp('servermgr_');
        final localPath = '${dir.path}${Platform.pathSeparator}$fileName';
        await _backend.sendCommand('download', {
          'remote_path': remotePath,
          'local_path': localPath,
        });
        // Open with platform default
        if (Platform.isWindows) {
          await Process.start('cmd', ['/c', 'start', '', localPath]);
        } else if (Platform.isMacOS) {
          await Process.start('open', [localPath]);
        } else {
          await Process.start('xdg-open', [localPath]);
        }
      } catch (e) {
        // ignore
      }
    });
  }

  void _applyRecentLogin(LoginProfile profile) {
    _hostController.text = profile.host;
    _portController.text = profile.port.toString();
    _userController.text = profile.username;
    _keyController.text = profile.keyPath;
    _passController.text = profile.password ?? '';
  }

  Future<void> _removeRecentLogin(LoginProfile profile) async {
    final updated = await _loginHistoryStore.remove(_recentLogins, profile);
    if (!mounted) return;
    setState(() => _recentLogins = updated);
  }

  Future<void> _clearRecentLogins() async {
    await _loginHistoryStore.clear();
    if (!mounted) return;
    setState(() => _recentLogins = []);
  }

  void _upExplorer() {
    final path = _pathController.text;
    final newPath = path == '/'
        ? '/'
        : path.substring(0, path.lastIndexOf('/'));
    _pathController.text = newPath.isEmpty ? '/' : newPath;
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
      setState(() {
        _remoteController.text = '${_pathController.text}/${item['name']}';
        _selectedIndex = 2; // Switch to Backup tab
      });
    }
  }

  Future<void> _mkdir() async {
    final name = await showInputDialog(
      context,
      'New Folder Name',
      'new_folder',
    );
    if (name != null) {
      final path = '${_pathController.text}/$name';
      try {
        await _backend.sendCommand('make_dir', {'path': path});
        _refreshExplorer();
      } catch (e) {
        // ignore
      }
    }
  }

  Future<void> _rename() async {
    final item = _explorerEntries.firstWhere((e) => true, orElse: () => {});
    if (item.isNotEmpty) {
      final newName = await showInputDialog(context, 'New Name', item['name']);
      if (newName != null) {
        final oldPath = '${_pathController.text}/${item['name']}';
        final newPath = '${_pathController.text}/$newName';
        try {
          await _backend.sendCommand('rename', {
            'old_path': oldPath,
            'new_path': newPath,
          });
          _refreshExplorer();
        } catch (e) {
          // ignore
        }
      }
    }
  }

  Future<void> _delete() async {
    final item = _explorerEntries.firstWhere((e) => true, orElse: () => {});
    if (item.isNotEmpty) {
      final confirmed = await showConfirmDialog(
        context,
        'Delete ${item['name']}?',
      );
      if (confirmed) {
        final path = '${_pathController.text}/${item['name']}';
        try {
          await _backend.sendCommand('delete', {'path': path});
          _refreshExplorer();
        } catch (e) {
          // ignore
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
        await _backend.sendCommand('upload', {
          'local_path': localPath,
          'remote_path': remotePath,
        });
        _refreshExplorer();
      } catch (e) {
        // ignore
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
          await _backend.sendCommand('download', {
            'remote_path': remotePath,
            'local_path': result,
          });
        } catch (e) {
          // ignore
        }
      }
    }
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
    if (remote.trim().isEmpty) {
      _addBackupLog(
        'Abort: remote path is empty. Select a folder to backup first.',
      );
      return;
    }
    String remoteBaseName(String p) {
      final parts = p.split('/').where((s) => s.trim().isNotEmpty).toList();
      return parts.isEmpty ? 'backup' : parts.last;
    }

    String joinLocalPath(String base, List<String> parts) {
      var out = base;
      for (final part in parts) {
        if (part.trim().isEmpty) continue;
        out = '$out${Platform.pathSeparator}$part';
      }
      return out;
    }

    String relativeRemotePath(String full, String root) {
      var rel = full;
      if (full.startsWith(root)) {
        rel = full.substring(root.length);
      }
      while (rel.startsWith('/')) {
        rel = rel.substring(1);
      }
      return rel.isEmpty ? remoteBaseName(full) : rel;
    }

    Future<List<Map<String, dynamic>>> collectFiles(
      String root,
      String current,
    ) async {
      try {
        final listRes = await _backend.sendCommand('list_dir', {
          'path': current,
        });
        if (listRes is Map && listRes.containsKey('error')) {
          // Not a directory, treat as file
          return [
            {
              'remote': current,
              'rel': relativeRemotePath(current, root),
              'size': 0,
            },
          ];
        }

        final entries = List<Map<String, dynamic>>.from(
          listRes['result'].map(
            (e) => {'name': e[0], 'is_dir': e[1], 'size': e[2]},
          ),
        );

        final out = <Map<String, dynamic>>[];
        for (final e in entries) {
          final name = (e['name'] ?? '').toString();
          final isDir = e['is_dir'] as bool;
          final size = (e['size'] ?? 0) as num;
          final childRemote = current == '/' ? '/$name' : '$current/$name';
          if (isDir) {
            out.addAll(await collectFiles(root, childRemote));
          } else {
            out.add({
              'remote': childRemote,
              'rel': relativeRemotePath(childRemote, root),
              'size': size,
            });
          }
        }
        return out;
      } catch (_) {
        // If list_dir fails, treat as file
        return [
          {
            'remote': current,
            'rel': relativeRemotePath(current, root),
            'size': 0,
          },
        ];
      }
    }

    try {
      var actualLocal = local;
      if (actualLocal.trim().isEmpty) {
        // Default to a safe temporary directory
        final d = await Directory.systemTemp.createTemp('servermgr_backup_');
        actualLocal = d.path;
        _localController.text = actualLocal;
        _addBackupLog('Local path was empty — using temp dir: $actualLocal');
      }

      // Make sure the chosen local base exists
      await Directory(actualLocal).create(recursive: true);

      // Requirement (1): create folder with same name as remote directory
      final localTargetDir = joinLocalPath(actualLocal, [
        remoteBaseName(remote),
      ]);
      await Directory(localTargetDir).create(recursive: true);
      _addBackupLog('Local target folder: $localTargetDir');

      setState(() => _progress = 0.0);

      await _runBusy('Downloading…', () async {
        _addBackupLog('Scanning remote tree…');
        final files = await collectFiles(remote, remote);
        if (files.isEmpty) {
          _addBackupLog('Nothing to download.');
          setState(() => _progress = 100.0);
          return;
        }

        final totalBytes = files
            .map((f) => (f['size'] ?? 0) as num)
            .where((s) => s > 0)
            .fold<num>(0, (a, b) => a + b);
        final totalFiles = files.length;
        var doneFiles = 0;
        num doneBytes = 0;

        _addBackupLog('Downloading $totalFiles file(s)…');

        for (final f in files) {
          final remoteFile = (f['remote'] ?? '').toString();
          final rel = (f['rel'] ?? '').toString();
          final size = (f['size'] ?? 0) as num;

          final relParts = rel
              .split('/')
              .where((s) => s.trim().isNotEmpty)
              .toList();
          final localFile = joinLocalPath(localTargetDir, relParts);

          try {
            await Directory(
              File(localFile).parent.path,
            ).create(recursive: true);
          } catch (_) {}

          final res = await _backend.sendCommand('download', {
            'remote_path': remoteFile,
            'local_path': localFile,
          });

          if (res is Map && res.containsKey('error')) {
            _addBackupLog(
              'Failed: $remoteFile -> $localFile : ${res['error']}',
            );
          } else {
            doneFiles += 1;
            doneBytes += size;
          }

          final pct = totalBytes > 0
              ? (doneBytes / totalBytes) * 100.0
              : (doneFiles / totalFiles) * 100.0;
          if (mounted) {
            setState(() => _progress = pct.clamp(0.0, 100.0));
          }
        }

        if (mounted) {
          setState(() => _progress = 100.0);
        }
        _addBackupLog(
          'Done. Downloaded $doneFiles/$totalFiles file(s) into $localTargetDir',
        );
      });
    } catch (e) {
      _addBackupLog('Backup failed: $e');
    }
  }

  Future<void> _startMultiBackup() async {
    final mode = _mode.startsWith('rsync') ? 'rsync' : 'tar';
    final servers = _batchServers
        .map(
          (s) => {
            'host': s.hostController.text.trim(),
            'port': int.tryParse(s.portController.text.trim()) ?? 22,
            'username': s.userController.text.trim(),
            'password': s.passwordController.text,
            'key_path': s.keyController.text,
            'remote_path': s.remotePathController.text.trim(),
          },
        )
        .where(
          (m) =>
              (m['host'] as String).isNotEmpty &&
              (m['remote_path'] as String).isNotEmpty,
        )
        .toList();

    if (servers.isEmpty) {
      _addBackupLog('Add at least one server with host and remote path.');
      return;
    }

    // Validate credentials per-server: require either password or key_path
    final missing = <int>[];
    for (var i = 0; i < servers.length; i++) {
      final s = servers[i];
      final pw = (s['password'] ?? '').toString().trim();
      final key = (s['key_path'] ?? '').toString().trim();
      if (pw.isEmpty && key.isEmpty) missing.add(i + 1);
    }

    if (missing.isNotEmpty) {
      // Show dialog to user listing which servers are missing credentials
      final listStr = missing.map((i) => 'Server #$i').join(', ');
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Missing Credentials'),
          content: Text(
            'The following servers are missing authentication (password or SSH key): $listStr.\n\nPlease edit the batch entries and provide a password or key before starting the backup.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      _addBackupLog('Batch aborted: missing credentials for $listStr');
      return;
    }

    var localRoot = _localController.text.trim();
    if (localRoot.isEmpty) {
      final d = await Directory.systemTemp.createTemp('servermgr_batch_');
      localRoot = d.path;
      _localController.text = localRoot;
      _addBackupLog('Local path was empty — using temp dir: $localRoot');
    }

    // Ensure backend is started before sending command
    await _backend.startBackend();

    await _runBusy('Starting batch…', () async {
      try {
        final res = await _backend.sendCommand('multi_backup', {
          'servers': servers,
          'local_root': localRoot,
          'mode': mode,
          'per_host_limit': _perHostLimit,
        }, const Duration(hours: 8));
        final result = (res is Map && res.containsKey('result'))
            ? res['result']
            : res;
        _addBackupLog('Batch queued: $result');
        // If backend returned connect instrumentation, log it
        try {
          if (result is Map && result.containsKey('connect_stats')) {
            _addBackupLog('Connect stats: ${result['connect_stats']}');
          }
        } catch (_) {}
        await _refreshJobs();
      } catch (e) {
        _addBackupLog('Batch failed to start: $e');
      }
    });
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

  Future<void> _browseKey(TextEditingController controller) async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      controller.text = result.files.single.path!;
    }
  }

  Future<void> _refreshJobs() async {
    try {
      final result = await _backend.sendCommand('list_jobs', {});
      setState(() {
        _jobs = List<Map<String, dynamic>>.from(result['result']);
      });
    } catch (e) {
      // ignore
    }
  }

  void _resumeJob() {
    // TODO: implement
  }

  void _deleteJob() {
    // TODO: implement
  }

  Future<void> _addSavedToBatch(int index) async {
    if (index < 0 || index >= _recentLogins.length) return;
    final p = _recentLogins[index];
    final cfg = BackupServerConfig(
      hostController: TextEditingController(text: p.host),
      portController: TextEditingController(text: p.port.toString()),
      userController: TextEditingController(text: p.username),
      passwordController: TextEditingController(text: p.password ?? ''),
      keyController: TextEditingController(text: p.keyPath),
      remotePathController: TextEditingController(text: '/'),
    );
    setState(() {
      _batchServers.add(cfg);
    });
  }

  void _renameSavedProfile(int index, String newLabel) async {
    if (index < 0 || index >= _recentLogins.length) return;
    _recentLogins[index] = _recentLogins[index].copyWith(label: newLabel);
    await _loginHistoryStore.save(_recentLogins);
    setState(() {});
  }

  void _removeSavedProfile(int index) async {
    if (index < 0 || index >= _recentLogins.length) return;
    _recentLogins.removeAt(index);
    await _loginHistoryStore.save(_recentLogins);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              NavigationRail(
                leading: Padding(
                  padding: const EdgeInsets.only(top: 12.0, bottom: 8.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          'assets/icon-b.png',
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'ServerBackup',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                selectedIndex: _selectedIndex,
                onDestinationSelected: (val) =>
                    setState(() => _selectedIndex = val),
                labelType: NavigationRailLabelType.all,
                backgroundColor: Theme.of(context).colorScheme.surface,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.folder_open),
                    label: Text('Explorer'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.backup_outlined),
                    label: Text('Backup'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.task_alt),
                    label: Text('Jobs'),
                  ),
                ],
              ).animate().slideX(
                begin: -1,
                end: 0,
                duration: 600.ms,
                curve: Curves.easeOutQuint,
              ),
              const VerticalDivider(width: 1, thickness: 1),
              Expanded(
                child: AnimatedSwitcher(
                  duration: 400.ms,
                  switchInCurve: Curves.easeOutQuart,
                  switchOutCurve: Curves.easeInQuart,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.05, 0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey(_selectedIndex),
                    child: Container(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: _buildTabContent(_selectedIndex),
                    ),
                  ),
                ),
              ),
            ],
          ),
          IgnorePointer(
            ignoring: !_isBusy,
            child: AnimatedOpacity(
              duration: 200.ms,
              opacity: _isBusy ? 1 : 0,
              child: Container(
                color: Colors.black.withOpacity(0.35),
                child: Center(
                  child:
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ).animate().rotate(duration: 900.ms),
                              const SizedBox(width: 12),
                              Text(_busyLabel ?? 'Working…'),
                            ],
                          ),
                        ),
                      ).animate().scale(
                        duration: 180.ms,
                        begin: const Offset(0.98, 0.98),
                        end: const Offset(1, 1),
                      ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabContent(int index) {
    switch (index) {
      case 0:
        return ExplorerTab(
          pathController: _pathController,
          explorerEntries: _explorerEntries,
          onRefresh: _refreshExplorer,
          onUp: _upExplorer,
          onSelectEntry: _selectEntry,
          onUseForBackup: _useForBackup,
          onMkdir: _mkdir,
          onRename: _rename,
          onDelete: _delete,
          onUpload: _upload,
          onDownload: _download,
          onOpenExternal: _openFileExternal,
          onOpenInternal: _openFileInternal,
          loginStatus: _loginStatus,
          isBusy: _isBusy,
          hostController: _hostController,
          portController: _portController,
          userController: _userController,
          keyController: _keyController,
          passController: _passController,
          recentLogins: _recentLogins,
          onSelectRecent: _applyRecentLogin,
          onRemoveRecent: _removeRecentLogin,
          onClearRecent: _clearRecentLogins,
          onConnect: _connect,
          onDisconnect: _disconnect,
        );
      case 1:
        return BackupTab(
          remoteController: _remoteController,
          localController: _localController,
          mode: _mode,
          progress: _progress,
          backupLogs: _backupLogs,
          batchServers: _batchServers,
          recentLogins: _recentLogins,
          jobs: _jobs,
          onModeChanged: (v) => setState(() => _mode = v),
          onBrowseLocal: _browseLocal,
          onStartBackup: _startBackup,
          onStartMultiBackup: _startMultiBackup,
          perHostLimit: _perHostLimit,
          onPerHostLimitChanged: (v) => setState(() => _perHostLimit = v),
          onAddServer: _addBatchServer,
          onRemoveServer: _removeBatchServer,
          onSelectSavedProfile: _applySavedToBatchServer,
          onSaveServer: _saveBatchServerToHistory,
          onEditServer: _editBatchServer,
          onAddSavedProfile: _addSavedToBatch,
          onRenameSavedProfile: _renameSavedProfile,
          onRemoveSavedProfile: _removeSavedProfile,
          onPauseBackup: _pauseBackup,
          onResumeBackup: _resumeBackup,
          onCancelBackup: _cancelBackup,
        );
      case 2:
        return JobsTab(
          jobs: _jobs,
          onRefreshJobs: _refreshJobs,
          onResumeJob: _resumeJob,
          onDeleteJob: _deleteJob,
        );
      default:
        return const Center(child: Text('Unknown Tab'));
    }
  }
}
