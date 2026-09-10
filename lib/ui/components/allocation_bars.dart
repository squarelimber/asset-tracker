import 'package:flutter/material.dart';

import '../../core/formats.dart';
import '../../core/responsive.dart';
import '../tokens.dart';

class AllocationEntry {
  const AllocationEntry({
    required this.label,
    required this.color,
    required this.value,
    required this.pct,
    this.targetPct,
    this.selectable = true,
  });

  final String label;
  final Color color;
  final double value;
  final double pct;

  /// Optional target (plan) share for this slice. When set, the bar shows the
  /// planned position as a marker so the user can rebalance toward it.
  final double? targetPct;

  /// Whether tapping the slice filters the holdings page. The merged
  /// "其他" pseudo-slice (desktop top-5 view) has no matching category
  /// filter, so it must not pretend to be clickable.
  final bool selectable;
}

class AllocationBars extends StatelessWidget {
  const AllocationBars({
    super.key,
    required this.entries,
    this.onSelect,
    this.amountFormat,
  });

  final List<AllocationEntry> entries;
  final void Function(AllocationEntry)? onSelect;

  /// Amount text override (e.g. masked `****` when hideAmounts is on).
  final String Function(double)? amountFormat;

  /// Top 5 + merged 其他 (desktop stacked-bar segments).
  static List<AllocationEntry> top5WithOther(List<AllocationEntry> entries) {
    if (entries.length <= 5) return entries;
    final other = AllocationEntry(
      label: '其他',
      color: T.text3,
      value: entries.skip(5).fold(0.0, (a, e) => a + e.value),
      pct: entries.skip(5).fold(0.0, (a, e) => a + e.pct),
      selectable: false,
    );
    return [...entries.sublist(0, 5), other];
  }

  @override
  Widget build(BuildContext context) {
    return Responsive.isDesktop(context)
        ? _DesktopBars(entries: entries, onSelect: onSelect, amountFormat: amountFormat)
        : _BarList(entries: entries, onSelect: onSelect, amountFormat: amountFormat);
  }
}

class _BarList extends StatelessWidget {
  const _BarList({required this.entries, required this.onSelect, this.amountFormat});

  final List<AllocationEntry> entries;
  final void Function(AllocationEntry)? onSelect;
  final String Function(double)? amountFormat;

  @override
  Widget build(BuildContext context) {
    final fmt = amountFormat ?? Formats.amountCompact;
    return Column(
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: T.s3),
            child: InkWell(
              onTap: (onSelect == null || !e.selectable) ? null : () => onSelect!(e),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(e.label, style: const TextStyle(fontSize: 13, color: T.text1))),
                      Text(fmt(e.value), style: T.mono(size: 12, color: T.text2)),
                      const SizedBox(width: T.s2),
                      Text(Formats.pct1(e.pct), style: T.mono(size: 12, color: T.text2)),
                    ],
                  ),
                  if (e.targetPct != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: _DeviationText(actual: e.pct, target: e.targetPct!),
                    ),
                  const SizedBox(height: T.s1),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final targetX = (e.targetPct ?? 0)
                            .clamp(0.0, 1.0)
                            .toDouble();
                        return Stack(
                          children: [
                            LinearProgressIndicator(
                              value: e.pct.clamp(0.0, 1.0),
                              minHeight: 6,
                              backgroundColor: T.surface2,
                              valueColor: AlwaysStoppedAnimation(e.color),
                            ),
                            if (e.targetPct != null && targetX > 0 && targetX < 1)
                              Positioned(
                                left: (constraints.maxWidth * targetX) - 1,
                                top: 0,
                                bottom: 0,
                                child: Container(
                                  width: 2,
                                  color: T.text1,
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _DesktopBars extends StatelessWidget {
  const _DesktopBars({
    required this.entries,
    required this.onSelect,
    this.amountFormat,
  });

  final List<AllocationEntry> entries;
  final void Function(AllocationEntry)? onSelect;
  final String Function(double)? amountFormat;

  @override
  Widget build(BuildContext context) {
    final segs = AllocationBars.top5WithOther(entries);
    return Column(
      children: [
        SizedBox(
          height: 22,
          child: Row(
            children: [
              for (var i = 0; i < segs.length; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  flex: (segs[i].pct * 1000).round().clamp(1, 1 << 16),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.lerp(segs[i].color, Colors.white, 0.12) ??
                              segs[i].color,
                          segs[i].color,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    alignment: Alignment.center,
                    child: segs[i].pct >= 0.10
                        ? FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              Formats.pct1(segs[i].pct),
                              style: T.mono(size: 11, color: Colors.black.withValues(alpha: 0.75), weight: FontWeight.w700),
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: T.s3),
        Wrap(
          spacing: T.s4,
          runSpacing: T.s2,
          children: [
            for (final e in segs)
              InkWell(
                onTap: (onSelect == null || !e.selectable) ? null : () => onSelect!(e),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: T.s1),
                    Text(e.label, style: const TextStyle(fontSize: 12, color: T.text2)),
                    const SizedBox(width: T.s1),
                    Text(
                      e.targetPct != null
                          ? '${Formats.pct1(e.pct)} / 目标${Formats.pct1(e.targetPct!)}'
                          : Formats.pct1(e.pct),
                      style: T.mono(size: 12, color: T.text1),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// "目标 X% 偏差 +Y.Y%" line shown under each slice when a plan exists.
/// Deviation is the gap in percentage points; beyond ±5pp it is highlighted
/// red (overweight) / green (underweight) to flag rebalancing.
class _DeviationText extends StatelessWidget {
  const _DeviationText({required this.actual, required this.target});

  final double actual;
  final double target;

  @override
  Widget build(BuildContext context) {
    final dev = actual - target;
    final color = dev > 0.05
        ? T.up
        : dev < -0.05
            ? T.down
            : T.text3;
    final sign = dev >= 0 ? '+' : '';
    return Row(
      children: [
        Text('目标 ${Formats.pct1(target)}', style: T.mono(size: 11, color: T.text3)),
        const SizedBox(width: T.s1),
        Text(
          '偏差 $sign${Formats.pct1(dev)}',
          style: T.mono(size: 11, color: color),
        ),
      ],
    );
  }
}
