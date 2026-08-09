import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Linked entry for amount-based assets with two modes:
/// - cumulative invested (cost)
/// - current profit (amount - invested)
/// Editing either updates the other automatically (like purchase date
/// vs. holding days). Changes are reported via [onChanged].
class InvestedProfitField extends StatefulWidget {
  const InvestedProfitField({
    super.key,
    required this.amount,
    this.initialInvested,
    required this.onChanged,
  });

  /// Current amount of the asset (listenable, e.g. from the amount field).
  final ValueListenable<double> amount;

  /// Initial cumulative invested value (null = amount).
  final double? initialInvested;

  /// Reports the resulting invested amount (null when unset -> use amount).
  final ValueChanged<double?> onChanged;

  @override
  State<InvestedProfitField> createState() => _InvestedProfitFieldState();
}

class _InvestedProfitFieldState extends State<InvestedProfitField> {
  late final TextEditingController _investedCtrl;
  late final TextEditingController _profitCtrl;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    // Only prefill when the user already recorded an invested amount.
    // A null initialInvested means "not set" -> keep both fields empty
    // (the invested amount defaults to the current amount on save).
    final invested = widget.initialInvested;
    _investedCtrl = TextEditingController(
      text: (invested != null && invested > 0) ? _plainNum(invested) : '',
    );
    _profitCtrl = TextEditingController(
      text: (invested != null && invested > 0) ? _profitText(invested) : '',
    );
    widget.amount.addListener(_onAmountChanged);
    _investedCtrl.addListener(_onInvestedChanged);
    _profitCtrl.addListener(_onProfitChanged);
  }

  @override
  void dispose() {
    widget.amount.removeListener(_onAmountChanged);
    _investedCtrl.removeListener(_onInvestedChanged);
    _profitCtrl.removeListener(_onProfitChanged);
    _investedCtrl.dispose();
    _profitCtrl.dispose();
    super.dispose();
  }

  double get _amount => widget.amount.value;

  /// Plain number without thousands separators, so the text stays
  /// directly parseable by double.tryParse (Formats.smartNum adds commas).
  static String _plainNum(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    var s = v.toStringAsFixed(4);
    s = s.replaceFirst(RegExp(r'\.?0+$'), '');
    return s;
  }

  String _profitText(double invested) {
    if (_amount <= 0) return '';
    return _plainNum(_amount - invested);
  }

  void _emit() {
    final invested = double.tryParse(_investedCtrl.text.trim());
    widget.onChanged(invested);
  }

  void _onAmountChanged() {
    if (_syncing) return;
    _syncing = true;
    final invested = double.tryParse(_investedCtrl.text.trim());
    final profit = double.tryParse(_profitCtrl.text.trim());
    if (invested != null) {
      // Keep invested, refresh profit (works for gains and losses).
      _profitCtrl.text = _profitText(invested);
    } else if (profit != null && _amount > 0) {
      // Only profit entered so far -> derive invested from it.
      _investedCtrl.text = _plainNum(_amount - profit);
    }
    _syncing = false;
    _emit();
  }

  void _onInvestedChanged() {
    if (_syncing) return;
    _syncing = true;
    final invested = double.tryParse(_investedCtrl.text.trim());
    _profitCtrl.text = invested == null ? '' : _profitText(invested);
    _syncing = false;
    _emit();
  }

  void _onProfitChanged() {
    if (_syncing) return;
    _syncing = true;
    final profit = double.tryParse(_profitCtrl.text.trim());
    if (profit != null && _amount > 0) {
      final invested = _amount - profit;
      _investedCtrl.text = invested > 0 ? _plainNum(invested) : '0';
    }
    _syncing = false;
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: _investedCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: '累计投入',
            hintText: '买的时候一共投入多少钱',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _profitCtrl,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            labelText: '当前收益',
            hintText: '填收益会自动算出投入（可填负数）',
          ),
        ),
      ],
    );
  }
}
