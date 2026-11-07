import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/enums.dart';
import '../../../data/database.dart';
import '../../../domain/closed_holding.dart';
import '../../tokens.dart';
import '../transaction_dialogs.dart';
import 'holding_dialogs.dart';

class HoldingActionsButton extends StatelessWidget {
  const HoldingActionsButton({
    super.key,
    required this.onPressed,
    this.compact = false,
  });

  final ValueChanged<Offset> onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 36.0 : 44.0;
    return IconButton(
      tooltip: '更多操作',
      icon: const Icon(Icons.more_horiz, size: 20),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
      ),
      onPressed: () {
        final box = context.findRenderObject()! as RenderBox;
        onPressed(box.localToGlobal(box.size.bottomRight(Offset.zero)));
      },
    );
  }
}

/// Opens the holding actions at the button or pointer position.
Future<void> showHoldingMenu(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding, {
  required Offset at,
}) async {
  final type = AssetType.fromStorage(holding.assetType);
  final closed = isHoldingClosed(holding);
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final anchor = overlay.globalToLocal(at);
  final value = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      anchor & Size.zero,
      Offset.zero & overlay.size,
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
      const PopupMenuDivider(),
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
      await setHoldingArchived(context, ref, holding, true);
    case 'unarchive':
      await setHoldingArchived(context, ref, holding, false);
    case 'delete':
      await _confirmDelete(context, ref, holding);
  }
}

Future<void> setHoldingArchived(
  BuildContext context,
  WidgetRef ref,
  HoldingRow holding,
  bool archived,
) async {
  final dao = ref.read(daoProvider);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await dao.setArchived(holding.id, archived);
  } catch (_) {
    if (context.mounted) {
      messenger.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
    return;
  }
  if (!context.mounted) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(archived ? '已归档' : '已取消归档'),
      action: archived
          ? SnackBarAction(
              label: '撤销',
              onPressed: () async {
                try {
                  await dao.setArchived(holding.id, false);
                } catch (_) {
                  if (messenger.mounted) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('撤销失败，请重试')),
                    );
                  }
                }
              },
            )
          : null,
    ),
  );
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
        '删除「${holding.name}」及其全部相关流水？'
        '收益日历中该产品的历史收益将一并删除，无法恢复。'
        '如需保留历史，可改用「归档」。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await ref.read(daoProvider).deleteHolding(holding.id);
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已删除「${holding.name}」')));
  }
}
