import 'package:flutter/material.dart' hide DataRow;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../sync/sync_api.dart';
import '../../../sync/sync_service.dart';
import '../../components/data_row.dart';
import '../../components/form_fields.dart';
import '../../components/section_header.dart';
import '../../components/terminal_card.dart';
import '../../tokens.dart';

/// Provider that builds the sync service on demand (configuration is read
/// from the local settings inside `sync()`).
final syncServiceProvider = Provider<SyncService>(
  (ref) => SyncService(ref.watch(daoProvider)),
);

class SyncSettingsPage extends ConsumerStatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  ConsumerState<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends ConsumerState<SyncSettingsPage> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _autoSync = false;
  bool _saving = false;
  bool _syncing = false;
  String? _lastSyncAt;
  int? _lastRev;
  String? _error;
  String? _result;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final dao = ref.read(daoProvider);
    final url = await dao.getSetting(SyncSettingsKeys.serverUrl);
    final token = await dao.getSetting(SyncSettingsKeys.token);
    final auto = await dao.getSetting(SyncSettingsKeys.autoSync);
    final lastSyncAt = await dao.getSetting(SyncSettingsKeys.lastSyncAt);
    final lastRev = await dao.getSetting(SyncSettingsKeys.lastRev);
    if (!mounted) return;
    setState(() {
      _urlController.text = url ?? '';
      _tokenController.text = token ?? '';
      _autoSync = auto == 'true';
      _lastSyncAt = lastSyncAt;
      _lastRev = lastRev == null ? null : int.tryParse(lastRev);
    });
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final error = url.isEmpty ? null : validateServerUrl(url);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final dao = ref.read(daoProvider);
    if (url.isEmpty) {
      await dao.setSetting(SyncSettingsKeys.serverUrl, '');
      await dao.setSetting(SyncSettingsKeys.token, '');
    } else {
      await dao.setSetting(SyncSettingsKeys.serverUrl, url);
      await dao.setSetting(SyncSettingsKeys.token, _tokenController.text.trim());
    }
    await dao.setSetting(SyncSettingsKeys.autoSync, _autoSync ? 'true' : 'false');
    if (!mounted) return;
    setState(() {
      _saving = false;
      _result = url.isEmpty ? '已清除同步配置' : '已保存，可立即同步';
    });
  }

  Future<void> _syncNow() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请先填写服务器地址');
      return;
    }
    setState(() {
      _syncing = true;
      _error = null;
      _result = null;
    });
    final result = await ref.read(syncServiceProvider).sync();
    if (!mounted) return;
    if (result.ok && result.dataChanged) {
      // Source rows changed: rebuild the derived history snapshots right
      // away so today's earnings reflects the merged holdings/transactions.
      ref.invalidate(historySyncProvider);
    }
    setState(() {
      _syncing = false;
      if (result.ok) {
        _result = '同步完成：更新 ${result.changed} 行，冲突 ${result.conflicts} 处（自动取较新版本）';
      } else {
        _error = result.message;
      }
      _lastSyncAt = result.ok ? DateTime.now().toIso8601String() : _lastSyncAt;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('数据同步')),
      body: ListView(
        children: [
          const SectionHeader(label: '同步服务器'),
          Text(
            '在 NAS 或局域网服务器上部署同步服务（见仓库 server/ 目录），'
            '填入地址后即可在多台设备间按需同步。所有数据经你自己的服务器传输，不上传第三方。',
            style: T.label(),
          ),
          const SizedBox(height: T.s3),
          TerminalCard(
            child: Column(
              children: [
                TerminalTextField(
                  controller: _urlController,
                  label: '服务器地址',
                  hint: 'http://192.168.1.100:8787',
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: T.s3),
                TerminalTextField(
                  controller: _tokenController,
                  label: '访问令牌（可选）',
                  hint: '与服务器 ASSET_SYNC_TOKEN 一致',
                  obscureText: true,
                ),
                const SizedBox(height: T.s2),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启动时自动同步'),
                  subtitle: const Text('打开应用时后台静默同步一次'),
                  value: _autoSync,
                  onChanged: (v) => setState(() => _autoSync = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: T.s3),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存设置'),
                ),
              ),
              const SizedBox(width: T.s3),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _syncing ? null : _syncNow,
                  icon: _syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(_syncing ? '同步中…' : '立即同步'),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: T.s3),
            Text(_error!, style: T.label(color: T.up)),
          ],
          if (_result != null) ...[
            const SizedBox(height: T.s3),
            Text(_result!, style: T.label()),
          ],
          const SizedBox(height: T.s4),
          const SectionHeader(label: '同步状态'),
          TerminalCard(
            child: DataRow(
              leading: const Icon(Icons.schedule),
              title: '上次同步',
              subtitle: Text(_lastSyncAt == null
                  ? '尚未同步过'
                  : '${_formatTime(_lastSyncAt!)}（服务器版本 $_lastRev）'),
              trailing: const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: T.s3),
          Text(
            '冲突处理：同一行在两台设备上都被修改时，自动采用修改时间较新的一版；'
            '删除在一台设备上生效后，其他设备不会复活该记录。',
            style: T.label(color: T.text3),
          ),
        ],
      ),
    );
  }

  static String _formatTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    final local = t.toLocal();
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${pad(local.month)}-${pad(local.day)} '
        '${pad(local.hour)}:${pad(local.minute)}';
  }
}
