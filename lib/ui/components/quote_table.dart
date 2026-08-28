import 'package:flutter/material.dart' hide DataRow;

import '../../core/formats.dart';
import '../tokens.dart';
import 'data_row.dart';
import 'delta_text.dart';
import 'section_header.dart';
import 'terminal_card.dart';

class QuoteRow {
  const QuoteRow({
    required this.code,
    required this.name,
    required this.price,
    required this.change,
    required this.changePct,
    this.unit,
    this.fxSymbol,
  });

  final String code;
  final String name;
  final double price;
  final double change;
  final double changePct;
  final String? unit;
  final String? fxSymbol;
}

class QuoteTable extends StatelessWidget {
  const QuoteTable({
    super.key,
    required this.group,
    required this.rows,
    this.onQuoteTap,
  });

  final String group;
  final List<QuoteRow> rows;
  final void Function(QuoteRow)? onQuoteTap;

  @override
  Widget build(BuildContext context) {
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(label: group),
          for (final r in rows)
            DataRow(
              title: r.name,
              subtitle: Text(
                r.fxSymbol ?? r.code,
                style: T.mono(size: 11, color: T.text3),
              ),
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    r.fxSymbol != null
                        ? r.price.toStringAsFixed(4)
                        : Formats.num(r.price),
                    style: T.mono(size: 14),
                  ),
                  DeltaText(
                    value: r.changePct,
                    text: '${r.changePct >= 0 ? '+' : ''}${Formats.pct1(r.changePct)}',
                  ),
                ],
              ),
              onTap: onQuoteTap == null ? null : () => onQuoteTap!(r),
            ),
        ],
      ),
    );
  }
}
