import 'package:flutter/material.dart';
import 'dart:io';
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
