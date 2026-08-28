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
  });

  final String label;
  final Color color;
  final double value;
  final double pct;
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
              onTap: onSelect == null ? null : () => onSelect!(e),
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
                  const SizedBox(height: T.s1),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: e.pct.clamp(0.0, 1.0),
                      minHeight: 6,
                      backgroundColor: T.surface2,
                      valueColor: AlwaysStoppedAnimation(e.color),
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
                      color: segs[i].color,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.14),
                          Colors.white.withValues(alpha: 0.02),
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
                onTap: onSelect == null ? null : () => onSelect!(e),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: e.color, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: T.s1),
                    Text(e.label, style: const TextStyle(fontSize: 12, color: T.text2)),
                    const SizedBox(width: T.s1),
                    Text(Formats.pct1(e.pct), style: T.mono(size: 12, color: T.text1)),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
