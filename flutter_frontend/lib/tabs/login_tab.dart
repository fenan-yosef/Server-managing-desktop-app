import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

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
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: hostController,
            decoration: const InputDecoration(labelText: 'Host'),
          ),
          TextField(
            controller: portController,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: userController,
            decoration: const InputDecoration(labelText: 'Username'),
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: keyController,
                  decoration: const InputDecoration(labelText: 'SSH Key'),
                ),
              ),
              IconButton(onPressed: _browseKey, icon: const Icon(Icons.folder)),
            ],
          ),
          TextField(
            controller: passController,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
          ),
          Row(
            children: [
              ElevatedButton(
                onPressed: onConnect,
                child: const Text('Connect'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: onDisconnect,
                child: const Text('Disconnect'),
              ),
            ],
          ),
          Text(loginStatus),
        ],
      ),
    );
  }
}
