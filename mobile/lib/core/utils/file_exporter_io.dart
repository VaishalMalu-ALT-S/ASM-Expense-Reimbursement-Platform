import 'dart:io';
import 'package:flutter/services.dart';

Future<bool> saveOrDownloadFile({
  required String filename,
  required String content,
  required String mimeType,
}) async {
  try {
    final tempDir = Directory.systemTemp;
    final file = File('${tempDir.path}/$filename');
    await file.writeAsString(content);
    await Clipboard.setData(ClipboardData(text: content));
    return true;
  } catch (_) {
    return false;
  }
}
