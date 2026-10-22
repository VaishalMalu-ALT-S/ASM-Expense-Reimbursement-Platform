import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<bool> saveOrDownloadFile({
  required String filename,
  required String content,
  required String mimeType,
}) async {
  try {
    Directory? dir;
    try {
      if (Platform.isAndroid) {
        dir = await getExternalStorageDirectory();
      }
      dir ??= await getApplicationDocumentsDirectory();
    } catch (_) {
      dir = Directory.systemTemp;
    }

    final file = File('${dir.path}/$filename');
    await file.writeAsString(content);

    // Also copy to clipboard as convenience fallback
    await Clipboard.setData(ClipboardData(text: content));

    // Open native Android/iOS share or save prompt
    try {
      await Share.shareXFiles(
        [XFile(file.path, mimeType: mimeType, name: filename)],
        text: 'ASM Corporate Expense Report: $filename',
      );
    } catch (_) {
      // In case native share fails, file is already written and copied to clipboard
    }

    return true;
  } catch (_) {
    return false;
  }
}

