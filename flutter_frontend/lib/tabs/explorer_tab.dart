import 'package:flutter/material.dart';

class ExplorerTab extends StatelessWidget {
  final TextEditingController pathController;
  final List<Map<String, dynamic>> explorerEntries;
  final Future<void> Function() onRefresh;
  final VoidCallback onUp;
  final Function(Map<String, dynamic>) onSelectEntry;
  final VoidCallback onUseForBackup;
  final Future<void> Function() onMkdir;
  final Future<void> Function() onRename;
  final Future<void> Function() onDelete;
  final Future<void> Function() onUpload;
  final Future<void> Function() onDownload;

  const ExplorerTab({
    super.key,
    required this.pathController,
    required this.explorerEntries,
    required this.onRefresh,
    required this.onUp,
    required this.onSelectEntry,
    required this.onUseForBackup,
    required this.onMkdir,
    required this.onRename,
    required this.onDelete,
    required this.onUpload,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: pathController,
                  decoration: const InputDecoration(labelText: 'Path'),
                  onSubmitted: (_) => onRefresh(),
                ),
              ),
              IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh)),
              IconButton(onPressed: onUp, icon: const Icon(Icons.arrow_upward)),
              ElevatedButton(
                onPressed: onUseForBackup,
                child: const Text('Use as Source'),
              ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              itemCount: explorerEntries.length,
              itemBuilder: (c, i) {
                final entry = explorerEntries[i];
                return ListTile(
                  leading: Icon(
                    entry['is_dir'] ? Icons.folder : Icons.insert_drive_file,
                  ),
                  title: Text(entry['name']),
                  subtitle: Text(
                    entry['is_dir'] ? 'DIR' : '${entry['size']} bytes',
                  ),
                  onTap: () => onSelectEntry(entry),
                );
              },
            ),
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: onMkdir,
                child: const Text('New Folder'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: onRename, child: const Text('Rename')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: onDelete, child: const Text('Delete')),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: onUpload, child: const Text('Upload')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onDownload,
                child: const Text('Download'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
