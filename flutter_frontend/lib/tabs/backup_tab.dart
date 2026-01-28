import 'package:flutter/material.dart';

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
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: remoteController,
            decoration: const InputDecoration(
              labelText: 'Remote source (Linux)',
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: localController,
                  decoration: const InputDecoration(
                    labelText: 'Local backup root',
                  ),
                ),
              ),
              IconButton(
                onPressed: onBrowseLocal,
                icon: const Icon(Icons.folder),
              ),
            ],
          ),
          DropdownButton<String>(
            value: mode,
            items: [
              'rsync (resumable)',
              'tar.gz (single archive)',
            ].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
            onChanged: (v) => onModeChanged(v!),
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: onStartBackup,
                child: const Text('Start Backup'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onPauseBackup,
                child: const Text('Pause'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onResumeBackup,
                child: const Text('Resume'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onCancelBackup,
                child: const Text('Cancel'),
              ),
            ],
          ),
          LinearProgressIndicator(value: progress / 100),
          Expanded(
            child: ListView.builder(
              itemCount: backupLogs.length,
              itemBuilder: (c, i) => Text(backupLogs[i]),
            ),
          ),
        ],
      ),
    );
  }
}
