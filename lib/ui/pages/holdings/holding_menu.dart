import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../tokens.dart';
import '../transaction_dialogs.dart';
import 'holding_dialogs.dart';

/// Context menu for a holding row: 记交易 / 更新价格 / 编辑 / 归档 / 删除.
///
/// [at] is the global position to anchor the menu (right-click or
/// long-press location); when omitted the menu opens at the bottom of
/// [context]'s row.
Future<void> showHoldingMenu(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding, {
  Offset? at,
}) async {
  final type = AssetType.fromStorage(holding.assetType);
  final closed = isHoldingClosed(holding);
  final box = context.findRenderObject();
  final Offset anchor;
  if (at != null) {
    anchor = at;
  } else if (box is RenderBox) {
    final origin = box.localToGlobal(Offset.zero);
    anchor = Offset(origin.dx, origin.dy + box.size.height);
  } else {
    anchor = const Offset(0, 0);
  }
  final size = MediaQuery.sizeOf(context);
  final value = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      anchor.dx.clamp(0.0, size.width - 160),
      anchor.dy.clamp(0.0, size.height - 10),
      0,
      0,
    ),
    items: [
      if (!closed && type != AssetType.liability)
        _item('txn', Icons.receipt_long, '记一笔交易'),
      if (!closed) _item('price', Icons.update, '更新价格'),
      _item('edit', Icons.edit, '编辑'),
      _item(
        holding.archived ? 'unarchive' : 'archive',
        Icons.archive_outlined,
        holding.archived ? '取消归档' : '归档',
      ),
      const PopupMenuItem<String>(
        value: 'sep',
        enabled: false,
        height: 12,
        child: SizedBox.shrink(),
      ),
      _item('delete', Icons.delete_outline, '删除', color: T.up),
    ],
  );
  if (value == null || !context.mounted) return;
  switch (value) {
    case 'txn':
      await showHoldingTransactionDialog(context, ref, holding);
    case 'price':
      await showUpdatePriceDialog(context, ref, holding);
    case 'edit':
      await showEditHoldingDialog(context, ref, holding);
    case 'archive':
      await ref.read(daoProvider).setArchived(holding.id, true);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已归档')));
      }
    case 'unarchive':
      await ref.read(daoProvider).setArchived(holding.id, false);
    case 'delete':
      await _confirmDelete(context, ref, holding);
  }
}

PopupMenuItem<String> _item(
  String value,
  IconData icon,
  String label, {
  Color? color,
}) {
  return PopupMenuItem<String>(
    value: value,
    child: Row(
      children: [
        Icon(icon, size: 18, color: color ?? T.text2),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color ?? T.text1)),
      ],
    ),
  );
}

Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除持仓'),
      content: Text(
        '删除「${holding.name}」？历史流水与收益日历记录会保留，'
        '但持仓本身无法恢复。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await ref.read(daoProvider).deleteHolding(holding.id);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已删除「${holding.name}」')));
  }
}
