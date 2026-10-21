import 'package:flutter/material.dart';

/// Asks the employee to confirm saving an expense the server flagged as a
/// POSSIBLE_DUPLICATE. Returns true only on explicit confirmation.
Future<bool> confirmPossibleDuplicate(BuildContext context, String message) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      icon: const Icon(Icons.content_copy_outlined),
      title: const Text('Possible duplicate expense'),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Save as separate expense')),
      ],
    ),
  );
  return confirmed ?? false;
}
