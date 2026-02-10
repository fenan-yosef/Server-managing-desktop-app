import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/login_history.dart';

class BackupServerConfig {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController userController;
  final TextEditingController passwordController;
  final TextEditingController keyController;
  final TextEditingController remotePathController;

  BackupServerConfig({
    required this.hostController,
    required this.portController,
    required this.userController,
    required this.passwordController,
    required this.keyController,
    required this.remotePathController,
  });

  void dispose() {
    hostController.dispose();
    portController.dispose();
    userController.dispose();
    passwordController.dispose();
    keyController.dispose();
    remotePathController.dispose();
  }
}

class BackupTab extends StatelessWidget {
  final TextEditingController remoteController;
  final TextEditingController localController;
  final String mode;
  final double progress;
  final List<String> backupLogs;
  final List<BackupServerConfig> batchServers;
  final List<LoginProfile> recentLogins;
  final Function(String) onModeChanged;
  final Future<void> Function() onBrowseLocal;
  final Future<void> Function() onStartBackup;
  final Future<void> Function() onStartMultiBackup;
  final VoidCallback onAddServer;
  final void Function(int) onRemoveServer;
  final void Function(int, LoginProfile) onSelectSavedProfile;
  final void Function(int) onEditServer;
  final void Function(int) onAddSavedProfile;
  final void Function(int, String) onRenameSavedProfile;
  final void Function(int) onRemoveSavedProfile;
  final Future<void> Function(int) onSaveServer;
  final VoidCallback onPauseBackup;
  final VoidCallback onResumeBackup;
  final VoidCallback onCancelBackup;

  const BackupTab({
    super.key,
    required this.remoteController,
    required this.localController,
    required this.mode,
    required this.progress,
    required this.backupLogs,
    required this.batchServers,
    required this.recentLogins,
    required this.onModeChanged,
    required this.onBrowseLocal,
    required this.onStartBackup,
    required this.onStartMultiBackup,
    required this.onAddServer,
    required this.onRemoveServer,
    required this.onSelectSavedProfile,
    required this.onEditServer,
    required this.onAddSavedProfile,
    required this.onRenameSavedProfile,
    required this.onRemoveSavedProfile,
    required this.onSaveServer,
    required this.onPauseBackup,
    required this.onResumeBackup,
    required this.onCancelBackup,
  });

  void _showRenameDialog(BuildContext context, int index, String currentLabel) {
    final controller = TextEditingController(text: currentLabel);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Profile'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'New Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              onRenameSavedProfile(index, controller.text);
              Navigator.pop(ctx);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Configuration card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Configuration',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: remoteController,
                    decoration: const InputDecoration(
                      labelText: 'Remote Source Path',
                      prefixIcon: Icon(Icons.cloud_download),
                      helperText: 'e.g. /home/user/data',
                    ),
                  ).animate().fade().moveX(),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: localController,
                          decoration: const InputDecoration(
                            labelText: 'Local Destination',
                            prefixIcon: Icon(Icons.save),
                            helperText: 'e.g. C:/Backups',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        onPressed: onBrowseLocal,
                        icon: const Icon(Icons.folder_open),
                        tooltip: 'Browse Local',
                      ),
                    ],
                  ).animate().fade(delay: 100.ms).moveX(),
                  const SizedBox(height: 16),
                  const Text('Backup Mode'),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'tar.gz (single archive)',
                        label: Text('Archive (Tar.gz)'),
                        icon: Icon(Icons.archive),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => onModeChanged(s.first),
                  ).animate().fade(delay: 200.ms).scale(),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () {
                      remoteController.text = '/';
                    },
                    icon: const Icon(Icons.public),
                    label: const Text('Whole Server'),
                  ),
                ],
              ),
            ),
          ).animate().slideY(begin: -0.5, end: 0, duration: 500.ms),
          const SizedBox(height: 24),

          // Batch servers card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Batch Servers',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      FilledButton.icon(
                        onPressed: onAddServer,
                        icon: const Icon(Icons.add),
                        label: const Text('Add Server'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Two-column view: left = saved profiles, right = batch list
                  SizedBox(
                    height: 240,
                    child: Row(
                      children: [
                        // Left: saved profiles
                        Expanded(
                          child: Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Saved Profiles',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: recentLogins.isEmpty
                                        ? const Center(
                                            child: Text('No saved profiles'),
                                          )
                                        : ListView.builder(
                                            physics:
                                                const AlwaysScrollableScrollPhysics(),
                                            itemCount: recentLogins.length,
                                            itemBuilder: (c, i) {
                                              final p = recentLogins[i];
                                              return ListTile(
                                                dense: true,
                                                title: Text(p.label),
                                                subtitle: Text(
                                                  '${p.username}@${p.host}:${p.port}',
                                                ),
                                                trailing: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    IconButton(
                                                      icon: const Icon(
                                                        Icons.add,
                                                      ),
                                                      tooltip: 'Add to batch',
                                                      onPressed: () =>
                                                          onAddSavedProfile(i),
                                                    ),
                                                    PopupMenuButton<String>(
                                                      onSelected: (value) {
                                                        if (value == 'rename') {
                                                          _showRenameDialog(
                                                            context,
                                                            i,
                                                            p.label,
                                                          );
                                                        } else if (value ==
                                                            'delete') {
                                                          onRemoveSavedProfile(
                                                            i,
                                                          );
                                                        }
                                                      },
                                                      itemBuilder: (context) =>
                                                          [
                                                            const PopupMenuItem(
                                                              value: 'rename',
                                                              child: Text(
                                                                'Rename',
                                                              ),
                                                            ),
                                                            const PopupMenuItem(
                                                              value: 'delete',
                                                              child: Text(
                                                                'Delete',
                                                              ),
                                                            ),
                                                          ],
                                                    ),
                                                  ],
                                                ),
                                              );
                                            },
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Right: batch servers list
                        Expanded(
                          child: Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Batch List',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: batchServers.isEmpty
                                        ? const Center(
                                            child: Text(
                                              'No servers added to batch',
                                            ),
                                          )
                                        : ListView.builder(
                                            physics:
                                                const AlwaysScrollableScrollPhysics(),
                                            itemCount: batchServers.length,
                                            itemBuilder: (c, i) => Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 8.0,
                                              ),
                                              child: _ServerCardSummary(
                                                index: i,
                                                config: batchServers[i],
                                                onRemove: () =>
                                                    onRemoveServer(i),
                                                onEdit: () => onEditServer(i),
                                                onSave: () => onSaveServer(i),
                                              ),
                                            ),
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ).animate().fade(delay: 220.ms).slideY(begin: -0.2, end: 0),
          const SizedBox(height: 24),

          // Operations card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Operations',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${progress.toStringAsFixed(1)}%',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(
                        begin: 0.0,
                        end: (progress / 100).clamp(0.0, 1.0),
                      ),
                      duration: const Duration(milliseconds: 500),
                      builder: (context, value, child) {
                        return LinearProgressIndicator(
                          value: value,
                          minHeight: 8,
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: onStartBackup,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Start'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: onStartMultiBackup,
                        icon: const Icon(Icons.cloud_download),
                        label: const Text('Run Batch (Parallel)'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: onPauseBackup,
                        icon: const Icon(Icons.pause),
                        label: const Text('Pause'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: onResumeBackup,
                        icon: const Icon(Icons.play_arrow_outlined),
                        label: const Text('Resume'),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.errorContainer,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onErrorContainer,
                        ),
                        onPressed: onCancelBackup,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ).animate().fade(delay: 300.ms),
          const SizedBox(height: 24),

          const Text('Console Log'),
          const SizedBox(height: 8),

          // Fixed-height console area so parent can scroll
          SizedBox(
            height: 260,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: backupLogs.length,
                itemBuilder: (c, i) {
                  return Text(
                    backupLogs[i],
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      color: Color(0xFFCCCCCC),
                      fontSize: 12,
                    ),
                  ).animate().fade().slideX(begin: -0.1, end: 0);
                },
              ),
            ),
          ).animate().slideY(begin: 0.5, end: 0, delay: 400.ms),
        ],
      ),
    );
  }
}

class _ServerCardSummary extends StatelessWidget {
  final int index;
  final BackupServerConfig config;
  final VoidCallback onRemove;
  final VoidCallback onEdit;
  final VoidCallback onSave;

  const _ServerCardSummary({
    required this.index,
    required this.config,
    required this.onRemove,
    required this.onEdit,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final host = config.hostController.text.isEmpty
        ? '<no host>'
        : config.hostController.text;
    final remote = config.remotePathController.text.isEmpty
        ? '<no path>'
        : config.remotePathController.text;
    final user = config.userController.text.isEmpty
        ? ''
        : '${config.userController.text}@';

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        title: Text('$user$host'),
        subtitle: Text(remote),
        leading: CircleAvatar(child: Text('${index + 1}')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit),
              tooltip: 'Edit',
            ),
            IconButton(
              onPressed: onSave,
              icon: const Icon(Icons.save),
              tooltip: 'Save to profiles',
            ),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.delete),
              tooltip: 'Remove',
            ),
          ],
        ),
      ),
    );
  }
}
