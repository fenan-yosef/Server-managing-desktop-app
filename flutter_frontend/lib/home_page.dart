import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'services/backend_service.dart';
import 'tabs/login_tab.dart';
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

  // Jobs
  List<Map<String, dynamic>> _jobs = [];

  @override
  void initState() {
    super.initState();
    _backend.onLog = (msg) => setState(() => _logs.add(msg));
    // Do not start backend here. It starts on 'Connect'.
    _loadRecentLogins();
  }

  Future<void> _loadRecentLogins() async {
    final loaded = await _loginHistoryStore.load();
    if (!mounted) return;
    setState(() => _recentLogins = loaded);
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

        await _backend.sendCommand('connect', {
          'host': host,
          'port': port,
          'username': user,
          'key_path': key,
          'password': pass,
        });

        final updated = await _loginHistoryStore.addOrUpdate(
          _recentLogins,
          host: host,
          port: port,
          username: user,
          keyPath: key,
        );

        setState(() {
          _recentLogins = updated;
          _loginStatus = 'Connected';
        });
      } catch (e) {
        setState(() {
          _loginStatus = 'Connection failed: $e';
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
                    icon: Icon(Icons.login),
                    label: Text('Connect'),
                  ),
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
        return LoginTab(
          hostController: _hostController,
          portController: _portController,
          userController: _userController,
          keyController: _keyController,
          passController: _passController,
          loginStatus: _loginStatus,
          isBusy: _isBusy,
          recentLogins: _recentLogins,
          onSelectRecent: _applyRecentLogin,
          onRemoveRecent: _removeRecentLogin,
          onClearRecent: _clearRecentLogins,
          onConnect: _connect,
          onDisconnect: _disconnect,
        );
      case 1:
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
        );
      case 2:
        return BackupTab(
          remoteController: _remoteController,
          localController: _localController,
          mode: _mode,
          progress: _progress,
          backupLogs: _backupLogs,
          onModeChanged: (v) => setState(() => _mode = v),
          onBrowseLocal: _browseLocal,
          onStartBackup: _startBackup,
          onPauseBackup: _pauseBackup,
          onResumeBackup: _resumeBackup,
          onCancelBackup: _cancelBackup,
        );
      case 3:
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
