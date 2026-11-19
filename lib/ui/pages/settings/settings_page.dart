import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../core/responsive.dart';
import '../../../core/ui_prefs.dart';
import '../../../services/alert_notification_service.dart';
import '../../../services/backup_service.dart';
import '../../../services/csv_export.dart';
import '../../../services/file_export.dart';
import '../../components/app_bar_actions.dart';
import '../../components/data_row.dart';
import '../../components/rebuild_history_dialog.dart';
import '../../components/secondary_page_back_button.dart';
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
        leading: const SecondaryPageBackButton(),
        title: const Text('设置'),
        actions: const [TerminalAppBarActions()],
      ),
      body: ResponsiveShell(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(label: '数据备份'),
              Text('数据默认保存在本机。配置同步后会与所选服务器交换数据。可定期导出备份用于恢复。', style: T.label()),
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
                      subtitle: const Text('从 JSON 文件恢复（将覆盖本机数据）'),
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
                        onTap: () => showRebuildHistoryDialog(context, ref),
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
                      onTap: () =>
                          _exportCsv(context, ref, csv: true, holdings: true),
                    ),
                    DataRow(
                      leading: const Icon(Icons.receipt_long_outlined),
                      title: '导出流水 CSV',
                      subtitle: const Text('全部交易记录'),
                      trailing: const SizedBox.shrink(),
                      onTap: () =>
                          _exportCsv(context, ref, csv: true, holdings: false),
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
              const SectionHeader(label: '显示'),
              const SizedBox(height: T.s3),
              const TerminalCard(
                child: Column(
                  children: [_AmountVisibilityRow(), _SpotlightHoldRow()],
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

  Future<void> _export(
    BuildContext context,
    WidgetRef ref, {
    String? fileName,
  }) async {
    final json = await ref.read(backupServiceProvider).exportJson();
    if (!context.mounted) return;
    await _exportFile(
      context,
      Uint8List.fromList(utf8.encode(json)),
      fileName: fileName ?? backupFileName(),
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
    final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: [typeGroup]);
    } catch (_) {
      if (context.mounted) _showImportMessage(context, '无法打开文件选择器', ok: false);
      return;
    }
    final backupFile = file;
    if (backupFile == null) return;
    if (!context.mounted) return;
    final service = ref.read(backupServiceProvider);
    final String json;
    final BackupPreview preview;
    try {
      json = utf8.decode(await backupFile.readAsBytes());
      preview = service.previewJson(json);
    } on FormatException catch (error) {
      if (context.mounted) {
        _showImportMessage(context, error.message, ok: false);
      }
      return;
    } catch (_) {
      if (context.mounted) _showImportMessage(context, '无法读取备份文件', ok: false);
      return;
    }
    if (!context.mounted) return;

    final result = await showDialog<ImportResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var busy = false;
        String? error;
        return StatefulBuilder(
          builder: (dialogContext, setState) => PopScope(
            canPop: !busy,
            child: AlertDialog(
              scrollable: true,
              title: const Text('核对备份'),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(backupFile.name, style: T.label()),
                  if (preview.exportedAt case final time?)
                    Text('备份时间 ${Formats.dateTime(time.toLocal())}')
                  else
                    const Text('文件未记录备份时间'),
                  const SizedBox(height: T.s2),
                  Text('${preview.accounts} 个账户 · ${preview.holdings} 项持仓'),
                  Text(
                    '${preview.transactions} 条流水 · ${preview.snapshots} 个快照',
                  ),
                  const SizedBox(height: T.s2),
                  const Text('恢复会覆盖当前账本。再次同步时，服务器上保留的记录可能重新合入。'),
                  TextButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            setState(() {
                              busy = true;
                              error = null;
                            });
                            try {
                              final timestamp = DateTime.now()
                                  .toIso8601String()
                                  .split('.')
                                  .first
                                  .replaceAll(':', '');
                              await _export(
                                dialogContext,
                                ref,
                                fileName: '恢复前_asset_tracker_$timestamp.json',
                              );
                            } catch (_) {
                              if (dialogContext.mounted) error = '当前账本导出失败，请重试';
                            } finally {
                              if (dialogContext.mounted) {
                                setState(() => busy = false);
                              }
                            }
                          },
                    icon: const Icon(Icons.save_alt),
                    label: const Text('先导出当前账本'),
                  ),
                  if (error != null)
                    Text(error!, style: T.label(color: T.warning)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: T.up),
                  onPressed: busy
                      ? null
                      : () async {
                          setState(() {
                            busy = true;
                            error = null;
                          });
                          final result = await service.importJson(json);
                          if (!dialogContext.mounted) return;
                          if (result.ok) {
                            Navigator.pop(dialogContext, result);
                          } else {
                            setState(() {
                              busy = false;
                              error = result.message;
                            });
                          }
                        },
                  child: const Text('覆盖导入'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (result != null && context.mounted) {
      _showImportMessage(context, result.message, ok: true);
    }
  }

  void _showImportMessage(
    BuildContext context,
    String message, {
    required bool ok,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: ok ? null : T.up),
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
    // Await the rates before export. Unavailable conversions stay blank.
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

class _AmountVisibilityRow extends ConsumerWidget {
  const _AmountVisibilityRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preference = ref.watch(hideAmountsOnStartupProvider);
    return DataRow(
      leading: const Icon(Icons.visibility_outlined),
      title: '启动时隐藏金额',
      subtitle: const Text('关闭时打开应用默认显示金额，小眼睛可临时切换'),
      trailing: Switch(
        value: preference.valueOrNull ?? false,
        onChanged: preference.hasValue
            ? (hide) async {
                try {
                  await ref
                      .read(daoProvider)
                      .setSetting(hideAmountsOnStartupKey, '$hide');
                  if (!context.mounted) return;
                  ref.read(hideAmountsProvider.notifier).state = hide;
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('保存设置失败，请重试')));
                  }
                }
              }
            : null,
      ),
    );
  }
}

/// 焦点滚轮卡的停留时长选择器。
class _SpotlightHoldRow extends ConsumerWidget {
  const _SpotlightHoldRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms =
        ref.watch(spotlightHoldMsProvider).valueOrNull ??
        defaultSpotlightHoldMs;
    return DataRow(
      leading: const Icon(Icons.slow_motion_video_outlined),
      title: '滚动卡停留时间',
      subtitle: const Text('移动端每项停留时间；减少动态效果时可手动切换'),
      trailing: Text(
        spotlightHoldLabel(ms),
        style: T.mono(size: 13, color: T.text2),
      ),
      showChevron: true,
      onTap: () => _pick(context, ref, ms),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref, int current) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('滚动卡停留时间'),
        children: [
          for (final ms in spotlightHoldChoicesMs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, ms),
              child: Row(
                children: [
                  Expanded(child: Text(spotlightHoldLabel(ms))),
                  if (ms == current) const Icon(Icons.check, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(daoProvider).setSetting(spotlightHoldMsKey, '$picked');
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
    final value = await ref
        .read(daoProvider)
        .getSetting(AlertNotificationService.enabledKey);
    if (!mounted) return;
    setState(() => _enabled = value != 'false');
  }

  Future<void> _onChanged(bool value) async {
    setState(() => _enabled = value);
    await ref
        .read(daoProvider)
        .setSetting(
          AlertNotificationService.enabledKey,
          value ? 'true' : 'false',
        );
    if (!value) return;
    // Re-enabling: make sure the OS permission is actually granted (this
    // re-checks silently if the user fixed it in system settings).
    final notifications = ref.read(notificationServiceProvider);
    await notifications.init();
    final granted = await notifications.refreshPermission();
    if (!granted && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未获得系统通知权限，请在系统设置中允许 Asset Tracker 发送通知')),
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
