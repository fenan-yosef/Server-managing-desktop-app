import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/login_history.dart';

class LoginTab extends StatefulWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController userController;
  final TextEditingController keyController;
  final TextEditingController passController;
  final String loginStatus;
  final bool isBusy;
  final List<LoginProfile> recentLogins;
  final void Function(LoginProfile) onSelectRecent;
  final void Function(LoginProfile) onRemoveRecent;
  final VoidCallback onClearRecent;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

  const LoginTab({
    super.key,
    required this.hostController,
    required this.portController,
    required this.userController,
    required this.keyController,
    required this.passController,
    required this.loginStatus,
    this.isBusy = false,
    this.recentLogins = const [],
    required this.onSelectRecent,
    required this.onRemoveRecent,
    required this.onClearRecent,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  State<LoginTab> createState() => _LoginTabState();
}

class _LoginTabState extends State<LoginTab> {
  bool _obscurePassword = true;

  Future<void> _browseKey() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      widget.keyController.text = result.files.single.path!;
    }
  }

  @override
  Widget build(BuildContext context) {
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
                      label: widget.isBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Connect'),
                    ),
                  ),
                  if (widget.loginStatus == 'Connected') ...[
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                        ),
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
                        ? Colors.greenAccent
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
}
