import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class BackupTab extends StatelessWidget {
  final TextEditingController remoteController;
  final TextEditingController localController;
  final String mode;
  final double progress;
  final List<String> backupLogs;
  final Function(String) onModeChanged;
  final Future<void> Function() onBrowseLocal;
  final Future<void> Function() onStartBackup;
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
    required this.onModeChanged,
    required this.onBrowseLocal,
    required this.onStartBackup,
    required this.onPauseBackup,
    required this.onResumeBackup,
    required this.onCancelBackup,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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
                        value: 'rsync (resumable)',
                        label: Text('Sync (Rsync)'),
                        icon: Icon(Icons.sync),
                      ),
                      ButtonSegment(
                        value: 'tar.gz (single archive)',
                        label: Text('Archive (Tar.gz)'),
                        icon: Icon(Icons.archive),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => onModeChanged(s.first),
                  ).animate().fade(delay: 200.ms).scale(),
                ],
              ),
            ),
          ).animate().slideY(begin: -0.5, end: 0, duration: 500.ms),
          const SizedBox(height: 24),
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
          Expanded(
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
