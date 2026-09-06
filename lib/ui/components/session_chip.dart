import 'package:flutter/material.dart';

import '../tokens.dart';

/// A-share trading session derived from the local clock.
///
/// No holiday calendar is consulted: a holiday still reads as 未开盘/已收盘.
enum MarketSession { preOpen, open, lunch, closed, weekend }

MarketSession aShareSession([DateTime? now]) {
  final n = now ?? DateTime.now();
  if (n.weekday == DateTime.saturday || n.weekday == DateTime.sunday) {
    return MarketSession.weekend;
  }
  final t = n.hour * 60 + n.minute;
  if (t >= 9 * 60 + 30 && t < 11 * 60 + 30) return MarketSession.open;
  if (t >= 13 * 60 && t < 15 * 60) return MarketSession.open;
  if (t < 9 * 60 + 30) return MarketSession.preOpen;
  if (t < 13 * 60) return MarketSession.lunch;
  return MarketSession.closed;
}

/// Compact chip showing the current A-share session (交易中 / 午休 / 未开盘 /
/// 已收盘 / 休市). Pass [session] to pin a value (e.g. in tests).
class SessionChip extends StatelessWidget {
  const SessionChip({super.key, this.session});

  final MarketSession? session;

  @override
  Widget build(BuildContext context) {
    final s = session ?? aShareSession();
    final (label, color, active) = switch (s) {
      MarketSession.open => ('交易中', T.accent, true),
      MarketSession.lunch => ('午休', T.text2, false),
      MarketSession.preOpen => ('未开盘', T.text2, false),
      MarketSession.closed => ('已收盘', T.text2, false),
      MarketSession.weekend => ('休市', T.text3, false),
    };
    return Tooltip(
      message: 'A 股交易时段（按本地时间，不含节假日判断）',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: active ? 0.14 : 0.06),
          borderRadius: BorderRadius.circular(T.rPill),
          border: Border.all(color: color.withValues(alpha: active ? 0.4 : 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
