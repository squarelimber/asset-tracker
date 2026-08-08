import 'package:flutter/material.dart';

import '../../core/formats.dart';

/// A purchase date input with two linked entry modes:
/// - calendar picker (absolute date)
/// - holding days (relative: today - N days)
/// Editing either updates the other automatically.
class PurchaseDateField extends StatefulWidget {
  const PurchaseDateField({super.key, required this.value, this.label = '买入日期'});

  final ValueNotifier<DateTime?> value;
  final String label;

  @override
  State<PurchaseDateField> createState() => _PurchaseDateFieldState();
}

class _PurchaseDateFieldState extends State<PurchaseDateField> {
  late final TextEditingController _daysCtrl;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _daysCtrl = TextEditingController(
      text: _daysOf(widget.value.value),
    );
    widget.value.addListener(_onDateChanged);
  }

  @override
  void dispose() {
    widget.value.removeListener(_onDateChanged);
    _daysCtrl.dispose();
    super.dispose();
  }

  String _daysOf(DateTime? date) {
    if (date == null) return '';
    final days = DateTime.now().difference(date).inDays;
    return days <= 0 ? '0' : '$days';
  }

  void _onDateChanged() {
    if (_syncing) return;
    _syncing = true;
    _daysCtrl.text = _daysOf(widget.value.value);
    _syncing = false;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: widget.value.value ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      _syncing = true;
      widget.value.value = picked;
      _daysCtrl.text = _daysOf(picked);
      _syncing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ValueListenableBuilder<DateTime?>(
          valueListenable: widget.value,
          builder: (context, value, _) => InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: InputDecoration(labelText: widget.label),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_outlined, size: 16),
                  const SizedBox(width: 8),
                  Text(value == null ? '未设置' : Formats.date(value)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _daysCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: false),
          decoration: InputDecoration(
            labelText: '持有天数（选填，与日期二选一）',
            hintText: '如 400 = 400 天前买入',
          ),
          onChanged: (text) {
            final days = int.tryParse(text.trim());
            if (days == null || days < 0) return;
            _syncing = true;
            widget.value.value = DateTime.now().subtract(Duration(days: days));
            _syncing = false;
          },
        ),
      ],
    );
  }
}
