import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../../services/backup_service.dart';
import '../../services/csv_export.dart';

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(daoProvider)),
);

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ResponsiveShell(
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
                    leading: const Icon(Icons.download, color: AppColors.warning),
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
                    onTap: () => _exportCsv(context, ref, csv: true, holdings: true),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: const Text('导出流水 CSV'),
                    subtitle: const Text('全部交易记录'),
                    onTap: () => _exportCsv(context, ref, csv: true, holdings: false),
                  ),
                ],
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
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final json = await ref.read(backupServiceProvider).exportJson();
    const suggested = XTypeGroup(label: 'JSON', extensions: ['json']);
    final location = await getSaveLocation(suggestedName: backupFileName(), acceptedTypeGroups: [suggested]);
    if (location == null) return;
    final file = File(location.path);
    await file.writeAsString(json);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出到 ${location.path}')),
    );
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.up),
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
        backgroundColor: result.ok ? null : AppColors.up,
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

    const typeGroup = XTypeGroup(label: 'CSV', extensions: ['csv']);
    final location = await getSaveLocation(
      suggestedName: holdings ? '持仓_${todayKey()}.csv' : '流水_${todayKey()}.csv',
      acceptedTypeGroups: [typeGroup],
    );
    if (location == null) return;
    final file = File(location.path);
    await file.writeAsString(content, encoding: utf8);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出 ${location.path}')),
    );
  }
}
