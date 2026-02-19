import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/login_history.dart';

enum ExplorerViewMode { details, grid, smallIcons, tinyList }

enum ExplorerSortBy { name, size, type }

class ExplorerTab extends StatefulWidget {
  final TextEditingController pathController;
  final List<Map<String, dynamic>> explorerEntries;
  final Future<void> Function() onRefresh;
  final VoidCallback onUp;
  final Function(Map<String, dynamic>) onSelectEntry;
  final VoidCallback onUseForBackup;
  final Future<void> Function() onMkdir;
  final Future<void> Function(Map<String, dynamic>) onRename;
  final Future<void> Function(List<Map<String, dynamic>>) onDelete;
  final Future<void> Function() onUpload;
  final Future<void> Function() onDownload;
  final Future<void> Function(String) onOpenExternal;
  final Future<void> Function(String) onOpenInternal;

  // Login parameters
  final String loginStatus;
  final bool isBusy;
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController userController;
  final TextEditingController keyController;
  final TextEditingController passController;
  final List<LoginProfile> recentLogins;
  final void Function(LoginProfile) onSelectRecent;
  final void Function(LoginProfile) onRemoveRecent;
  final VoidCallback onClearRecent;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

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
    required this.onOpenExternal,
    required this.onOpenInternal,
    required this.loginStatus,
    required this.isBusy,
    required this.hostController,
    required this.portController,
    required this.userController,
    required this.keyController,
    required this.passController,
    required this.recentLogins,
    required this.onSelectRecent,
    required this.onRemoveRecent,
    required this.onClearRecent,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  State<ExplorerTab> createState() => _ExplorerTabState();
}

class _ExplorerTabState extends State<ExplorerTab> {
  ExplorerViewMode _viewMode = ExplorerViewMode.details;
  ExplorerSortBy _sortBy = ExplorerSortBy.name;
  bool _ascending = true;
  bool _obscurePassword = true;
  final Set<String> _selectedPaths = <String>{};

  List<Map<String, dynamic>> get _entries => widget.explorerEntries;

  String _entryRemotePath(Map<String, dynamic> entry) {
    final name = (entry['name'] ?? '').toString();
    final base = widget.pathController.text.trim();
    if (base.isEmpty || base == '/') return '/$name';
    return '$base/$name';
  }

  bool _isSelected(Map<String, dynamic> entry) {
    return _selectedPaths.contains(_entryRemotePath(entry));
  }

  void _toggleSelected(Map<String, dynamic> entry, bool selected) {
    final path = _entryRemotePath(entry);
    setState(() {
      if (selected) {
        _selectedPaths.add(path);
      } else {
        _selectedPaths.remove(path);
      }
    });
  }

  List<Map<String, dynamic>> _selectedEntries(
    List<Map<String, dynamic>> entries,
  ) {
    return entries
        .where((e) => _selectedPaths.contains(_entryRemotePath(e)))
        .toList();
  }

  Future<void> _handleRenameSelected(List<Map<String, dynamic>> entries) async {
    final selected = _selectedEntries(entries);
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select one file or folder to rename.')),
      );
      return;
    }
    if (selected.length > 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rename supports only one selected item at a time.'),
        ),
      );
      return;
    }
    try {
      await widget.onRename(selected.first);
      setState(() {
        _selectedPaths..clear();
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Rename failed: $e')));
    }
  }

  Future<void> _handleDeleteSelected(List<Map<String, dynamic>> entries) async {
    final selected = _selectedEntries(entries);
    if (selected.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select one or more files/folders to delete.'),
        ),
      );
      return;
    }

    final names = selected
        .map((e) => (e['name'] ?? '').toString())
        .where((n) => n.trim().isNotEmpty)
        .toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${names.length} item(s)?'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('The following items will be deleted:'),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: names
                        .map(
                          (n) => Text('• $n', overflow: TextOverflow.ellipsis),
                        )
                        .toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await widget.onDelete(selected);
      setState(() {
        for (final e in selected) {
          _selectedPaths.remove(_entryRemotePath(e));
        }
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<void> _browseKey() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      widget.keyController.text = result.files.single.path!;
    }
  }

  List<Map<String, dynamic>> get _sortedEntries {
    final list = List<Map<String, dynamic>>.from(_entries);
    list.sort((a, b) {
      // dirs-first by type if sorting by type, otherwise optional
      if (_sortBy == ExplorerSortBy.name) {
        final an = (a['name'] ?? '').toString().toLowerCase();
        final bn = (b['name'] ?? '').toString().toLowerCase();
        return an.compareTo(bn) * (_ascending ? 1 : -1);
      } else if (_sortBy == ExplorerSortBy.size) {
        final asz = (a['size'] ?? 0) as num;
        final bsz = (b['size'] ?? 0) as num;
        return (asz == bsz)
            ? 0
            : ((asz < bsz ? -1 : 1) * (_ascending ? 1 : -1));
      } else if (_sortBy == ExplorerSortBy.type) {
        final ad = a['is_dir'] ? 0 : 1;
        final bd = b['is_dir'] ? 0 : 1;
        final cmp = ad.compareTo(bd);
        if (cmp != 0) return (_ascending ? 1 : -1) * cmp;
        // fallback to name
        final an = (a['name'] ?? '').toString().toLowerCase();
        final bn = (b['name'] ?? '').toString().toLowerCase();
        return an.compareTo(bn) * (_ascending ? 1 : -1);
      }
      return 0;
    });
    return list;
  }

  @override
  void didUpdateWidget(covariant ExplorerTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final validPaths = _entries.map(_entryRemotePath).toSet();
    _selectedPaths.removeWhere((p) => !validPaths.contains(p));
  }

  Widget _buildTopControls(BuildContext context) {
    return Container(
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
            onPressed: widget.onUp,
            icon: const Icon(Icons.arrow_upward),
            tooltip: 'Up',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: widget.pathController,
              decoration: const InputDecoration(
                hintText: 'Path',
                contentPadding: EdgeInsets.symmetric(horizontal: 16),
                prefixIcon: Icon(Icons.search),
              ),
              onSubmitted: (_) => widget.onRefresh(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
          const SizedBox(width: 8),
          // View mode selector
          DropdownButton<ExplorerViewMode>(
            value: _viewMode,
            dropdownColor: Theme.of(context).colorScheme.surface,
            onChanged: (v) => setState(() => _viewMode = v ?? _viewMode),
            underline: const SizedBox.shrink(),
            items: ExplorerViewMode.values.map((m) {
              return DropdownMenuItem(
                value: m,
                child: Text(m.toString().split('.').last),
              );
            }).toList(),
          ),
          const SizedBox(width: 8),
          // Sort selector
          DropdownButton<ExplorerSortBy>(
            value: _sortBy,
            dropdownColor: Theme.of(context).colorScheme.surface,
            onChanged: (v) => setState(() => _sortBy = v ?? _sortBy),
            underline: const SizedBox.shrink(),
            items: ExplorerSortBy.values.map((s) {
              return DropdownMenuItem(
                value: s,
                child: Text(s.toString().split('.').last),
              );
            }).toList(),
          ),
          IconButton(
            onPressed: () => setState(() => _ascending = !_ascending),
            icon: Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward),
            tooltip: 'Toggle sort direction',
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: widget.onDisconnect,
            icon: const Icon(Icons.logout),
            tooltip: 'Disconnect',
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: widget.onUseForBackup,
            icon: const Icon(Icons.save_alt),
            label: const Text('Use Source'),
          ),
        ],
      ),
    ).animate().slideY(begin: -1, end: 0, duration: 400.ms);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loginStatus != 'Connected') {
      // Show login UI
      return Center(
        child: Card(
          margin: const EdgeInsets.all(32),
          child: Container(
            width: 500,
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'SSH Connection',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ).animate().fade().moveY(begin: -10, end: 0),
                const SizedBox(height: 16),
                if (widget.recentLogins.isNotEmpty) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Recent',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      TextButton(
                        onPressed: widget.onClearRecent,
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.recentLogins.map((p) {
                      return InputChip(
                        label: Text(p.label),
                        onPressed: () => widget.onSelectRecent(p),
                        onDeleted: () => widget.onRemoveRecent(p),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: widget.hostController,
                        decoration: const InputDecoration(
                          labelText: 'Host',
                          prefixIcon: Icon(Icons.dns),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: widget.portController,
                        decoration: const InputDecoration(labelText: 'Port'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ).animate().fade(delay: 100.ms).moveX(begin: -10, end: 0),
                const SizedBox(height: 16),
                TextField(
                  controller: widget.userController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person),
                  ),
                ).animate().fade(delay: 200.ms).moveX(begin: -10, end: 0),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.keyController,
                        decoration: const InputDecoration(
                          labelText: 'SSH Key (Optional)',
                          prefixIcon: Icon(Icons.vpn_key),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: _browseKey,
                      icon: const Icon(Icons.folder),
                    ),
                  ],
                ).animate().fade(delay: 300.ms).moveX(begin: -10, end: 0),
                const SizedBox(height: 16),
                TextField(
                  controller: widget.passController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.password),
                    suffixIcon: IconButton(
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                  obscureText: _obscurePassword,
                ).animate().fade(delay: 400.ms).moveX(begin: -10, end: 0),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.isBusy ? null : widget.onConnect,
                        icon: const Icon(Icons.login),
                        label: const Text('Connect'),
                      ),
                    ),
                    if (widget.loginStatus == 'Connected') ...[
                      const SizedBox(width: 16),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: widget.isBusy ? null : widget.onDisconnect,
                          icon: const Icon(Icons.logout),
                          label: const Text('Disconnect'),
                        ),
                      ),
                    ],
                  ],
                ).animate().fade(delay: 500.ms).moveY(begin: 10, end: 0),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    widget.loginStatus,
                    style: TextStyle(
                      color: widget.loginStatus == 'Connected'
                          ? Colors.green
                          : widget.loginStatus.startsWith('Connection failed')
                          ? Colors.red
                          : Colors.grey,
                    ),
                  ),
                ).animate().fade(delay: 600.ms),
              ],
            ),
          ),
        ),
      );
    }

    // Show explorer UI
    final entries = _sortedEntries;
    return Column(
      children: [
        _buildTopControls(context),
        Expanded(
          child: entries.isEmpty
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
              : Builder(
                  builder: (c) {
                    if (_viewMode == ExplorerViewMode.grid) {
                      return GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 4,
                              childAspectRatio: 1,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                            ),
                        itemCount: entries.length,
                        itemBuilder: (ctx, i) {
                          final e = entries[i];
                          final isDir = e['is_dir'] as bool;
                          return GestureDetector(
                            onTap: () {
                              final remote = widget.pathController.text == '/'
                                  ? '/${e['name']}'
                                  : '${widget.pathController.text}/${e['name']}';
                              if (isDir) {
                                widget.onSelectEntry(e);
                              } else {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (ctx) => SafeArea(
                                    child: Wrap(
                                      children: [
                                        ListTile(
                                          leading: const Icon(Icons.article),
                                          title: const Text('Open (internal)'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onOpenInternal(remote);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.open_in_new,
                                          ),
                                          title: const Text('Open (external)'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onOpenExternal(remote);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.download),
                                          title: const Text('Download'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onDownload();
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }
                            },
                            child: Card(
                              child: Stack(
                                children: [
                                  Center(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          isDir
                                              ? Icons.folder
                                              : Icons.insert_drive_file,
                                          size: 36,
                                          color: isDir
                                              ? Colors.amber
                                              : Colors.blue,
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          e['name'],
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Positioned(
                                    right: 4,
                                    top: 4,
                                    child: Checkbox(
                                      value: _isSelected(e),
                                      onChanged: (v) =>
                                          _toggleSelected(e, v ?? false),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ).animate().fade(delay: (30 * i).ms);
                        },
                      );
                    }

                    if (_viewMode == ExplorerViewMode.smallIcons) {
                      return ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: entries.length,
                        itemBuilder: (ctx, i) {
                          final e = entries[i];
                          final isDir = e['is_dir'] as bool;
                          return ListTile(
                            leading: Icon(
                              isDir ? Icons.folder : Icons.insert_drive_file,
                              color: isDir ? Colors.amber : Colors.blue,
                            ),
                            title: Text(e['name']),
                            trailing: Checkbox(
                              value: _isSelected(e),
                              onChanged: (v) => _toggleSelected(e, v ?? false),
                            ),
                            onTap: () {
                              final remote = widget.pathController.text == '/'
                                  ? '/${e['name']}'
                                  : '${widget.pathController.text}/${e['name']}';
                              if (isDir) {
                                widget.onSelectEntry(e);
                              } else {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (ctx) => SafeArea(
                                    child: Wrap(
                                      children: [
                                        ListTile(
                                          leading: const Icon(Icons.article),
                                          title: const Text('Open (internal)'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onOpenInternal(remote);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.open_in_new,
                                          ),
                                          title: const Text('Open (external)'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onOpenExternal(remote);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.download),
                                          title: const Text('Download'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onDownload();
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }
                            },
                          ).animate().fade(delay: (20 * i).ms);
                        },
                      );
                    }

                    if (_viewMode == ExplorerViewMode.tinyList) {
                      return ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: entries.length,
                        itemBuilder: (ctx, i) {
                          final e = entries[i];
                          final isDir = e['is_dir'] as bool;
                          return ListTile(
                            minLeadingWidth: 4,
                            dense: true,
                            leading: Icon(
                              isDir ? Icons.folder : Icons.insert_drive_file,
                              size: 18,
                              color: isDir ? Colors.amber : Colors.blue,
                            ),
                            title: Text(
                              e['name'],
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Checkbox(
                              value: _isSelected(e),
                              onChanged: (v) => _toggleSelected(e, v ?? false),
                            ),
                            onTap: () {
                              final remote = widget.pathController.text == '/'
                                  ? '/${e['name']}'
                                  : '${widget.pathController.text}/${e['name']}';
                              if (isDir) {
                                widget.onSelectEntry(e);
                              } else {
                                showModalBottomSheet(
                                  context: context,
                                  builder: (ctx) => SafeArea(
                                    child: Wrap(
                                      children: [
                                        ListTile(
                                          leading: const Icon(Icons.article),
                                          title: const Text('Open (internal)'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onOpenInternal(remote);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(
                                            Icons.open_in_new,
                                          ),
                                          title: const Text('Open (external)'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onOpenExternal(remote);
                                          },
                                        ),
                                        ListTile(
                                          leading: const Icon(Icons.download),
                                          title: const Text('Download'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            widget.onDownload();
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }
                            },
                          );
                        },
                      );
                    }

                    // default: details
                    return ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: entries.length,
                      separatorBuilder: (c, i) => const SizedBox(height: 4),
                      itemBuilder: (c, i) {
                        final entry = entries[i];
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
                                    isDir
                                        ? Icons.folder
                                        : Icons.insert_drive_file,
                                    color: isDir ? Colors.amber : Colors.blue,
                                  ),
                                ),
                                title: Text(entry['name']),
                                subtitle: Text(
                                  isDir
                                      ? 'Directory'
                                      : '${entry['size']} bytes',
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.chevron_right,
                                      color: Colors.grey,
                                    ),
                                    Checkbox(
                                      value: _isSelected(entry),
                                      onChanged: (v) =>
                                          _toggleSelected(entry, v ?? false),
                                    ),
                                  ],
                                ),
                                onTap: () {
                                  final remote =
                                      widget.pathController.text == '/'
                                      ? '/${entry['name']}'
                                      : '${widget.pathController.text}/${entry['name']}';
                                  if (isDir) {
                                    widget.onSelectEntry(entry);
                                  } else {
                                    showModalBottomSheet(
                                      context: context,
                                      builder: (ctx) => SafeArea(
                                        child: Wrap(
                                          children: [
                                            ListTile(
                                              leading: const Icon(
                                                Icons.article,
                                              ),
                                              title: const Text(
                                                'Open (internal)',
                                              ),
                                              onTap: () {
                                                Navigator.pop(ctx);
                                                widget.onOpenInternal(remote);
                                              },
                                            ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.open_in_new,
                                              ),
                                              title: const Text(
                                                'Open (external)',
                                              ),
                                              onTap: () {
                                                Navigator.pop(ctx);
                                                widget.onOpenExternal(remote);
                                              },
                                            ),
                                            ListTile(
                                              leading: const Icon(
                                                Icons.download,
                                              ),
                                              title: const Text('Download'),
                                              onTap: () {
                                                Navigator.pop(ctx);
                                                widget.onDownload();
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                },
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            )
                            .animate()
                            .fade(duration: 300.ms, delay: (50 * i).ms)
                            .slideX(begin: 0.1, end: 0);
                      },
                    );
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
                onPressed: widget.onMkdir,
              ),
              ActionChip(
                avatar: const Icon(Icons.drive_file_rename_outline),
                label: const Text('Rename'),
                onPressed: () => _handleRenameSelected(entries),
              ),
              ActionChip(
                avatar: const Icon(Icons.delete),
                label: const Text('Delete'),
                onPressed: () => _handleDeleteSelected(entries),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
              ),
              ActionChip(
                avatar: const Icon(Icons.upload_file),
                label: const Text('Upload'),
                onPressed: widget.onUpload,
              ),
              ActionChip(
                avatar: const Icon(Icons.download),
                label: const Text('Download'),
                onPressed: widget.onDownload,
              ),
            ],
          ),
        ).animate().slideY(begin: 1, end: 0, delay: 200.ms),
      ],
    );
  }
}
