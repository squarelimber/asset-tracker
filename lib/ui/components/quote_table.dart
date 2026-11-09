import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../tokens.dart';
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
    this.sessionLabel,
    this.sessionOpen = false,
  });

  final String group;
  final List<QuoteRow> rows;
  final void Function(QuoteRow)? onQuoteTap;
  final String? sessionLabel;
  final bool sessionOpen;

  @override
  Widget build(BuildContext context) {
    return TerminalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  group,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: T.text1,
                  ),
                ),
              ),
              if (sessionLabel != null)
                Text(
                  sessionLabel!,
                  style: T.label(
                    size: 11,
                    color: sessionOpen ? T.accent : T.text3,
                  ),
                ),
            ],
          ),
          const SizedBox(height: T.s2),
          Row(
            children: [
              Expanded(
                flex: 4,
                child: Text('名称', style: T.label(size: 11, color: T.text3)),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  '最新',
                  textAlign: TextAlign.right,
                  style: T.label(size: 11, color: T.text3),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '涨跌幅',
                  textAlign: TextAlign.right,
                  style: T.label(size: 11, color: T.text3),
                ),
              ),
            ],
          ),
          for (final r in rows)
            InkWell(
              onTap: onQuoteTap == null ? null : () => onQuoteTap!(r),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: T.borderSoft)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            r.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: T.text1,
                            ),
                          ),
                          if (r.unit != null && r.unit != 'point')
                            Text(
                              r.unit!,
                              style: T.label(size: 11, color: T.text3),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          r.fxSymbol != null
                              ? r.price.toStringAsFixed(4)
                              : Formats.num(r.price),
                          style: T.mono(size: 13),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 2,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          '${r.changePct >= 0 ? '+' : ''}${Formats.pct(r.changePct)}',
                          style: T.mono(
                            size: 12,
                            color: T.changeColor(r.changePct),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
