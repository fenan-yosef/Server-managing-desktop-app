import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_animate/flutter_animate.dart';

class LoginTab extends StatelessWidget {
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController userController;
  final TextEditingController keyController;
  final TextEditingController passController;
  final String loginStatus;
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
    required this.onConnect,
    required this.onDisconnect,
  });

  Future<void> _browseKey() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      keyController.text = result.files.single.path!;
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
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: hostController,
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
                      controller: portController,
                      decoration: const InputDecoration(labelText: 'Port'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ).animate().fade(delay: 100.ms).moveX(begin: -10, end: 0),
              const SizedBox(height: 16),
              TextField(
                controller: userController,
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
                      controller: keyController,
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
                controller: passController,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.password),
                ),
                obscureText: true,
              ).animate().fade(delay: 400.ms).moveX(begin: -10, end: 0),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onConnect,
                      icon: const Icon(Icons.login),
                      label: const Text('Connect'),
                    ),
                  ),
                  if (loginStatus == 'Connected') ...[
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: onDisconnect,
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
                  loginStatus,
                  style: TextStyle(
                    color: loginStatus == 'Connected'
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
