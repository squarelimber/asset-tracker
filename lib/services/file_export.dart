import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Whether the platform has a native save dialog. Android/iOS do not, so
/// exports go through the system share sheet instead.
bool get isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Exports [bytes] as [fileName]: the native save dialog on desktop/web,
/// or the system share sheet on Android/iOS (which have no save dialog).
Future<void> saveBytesToUser(
  BuildContext context,
  Uint8List bytes, {
  required String fileName,
  required String mime,
  required XTypeGroup typeGroup,
}) async {
  if (isMobilePlatform) {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mime, name: fileName)],
      ),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已发起分享')));
    return;
  }
  final location = await getSaveLocation(
    suggestedName: fileName,
    acceptedTypeGroups: [typeGroup],
  );
  if (location == null) return;
  // XFile.saveTo writes through the native file dialog on desktop and
  // triggers a download on the web.
  await XFile.fromData(
    bytes,
    mimeType: mime,
    name: fileName,
  ).saveTo(location.path);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已导出')));
}
