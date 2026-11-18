import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/market_session.dart';
import '../../core/ui_prefs.dart';
import '../../domain/earnings_breakdown.dart';
import '../../domain/product_monthly_earnings.dart';
import '../tokens.dart';

/// Desktop shows all three observations at once. Compact layouts retain the
/// configurable rotation, with manual controls and no perspective transform.
class RotatingSpotlightCard extends ConsumerStatefulWidget {
  const RotatingSpotlightCard({super.key});

  @override
  ConsumerState<RotatingSpotlightCard> createState() =>
      _RotatingSpotlightCardState();
}

class _RotatingSpotlightCardState extends ConsumerState<RotatingSpotlightCard> {
  Timer? _timer;
  int _holdMs = defaultSpotlightHoldMs;
  int _index = 0;
  bool _canCycle = false;
  bool _hovering = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _canCycle =
        MediaQuery.sizeOf(context).width < 1100 &&
        !MediaQuery.disableAnimationsOf(context);
    _scheduleNext();
  }

  void _scheduleNext() {
    _timer?.cancel();
    if (!_canCycle || _hovering) return;
    _timer = Timer(Duration(milliseconds: _holdMs), () {
      if (!mounted) return;
      setState(() => _index = (_index + 1) % 4);
      _scheduleNext();
    });
  }

  void _advance() {
    setState(() => _index = (_index + 1) % 4);
    _scheduleNext();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayAsync = ref.watch(earningsBreakdownProvider(today));
    final productsAsync = ref.watch(productEarningsProvider(today.year));
    final hidden = ref.watch(hideAmountsProvider);
    final holdMs = ref.watch(spotlightHoldMsProvider).valueOrNull;
    if (holdMs != null && holdMs != _holdMs) {
      _holdMs = holdMs;
      _scheduleNext();
    }
    final faces = _buildFaces(todayAsync, productsAsync, today, hidden: hidden);
    final desktop = MediaQuery.sizeOf(context).width >= 1100;
    return MouseRegion(
      onEnter: (_) {
        _hovering = true;
        _scheduleNext();
      },
      onExit: (_) {
        _hovering = false;
        _scheduleNext();
      },
      child: Material(
        color: T.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rCard),
          side: const BorderSide(color: T.borderSoft),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 64,
          child: desktop
              ? Row(
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: VerticalDivider(width: 1, color: T.borderSoft),
                        ),
                      Expanded(child: faces[i].build(context)),
                    ],
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 160),
                        child: KeyedSubtree(
                          key: ValueKey(_index),
                          child: faces[_index].build(context),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '下一项',
                      onPressed: _advance,
                      icon: const Icon(
                        Icons.skip_next_outlined,
                        size: 18,
                        color: T.text2,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  List<_Face> _buildFaces(
    AsyncValue<EarningsBreakdown> todayAsync,
    AsyncValue<List<ProductEarnings>> productsAsync,
    DateTime now, {
    required bool hidden,
  }) {
    final out = <_Face>[];
    final spot = _todaySpotlight(todayAsync.valueOrNull);
    final monthBest = _monthBest(productsAsync.valueOrNull, now);
    final emptyToday = _emptyTodayText(
      loading: todayAsync.isLoading,
      unavailable:
          todayAsync.hasError ||
          (todayAsync.valueOrNull?.profit != null &&
              todayAsync.valueOrNull?.verified == false),
      today: now,
    );

    out.add(
      _Face(
        builder: () => spot.winner == null
            ? _FaceContent(title: '今日最佳', emptyText: emptyToday)
            : _FaceContent(
                title: '今日最佳',
                name: spot.winner!.name,
                type: spot.winner!.type,
                delta: spot.winner!.delta,
                hidden: hidden,
                onTap: () => context.push('/holdings'),
              ),
      ),
    );
    out.add(
      _Face(
        builder: () => spot.loser == null
            ? _FaceContent(title: '今日最差', emptyText: emptyToday)
            : _FaceContent(
                title: '今日最差',
                name: spot.loser!.name,
                type: spot.loser!.type,
                delta: spot.loser!.delta,
                hidden: hidden,
                onTap: () => context.push('/holdings'),
              ),
      ),
    );
    out.add(
      _Face(
        builder: () => monthBest == null
            ? _FaceContent(
                title: '本月最佳',
                emptyText: productsAsync.hasError ? '历史明细待更新' : '本月暂无收益数据',
              )
            : _FaceContent(
                title: '本月最佳',
                name: monthBest.name,
                type: monthBest.type,
                delta: monthBest.delta,
                hidden: hidden,
                onTap: () => context.push('/product-earnings'),
              ),
      ),
    );
    out.add(const _Face(builder: _hintFace));
    return out;
  }

  /// 今日两面的空态文案。三种情况都会走到空态，不能一律写「休市」：
  /// ① 数据还没加载完（开市时间也会短暂如此）；② 今天确实非交易日；
  /// ③ 开市但所有持仓当日无涨跌。[today] 是当天 0 点，[aShareSession]
  /// 在 0 点只会返回 weekend（非交易日）或 preOpen，判据稳定。
  static String _emptyTodayText({
    required bool loading,
    required bool unavailable,
    required DateTime today,
  }) {
    if (loading) return '正在加载今日行情…';
    if (unavailable) return '收益明细待更新';
    if (aShareSession(today) == MarketSession.weekend) {
      return '今日休市 · 无行情变动';
    }
    return '今日暂无涨跌数据';
  }

  static Widget _hintFace() =>
      const _FaceContent(title: '资产聚焦', emptyText: '点按卡片跳转 · 持仓与产品收益');

  /// 今日最佳/最差沿用收益日历的产品分解，不将本金流入流出当作收益。
  ({_SpotEntry? winner, _SpotEntry? loser}) _todaySpotlight(
    EarningsBreakdown? today,
  ) {
    if (today == null || !today.verified) return (winner: null, loser: null);
    _SpotEntry? winner;
    _SpotEntry? loser;
    for (final t in today.rows) {
      final delta = t.profit;
      if (delta.abs() < 0.01) continue; // 无变动
      if (winner == null || delta > winner.delta) {
        winner = _SpotEntry(name: t.name, type: t.type, delta: delta);
      }
      if (loser == null || delta < loser.delta) {
        loser = _SpotEntry(name: t.name, type: t.type, delta: delta);
      }
    }
    return (winner: winner, loser: loser);
  }

  /// 本月最佳与产品收益月历使用相同的月度汇总。
  _SpotEntry? _monthBest(List<ProductEarnings>? products, DateTime now) {
    if (products == null) return null;
    _SpotEntry? best;
    for (final p in products) {
      final month = const ProductEarningsCalculator().monthOf(
        p,
        now.year,
        now.month,
      );
      if (month.days == 0) continue;
      final delta = month.profit;
      if (best == null || delta > best.delta) {
        best = _SpotEntry(name: p.name, type: p.type, delta: delta);
      }
    }
    return best;
  }
}

class _SpotEntry {
  const _SpotEntry({
    required this.name,
    required this.type,
    required this.delta,
  });

  final String name;
  final AssetType type;
  final double delta;
}

class _Face {
  const _Face({required this.builder});

  final Widget Function() builder;

  Widget build(BuildContext context) => builder();
}

class _FaceContent extends StatelessWidget {
  const _FaceContent({
    required this.title,
    this.name,
    this.type,
    this.delta,
    this.hidden = false,
    this.onTap,
    this.emptyText,
  });

  final String title;
  final String? name;
  final AssetType? type;
  final double? delta;

  /// 「小眼睛」隐藏态：金额遮罩成 [Formats.masked]，但保留涨跌配色
  /// （与概览卡等其余位置的遮罩口径一致：只遮金额、不遮方向色）。
  final bool hidden;
  final VoidCallback? onTap;
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    const mainText = T.text1;
    const subText = T.text3;
    final has = name != null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        // 纵向只留 4px：卡高减半后内容已顶满，再留 8px 会溢出，
        // 且上下白边正是要砍掉的部分。
        padding: const EdgeInsets.symmetric(horizontal: T.s3, vertical: T.s1),
        child: Row(
          children: [
            if (has) ...[
              Icon(type!.icon, size: 16, color: T.text2),
              const SizedBox(width: T.s2),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 10, color: subText),
                  ),
                  const SizedBox(height: 2),
                  if (has)
                    Text(
                      name!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: mainText,
                      ),
                    )
                  else
                    Text(
                      emptyText ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: subText),
                    ),
                ],
              ),
            ),
            if (has) ...[
              Text(
                hidden
                    ? Formats.masked()
                    : (delta ?? 0) >= 0
                    ? '+${Formats.amount(delta!)}'
                    : Formats.amount(delta!),
                style: T.mono(
                  size: 13,
                  weight: FontWeight.w700,
                  color: T.changeColor(delta ?? 0),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, size: 16, color: subText),
            ],
          ],
        ),
      ),
    );
  }
}
