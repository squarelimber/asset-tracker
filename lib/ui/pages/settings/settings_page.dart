import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../services/alert_notification_service.dart';
import '../../../services/backup_service.dart';
import '../../../services/csv_export.dart';
import '../../../services/file_export.dart';
import '../../../services/history_backfill_service.dart';
import '../../components/app_bar_actions.dart';
import '../../components/data_row.dart';
import '../../components/section_header.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';
import 'sync_settings_page.dart';

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
        actions: const [TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(label: '数据备份'),
              Text(
                '所有数据仅保存在本机。建议定期导出备份，可在其他设备导入恢复。',
                style: T.label(),
              ),
              const SizedBox(height: T.s3),
              TerminalCard(
                child: Column(
                  children: [
                    DataRow(
                      leading: const Icon(Icons.upload_file),
                      title: '导出备份',
                      subtitle: const Text('将全部数据保存为 JSON 文件'),
                      trailing: const SizedBox.shrink(),
                      onTap: () => _export(context, ref),
                    ),
                    DataRow(
                      leading: const Icon(Icons.download, color: T.warning),
                      title: '导入备份',
                      subtitle: const Text('从 JSON 文件恢复（将覆盖当前全部数据）'),
                      trailing: const SizedBox.shrink(),
                      onTap: () => _import(context, ref),
                    ),
                    // Derived-data repair, kept inside the existing card so it
                    // adds a row rather than another section/button block.
                    if (!kIsWeb)
                      DataRow(
                        leading: const Icon(Icons.restart_alt),
                        title: '重建历史快照',
                        subtitle: const Text('用收盘价与当日净值重算历史，修正盘中写入的偏差'),
                        trailing: const SizedBox.shrink(),
                        onTap: () => _rebuildHistory(context, ref),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: T.s4),
              const SectionHeader(label: '导出数据'),
              Text('导出为 Excel 可打开的 CSV（UTF-8）。', style: T.label()),
              const SizedBox(height: T.s3),
              TerminalCard(
                child: Column(
                  children: [
                    DataRow(
                      leading: const Icon(Icons.table_chart_outlined),
                      title: '导出持仓 CSV',
                      subtitle: const Text('账户、持仓明细、市值与收益'),
                      trailing: const SizedBox.shrink(),
                      onTap: () => _exportCsv(context, ref, csv: true, holdings: true),
                    ),
                    DataRow(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: '导出流水 CSV',
                      subtitle: const Text('全部交易记录'),
                      trailing: const SizedBox.shrink(),
                      onTap: () => _exportCsv(context, ref, csv: true, holdings: false),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: T.s4),
              const SectionHeader(label: '数据同步'),
              Text('在自建服务器（如 NAS）间同步多台设备的数据。', style: T.label()),
              const SizedBox(height: T.s3),
              TerminalCard(
                child: DataRow(
                  leading: const Icon(Icons.sync),
                  title: '同步设置',
                  subtitle: const Text('服务器地址、访问令牌、立即同步'),
                  trailing: const SizedBox.shrink(),
                  showChevron: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SyncSettingsPage()),
                  ),
                ),
              ),
              const SizedBox(height: T.s4),
              if (!kIsWeb) const _NotificationsSection(),
              if (!kIsWeb) const SizedBox(height: T.s4),
              const SectionHeader(label: '关于'),
              TerminalCard(
                child: Column(
                  children: [
                    const DataRow(
                      leading: Icon(Icons.info_outline, size: 20),
                      title: 'Asset Tracker',
                      subtitle: Text(
                        '本地优先的开源资产追踪工具\n'
                        'MIT License · github.com/squarelimber/asset-tracker\n'
                        '本应用仅供参考，不构成投资建议',
                      ),
                      trailing: SizedBox.shrink(),
                    ),
                    // Installed build id (e.g. 0.9.9+35) — the first thing a
                    // bug report needs, and the one figure this page cannot
                    // derive from the local database.
                    DataRow(
                      leading: const Icon(Icons.tag, size: 20),
                      title: '当前版本',
                      subtitle: Text(
                        ref.watch(appVersionProvider).valueOrNull ?? '读取中…',
                      ),
                      trailing: const SizedBox.shrink(),
                    ),
                  ],
                ),
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
  }) {
    return saveBytesToUser(
      context,
      bytes,
      fileName: fileName,
      mime: mime,
      typeGroup: typeGroup,
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

  /// Rebuilds the whole snapshot history from the historical series.
  ///
  /// Snapshots are written twice for any given day: the backfill derives them
  /// from closing prices (and each day's published NAV), while the live path
  /// rewrites today from intraday quotes. A day whose last write happened
  /// mid-session stays frozen at that intraday value, which skews its own
  /// return and — worse — the next day's, since the daily return is the
  /// difference of two snapshots. This entry point re-derives everything from
  /// the historical series, which is the only way to repair days that are
  /// already recorded.
  Future<void> _rebuildHistory(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重建历史快照'),
        content: const Text(
          '将联网重新抓取历史收盘价与基金净值，重算全部历史净值快照。\n\n'
          '盘中刷新时写下的偏差快照会被修正，收益日历与总览的当日收益随之回到正确数值。'
          '需要数秒，期间请保持网络畅通。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始重建'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _RebuildProgressDialog(),
    ));

    BackfillResult result;
    try {
      result = await ref
          .read(historyBackfillServiceProvider)
          .backfill(forceRebuild: true);
      // Mirror the portfolio page's refresh gate: pull fresh quotes first and
      // only then rewrite today, so every figure — history and today alike —
      // ends up derived from verified-fresh data. A failed refresh simply
      // leaves the day the backfill just wrote in place.
      if (result.ok && !result.historyUnavailable) {
        final refresh = await ref.read(marketServiceProvider).refreshAll();
        if (refresh.allOk) {
          await ref.read(snapshotServiceProvider).ensureTodaySnapshot(force: true);
        }
        ref.invalidate(cnyRatesProvider);
      }
    } catch (error) {
      result = BackfillResult(
        ok: false,
        days: 0,
        holdings: 0,
        message: '重建失败：$error',
      );
    }
    if (navigator.mounted) navigator.pop();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message ?? (result.ok ? '历史快照已重建' : '重建未完成')),
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
    // FX rates for converting foreign-currency holdings to CNY in the
    // holdings export (missing rates fall back to the raw value). Await the
    // future so a cold start never silently exports ×1 "CNY" values.
    final cnyRates = await ref
        .read(cnyRatesProvider.future)
        .catchError((_) => const <String, double>{});

    final csvExport = const CsvExport();
    final content = holdings
        ? csvExport.holdings(allHoldings, accountName, cnyRates: cnyRates)
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

/// Local notifications toggle. Hidden on the web build, where the
/// notification plugin is intentionally not initialized.
class _NotificationsSection extends ConsumerStatefulWidget {
  const _NotificationsSection();

  @override
  ConsumerState<_NotificationsSection> createState() =>
      _NotificationsSectionState();
}

class _NotificationsSectionState extends ConsumerState<_NotificationsSection> {
  bool? _enabled; // null while loading

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value =
        await ref.read(daoProvider).getSetting(AlertNotificationService.enabledKey);
    if (!mounted) return;
    setState(() => _enabled = value != 'false');
  }

  Future<void> _onChanged(bool value) async {
    setState(() => _enabled = value);
    await ref
        .read(daoProvider)
        .setSetting(AlertNotificationService.enabledKey, value ? 'true' : 'false');
    if (!value) return;
    // Re-enabling: make sure the OS permission is actually granted (this
    // re-checks silently if the user fixed it in system settings).
    final notifications = ref.read(notificationServiceProvider);
    await notifications.init();
    final granted = await notifications.refreshPermission();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('未获得系统通知权限，请在系统设置中允许 Asset Tracker 发送通知'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(label: '提醒通知'),
        Text('规则触发时推送本地通知，同一条规则每天最多提醒一次。', style: T.label()),
        const SizedBox(height: T.s3),
        TerminalCard(
          child: DataRow(
            leading: const Icon(Icons.notifications_outlined),
            title: '本地通知',
            subtitle: const Text('风险预警与现金流提醒'),
            trailing: Switch(
              value: _enabled ?? true,
              onChanged: _enabled == null ? null : _onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// Blocking progress indicator for the manual history rebuild. Not dismissible:
/// a rebuild that is interrupted mid-flight is exactly how days end up frozen
/// on intraday prices.
class _RebuildProgressDialog extends StatelessWidget {
  const _RebuildProgressDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: T.s3),
          Expanded(child: Text('正在重建历史快照…', style: T.label())),
        ],
      ),
    );
  }
}
