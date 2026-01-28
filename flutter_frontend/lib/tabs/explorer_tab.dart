import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

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
    return Column(
      children: [
        // Top Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor.withOpacity(0.1),
              ),
            ),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: onUp,
                icon: const Icon(Icons.arrow_upward),
                tooltip: 'Up',
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: pathController,
                  decoration: const InputDecoration(
                    hintText: 'Path',
                    contentPadding: EdgeInsets.symmetric(horizontal: 16),
                    prefixIcon: Icon(Icons.search),
                  ),
                  onSubmitted: (_) => onRefresh(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: onUseForBackup,
                icon: const Icon(Icons.save_alt),
                label: const Text('Use Source'),
              ),
            ],
          ),
        ).animate().slideY(begin: -1, end: 0, duration: 400.ms),

        // List View
        Expanded(
          child: explorerEntries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_off,
                        size: 64,
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withOpacity(0.2),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No files found or not connected',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ).animate().fade(),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: explorerEntries.length,
                  separatorBuilder: (c, i) => const SizedBox(height: 4),
                  itemBuilder: (c, i) {
                    final entry = explorerEntries[i];
                    final isDir = entry['is_dir'] as bool;
                    return Card(
                          margin: EdgeInsets.zero,
                          child: ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: isDir
                                    ? Colors.amber.withOpacity(0.2)
                                    : Colors.blue.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                isDir ? Icons.folder : Icons.insert_drive_file,
                                color: isDir ? Colors.amber : Colors.blue,
                              ),
                            ),
                            title: Text(entry['name']),
                            subtitle: Text(
                              isDir ? 'Directory' : '${entry['size']} bytes',
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.grey,
                            ),
                            onTap: () => onSelectEntry(entry),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        )
                        .animate()
                        .fade(duration: 300.ms, delay: (50 * i).ms)
                        .slideX(begin: 0.1, end: 0);
                  },
                ),
        ),

        // Bottom Actions
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 10,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              ActionChip(
                avatar: const Icon(Icons.create_new_folder),
                label: const Text('New Folder'),
                onPressed: onMkdir,
              ),
              ActionChip(
                avatar: const Icon(Icons.drive_file_rename_outline),
                label: const Text('Rename'),
                onPressed: onRename,
              ),
              ActionChip(
                avatar: const Icon(Icons.delete),
                label: const Text('Delete'),
                onPressed: onDelete,
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
              ),
              ActionChip(
                avatar: const Icon(Icons.upload_file),
                label: const Text('Upload'),
                onPressed: onUpload,
              ),
              ActionChip(
                avatar: const Icon(Icons.download),
                label: const Text('Download'),
                onPressed: onDownload,
              ),
            ],
          ),
        ).animate().slideY(begin: 1, end: 0, delay: 200.ms),
      ],
    );
  }
}
