import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../data/database.dart';
import '../../domain/holding_cost.dart';
import '../../domain/transaction_service.dart';
import '../tokens.dart';

Future<void> showTransactionCorrectionDialog(
  BuildContext context,
  TransactionRow transaction,
) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TransactionCorrectionDialog(transaction),
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('交易已更正')));
  }
}

class _TransactionCorrectionDialog extends ConsumerStatefulWidget {
  const _TransactionCorrectionDialog(this.original);
  final TransactionRow original;

  @override
  ConsumerState<_TransactionCorrectionDialog> createState() =>
      _TransactionCorrectionDialogState();
}

class _TransactionCorrectionDialogState
    extends ConsumerState<_TransactionCorrectionDialog> {
  late final _amount = TextEditingController(
    text: widget.original.amount.toString(),
  );
  late final _quantity = TextEditingController(
    text: widget.original.quantity?.toString() ?? '',
  );
  late final _price = TextEditingController(
    text: widget.original.price?.toString() ?? '',
  );
  TransactionCorrectionPreview? _preview;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _quantity.dispose();
    _price.dispose();
    super.dispose();
  }

  double? _readNumber(TextEditingController controller) =>
      double.tryParse(controller.text.trim());

  Future<void> _showPreview({required bool shares}) async {
    final amount = _readNumber(_amount);
    final quantity = _readNumber(_quantity);
    final price = _readNumber(_price);
    if (amount == null ||
        (shares &&
            (quantity == null ||
                (_price.text.trim().isNotEmpty && price == null)))) {
      setState(() => _error = '请检查成交金额、份额和成交价');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(transactionServiceProvider)
          .previewCorrection(
            widget.original,
            amount: amount,
            quantity: shares ? quantity : widget.original.quantity,
            price: shares ? price : widget.original.price,
          );
      if (mounted) setState(() => _preview = result);
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _error = error.message.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(TransactionCorrectionPreview preview) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref
        .read(transactionServiceProvider)
        .saveCorrection(preview);
    if (!mounted) return;
    if (result.ok) {
      ref.invalidate(historySyncProvider);
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = result.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final original = widget.original;
    final holdings = ref.watch(holdingsProvider).valueOrNull;
    final holding = holdings
        ?.where((row) => row.id == original.holdingId)
        .firstOrNull;
    final type = TransactionType.fromStorage(original.type);
    final trade = type == TransactionType.buy || type == TransactionType.sell;
    final shares =
        trade &&
        !(holding != null &&
            AssetType.fromStorage(holding.assetType).isAmountBased);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        scrollable: true,
        title: Text(preview == null ? '更正交易' : '核对更正影响'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (preview == null) ...[
                Text(
                  '${type.label} · ${Formats.dateTime(original.occurredAt.toLocal())}',
                  style: T.label(),
                ),
                if (shares) ...[
                  _numberField(_quantity, '成交份额'),
                  _numberField(_price, '成交价（可留空）'),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _busy ? null : _fillAmount,
                      child: const Text('按份额和成交价填写金额'),
                    ),
                  ),
                ],
                _numberField(
                  _amount,
                  type == TransactionType.split
                      ? '份额折算比例'
                      : '实际金额（${original.currency}）',
                ),
              ] else ...[
                Text(
                  '${_value(original, shares: shares)} → ${_value(preview.revised, shares: shares)}',
                  style: T.mono(size: 15, weight: FontWeight.w600),
                ),
                const SizedBox(height: T.s2),
                if (preview.reconciledClosedQuantity > 0) ...[
                  Text(
                    '已核对全部买卖份额，本次同时修正历史份额差额 '
                    '${Formats.smartNum(preview.reconciledClosedQuantity)} 份，当前持仓仍为 0。',
                  ),
                  const SizedBox(height: T.s2),
                ],
                if (preview.usesSnapshotPrincipal)
                  Text('部分旧买入本金按已存快照成本核对，收益沿用历史估算口径。', style: T.label()),
                Text('将核对 ${preview.replayedRows} 条关联流水', style: T.label()),
                for (final impact in preview.holdings)
                  _holdingImpact(impact.before, impact.after),
                const SizedBox(height: T.s3),
                if (preview.historicalGain case final gain?)
                  Text(
                    '截至 ${gain.date}，受影响持仓累计盈亏估算 '
                    '${Formats.money(gain.before)} → ${Formats.money(gain.after)}',
                  )
                else
                  Text('现有快照信息不足，历史盈亏金额待重算。', style: T.label()),
                Text(
                  '受影响的历史收益从 ${Formats.date(preview.historyFrom.toLocal())} 起更新。',
                ),
                Text(
                  kIsWeb ? '同步至手机或桌面端后可重建历史快照。' : '各日收益金额会在历史快照重建后更新。',
                  style: T.label(),
                ),
              ],
              if (_error case final error?) ...[
                const SizedBox(height: T.s2),
                Text(error, style: T.label(color: T.warning)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (preview != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _preview = null;
                      _error = null;
                    }),
              child: const Text('返回修改'),
            ),
          FilledButton(
            onPressed: _busy || (trade && holdings == null)
                ? null
                : (preview == null
                      ? () => _showPreview(shares: shares)
                      : () => _save(preview)),
            child: Text(
              _busy
                  ? '处理中…'
                  : preview == null
                  ? '预览变更'
                  : '确认更正',
            ),
          ),
        ],
      ),
    );
  }

  Widget _numberField(TextEditingController controller, String label) =>
      Padding(
        padding: const EdgeInsets.only(top: T.s2),
        child: TextField(
          controller: controller,
          enabled: !_busy,
          decoration: InputDecoration(labelText: label),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
      );

  void _fillAmount() {
    final quantity = _readNumber(_quantity);
    final price = _readNumber(_price);
    if (quantity == null ||
        price == null ||
        !quantity.isFinite ||
        !price.isFinite) {
      setState(() => _error = '请先填写有效份额和成交价');
      return;
    }
    _amount.text = (quantity * price).toStringAsFixed(2);
    setState(() => _error = null);
  }

  String _value(TransactionRow row, {required bool shares}) {
    if (row.type == TransactionType.split.storageName) {
      return '×${Formats.smartNum(row.amount)}';
    }
    final amount = Formats.money(row.amount, row.currency);
    if (shares &&
        (row.type == 'buy' || row.type == 'sell') &&
        row.quantity != null) {
      final price = row.price == null
          ? ''
          : ' × ${Formats.smartNum(row.price!)}';
      return '${Formats.smartNum(row.quantity!)} 份$price · $amount';
    }
    return amount;
  }

  Widget _holdingImpact(HoldingRow before, HoldingRow after) {
    final type = AssetType.fromStorage(before.assetType);
    final shares = !type.isAmountBased && type != AssetType.liability;
    String quantity(HoldingRow row) => shares
        ? '${Formats.smartNum(row.quantity)} 份'
        : Formats.money(row.quantity, row.currency);
    double principal(HoldingRow row) =>
        shares ? row.quantity * row.costPrice : effectiveCostOf(row);
    double gain(HoldingRow row) =>
        (shares ? row.quantity * row.latestPrice : row.quantity) -
        principal(row);
    return Padding(
      padding: const EdgeInsets.only(top: T.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(before.name, style: T.label(size: 13, color: T.text1)),
          Text(
            '${shares ? '持仓份额' : '余额'} ${quantity(before)} → ${quantity(after)}',
          ),
          if (type != AssetType.liability &&
              (gain(before) - gain(after)).abs() >= .005)
            Text(
              '当前估算盈亏 ${Formats.money(gain(before), before.currency)} → '
              '${Formats.money(gain(after), after.currency)}',
              style: T.label(),
            ),
        ],
      ),
    );
  }
}
