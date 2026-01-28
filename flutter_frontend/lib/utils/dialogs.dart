import 'package:flutter/material.dart';

Future<String?> showInputDialog(
  BuildContext context,
  String title,
  String initial,
) async {
  String? result;
  await showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        onChanged: (v) => result = v,
        controller: TextEditingController(text: initial),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, result),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return result;
}

Future<bool> showConfirmDialog(BuildContext context, String message) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Confirm'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return result ?? false;
}
