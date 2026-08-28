import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../ui/components/app_bar_actions.dart';
import '../../ui/tokens.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../services/backup_service.dart';
import '../../services/csv_export.dart';
import 'sync_settings_page.dart';

/// Whether the platform has a native save dialog. Android/iOS do not, so
/// exports go through the system share sheet instead.
bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(daoProvider)),
);

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [const TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('数据备份', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                '所有数据仅保存在本机。建议定期导出备份，可在其他设备导入恢复。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.upload_file),
                      title: const Text('导出备份'),
                      subtitle: const Text('将全部数据保存为 JSON 文件'),
                      onTap: () => _export(context, ref),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(
                        Icons.download,
                        color: T.warning,
                      ),
                      title: const Text('导入备份'),
                      subtitle: const Text('从 JSON 文件恢复（将覆盖当前全部数据）'),
                      onTap: () => _import(context, ref),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Text('导出数据', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                '导出为 Excel 可打开的 CSV（UTF-8）。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.table_chart_outlined),
                      title: const Text('导出持仓 CSV'),
                      subtitle: const Text('账户、持仓明细、市值与收益'),
                      onTap: () =>
                          _exportCsv(context, ref, csv: true, holdings: true),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: const Text('导出流水 CSV'),
                      subtitle: const Text('全部交易记录'),
                      onTap: () =>
                          _exportCsv(context, ref, csv: true, holdings: false),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Text('数据同步', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                '在自建服务器（如 NAS）间同步多台设备的数据。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('同步设置'),
                  subtitle: const Text('服务器地址、访问令牌、立即同步'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SyncSettingsPage()),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Text('关于', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const ListTile(
                dense: true,
                leading: Icon(Icons.info_outline, size: 20),
                title: Text('Asset Tracker'),
                subtitle: Text(
                  '本地优先的开源资产追踪工具\n'
                  'MIT License · github.com/squarelimber/asset-tracker\n'
                  '本应用仅供参考，不构成投资建议',
                ),
                isThreeLine: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final json = await ref.read(backupServiceProvider).exportJson();
    if (!context.mounted) return;
    await _exportFile(
      context,
      Uint8List.fromList(utf8.encode(json)),
      fileName: backupFileName(),
      mime: 'application/json',
      typeGroup: const XTypeGroup(label: 'JSON', extensions: ['json']),
    );
  }

  /// Exports [bytes] as [fileName]: the native save dialog on desktop/web,
  /// or the system share sheet on Android/iOS (which have no save dialog).
  Future<void> _exportFile(
    BuildContext context,
    Uint8List bytes, {
    required String fileName,
    required String mime,
    required XTypeGroup typeGroup,
  }) async {
    if (_isMobilePlatform) {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mime, name: fileName)],
        ),
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已发起分享')));
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已导出')));
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    const typeGroup = XTypeGroup(label: 'JSON', extensions: ['json']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    if (!context.mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('导入将覆盖当前全部数据，且无法撤销。确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: T.up),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('覆盖导入'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Read as raw bytes and decode UTF-8 explicitly: cross_file's
    // XFile.readAsString() maps bytes 1:1 (Latin-1) on the Android bytes
    // path, which garbles Chinese characters.
    final bytes = await file.readAsBytes();
    final json = utf8.decode(bytes);
    final result = await ref.read(backupServiceProvider).importJson(json);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message),
        backgroundColor: result.ok ? null : T.up,
      ),
    );
  }

  Future<void> _exportCsv(
    BuildContext context,
    WidgetRef ref, {
    required bool csv,
    required bool holdings,
  }) async {
    final dao = ref.read(daoProvider);
    final accounts = await dao.getAccounts();
    final accountName = {for (final a in accounts) a.id: a.name};
    final allHoldings = await dao.getHoldings();
    final holdingName = {for (final h in allHoldings) h.id: h.name};

    final csvExport = const CsvExport();
    final content = holdings
        ? csvExport.holdings(allHoldings, accountName)
        : csvExport.transactions(await dao.getTransactions(), holdingName);

    final fileName = holdings ? '持仓_${todayKey()}.csv' : '流水_${todayKey()}.csv';
    if (!context.mounted) return;
    await _exportFile(
      context,
      Uint8List.fromList(utf8.encode(content)),
      fileName: fileName,
      mime: 'text/csv',
      typeGroup: const XTypeGroup(label: 'CSV', extensions: ['csv']),
    );
  }
}
