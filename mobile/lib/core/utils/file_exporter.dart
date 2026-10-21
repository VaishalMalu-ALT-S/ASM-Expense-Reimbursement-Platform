import 'file_exporter_stub.dart'
    if (dart.library.html) 'file_exporter_web.dart'
    if (dart.library.io) 'file_exporter_io.dart';

Future<bool> downloadReportFile({
  required String filename,
  required String content,
  String mimeType = 'text/csv;charset=utf-8',
}) =>
    saveOrDownloadFile(
      filename: filename,
      content: content,
      mimeType: mimeType,
    );
