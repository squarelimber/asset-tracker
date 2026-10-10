import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/enums.dart';
import '../../core/formats.dart';
import '../../core/market_session.dart';
import '../../core/ui_prefs.dart';
import '../../domain/product_monthly_earnings.dart';
import '../../services/history_backfill_service.dart';
import '../tokens.dart';

/// 卡片圆角：与「总资产」概览卡（AssetOverviewCard 自绘的 12）保持一致，
/// 这样滚轮卡和它上下相邻的卡是同一种圆角语言。外层容器与每个立方体面
/// 都要用同一个值 —— 面是铺满整卡的，只圆外层会在四个角留下断掉的棱线。
const double _cardRadius = 12;

/// 总览页的「立方体滚轮」：单个 3D 立方体绕水平轴转动，四个面轮流朝向
/// 观众——今日最佳 / 今日最差 / 本月最佳（口径 A）＋ 无数据占位面。
/// 盒身与面都是淡蓝渐变（正面近白、侧面压深一档）；每面停留一段可配置的
/// 时长（设置页「显示 → 滚动卡停留时间」，默认 2.3s）后 0.9s 翻转 90°；
/// 透视投影呈现立方体滚动感（quad-flip：当前面向下翻出、下一面从上方翻入）。
///
/// 相位 = `_turns + _flip.value`，每 +1 前进 90°，四面按声明顺序
/// 0→1→2→3 循环（见 [_slots]：槽位顺序必须与面的声明顺序一致）。
/// 翻转结束时会同时 `_turns++` 并把 [_flip] 归零，相位因此始终连续。
class RotatingSpotlightCard extends ConsumerStatefulWidget {
  const RotatingSpotlightCard({super.key});

  @override
  ConsumerState<RotatingSpotlightCard> createState() =>
      _RotatingSpotlightCardState();
}

class _RotatingSpotlightCardState extends ConsumerState<RotatingSpotlightCard>
    with SingleTickerProviderStateMixin {
  static const _flipDuration = Duration(milliseconds: 900);

  /// 透视投影系数（见下方 transform 的 setEntry）。值越小纵深越弱。
  /// 取 0.0044 ≈ 卡高从 104 减半前的两倍：纵深强弱看的是 `p·radius`
  /// 这个乘积，radius 减半后要把它补回来，滚动才保持原来的立体感。
  static const _perspective = 0.0044;

  late final AnimationController _flip;

  /// 每面停留时长（毫秒）。先取默认值，等 provider 的首个值到达后由
  /// [_applyHoldMs] 校正成用户设置。
  int _holdMs = defaultSpotlightHoldMs;

  /// 已完成的翻转次数；静止相位 = `_turns`（此时 [_flip] 的值已归零）。
  int _turns = 0;
  Timer? _hold;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _flip = AnimationController(vsync: this, duration: _flipDuration);
    _scheduleNext();
  }

  @override
  void dispose() {
    _disposed = true;
    _hold?.cancel();
    _flip.dispose();
    super.dispose();
  }

  /// 设置页改了停留时长：换用新值并重排下一次翻转。
  ///
  /// 正在翻转时只记下新值、不碰定时器 —— 本轮结束时的 [_scheduleNext]
  /// 自然会用新值。此刻若强行重排，就会多出一个与动画完成回调并行的
  /// 定时器，节奏会开始乱跳。
  void _applyHoldMs(int ms) {
    if (ms == _holdMs) return;
    _holdMs = ms;
    if (_flip.isAnimating) return;
    _scheduleNext();
  }

  /// 停留 [_holdMs] 后翻转到下一面。
  void _scheduleNext() {
    _hold?.cancel();
    _hold = Timer(Duration(milliseconds: _holdMs), () {
      if (_disposed || !mounted) return;
      _flip.forward(from: 0).whenComplete(() {
        if (_disposed || !mounted) return;
        // 相位基准 +1 必须与动画值归零同时发生。只让 _turns++ 而把
        // _flip.value 留在 1.0，相位就多算 90°：停留期间只要重建一次
        // 就会跳到「后面第二面」，下一次翻转又把刚翻走的那面重新滚一遍
        // —— 即「进来的却是要离开的内容，然后突然跳到下一面」。
        _turns++;
        _flip.value = 0;
        _scheduleNext();
      });
    });
  }

  /// 四个面在立方体上的槽位，按滚动出现的先后排列：前 → 上 → 后 → 下。
  /// 相位每 +1（90°）前进一格 ⇒ 当前面向下翻出、下一面从上方翻入，
  /// 于是四面按 [_buildFaces] 的声明顺序 0→1→2→3 循环出现。
  /// [y]/[z] 以 radius 为单位（+y 向下、+z 朝向观众）；[angle] 是该面在
  /// 槽位上的自身朝向——相位 + angle ≡ 0 时它正对观众且文字正向。
  static const List<({double y, double z, double angle})> _slots = [
    (y: 0.0, z: 1.0, angle: 0.0), // 前：今日最佳
    (y: -1.0, z: 0.0, angle: math.pi / 2), // 上：今日最差
    (y: 0.0, z: -1.0, angle: math.pi), // 后：本月最佳
    (y: 1.0, z: 0.0, angle: -math.pi / 2), // 下：资产聚焦
  ];

  @override
  Widget build(BuildContext context) {
    // 归一化到当天 0 点：这个 DateTime 就是 provider 的 family key。
    // 用 DateTime.now() 会把微秒也带进 key —— 每次 rebuild 都新建一个
    // provider（永远停在 loading、取不到数据），旧的在 autoDispose 里被
    // 回收并留下零时长 timer，于是卡片永远停在空态文案「今日休市」。
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final prevDay = DateTime(now.year, now.month, now.day - 1);
    final todayAsync = ref.watch(dayHoldingsBreakdownProvider(today));
    final prevAsync = ref.watch(dayHoldingsBreakdownProvider(prevDay));
    final productsAsync = ref.watch(productEarningsProvider(today.year));
    // 「小眼睛」开关（默认隐藏）：数字面必须一起遮。卡片原先没订阅它，
    // 于是滚到数字面时会把真实金额直接露出来。
    final hidden = ref.watch(hideAmountsProvider);
    // 停留时长来自设置页，必须在 build 里 **watch 出来同步**，不能只 listen。
    //
    // provider 是常驻的（非 autoDispose），设置页读过之后它的值就一直是
    // AsyncData —— 而外壳是普通 ShellRoute + go()，从设置页返回时本卡片是
    // 全新挂载的：此时 ref.listen 不会补发「当前值」(fireImmediately 默认
    // false)，卡片便一直沿用字段上的默认 2.3s，即「改了停留时间没反应」
    // （只有 app 冷启动、且卡片比设置页先读到值时才会偶然生效）。
    //
    // watch 让两条路径收敛到同一个 _applyHoldMs：挂载时已有值、以及运行中
    // 值变化。重复调用是幂等的 —— 值没变就直接返回，不会重排定时器，因此
    // 卡片因行情/provider 重建时节奏不会被重置。
    final holdMs = ref.watch(spotlightHoldMsProvider).valueOrNull;
    if (holdMs != null) _applyHoldMs(holdMs);

    final faces = _buildFaces(
      todayAsync,
      prevAsync,
      productsAsync,
      today,
      hidden: hidden,
    ); // 4 面，索引 0..3（含空占位）。

    return Container(
      // 紧凑长条：只留「标题 + 一行主体」的高，砍掉上下大片空白。
      height: 52,
      decoration: _boxDecoration(),
      clipBehavior: Clip.antiAlias,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final h = constraints.maxHeight;
            final radius = h / 2;
            return AnimatedBuilder(
              animation: _flip,
              builder: (context, _) {
                // 真正的长方体：四个面围绕同一个 X 轴旋转，面中心先
                // 放到「前 / 上 / 后 / 下」四个槽位，再作为整体转动。
                // 相位每 +1（= 90°）：当前面向下翻出，槽位里的下一面从
                // 上方翻入；槽位顺序与面的声明顺序一致，所以四个面按
                // 0→1→2→3 循环出现。
                final theta = -(_turns + _flip.value) * (math.pi / 2);
                final facesWithDepth = <({int index, double z})>[];
                for (var i = 0; i < faces.length; i++) {
                  final slot = _slots[i % _slots.length];
                  final z =
                      (slot.y * math.sin(theta) + slot.z * math.cos(theta)) *
                      radius;
                  facesWithDepth.add((index: i, z: z));
                }
                facesWithDepth.sort((a, b) => a.z.compareTo(b.z));
                final rendered = <Widget>[];
                for (final item in facesWithDepth) {
                  final i = item.index;
                  if (item.z < -radius * 0.05) continue;
                  final facing = (item.z / radius).clamp(0.0, 1.0);
                  final slot = _slots[i % _slots.length];
                  // 绕 X 轴的正交变换：面先按自身朝向转到槽位，再随整体
                  // 旋转。相位 + 自身朝向 ≡ 0 时该面正对观众且文字正向。
                  //
                  // 透视补偿：setEntry(3,2,p) 的透视会把 z≠0 的点除以
                  // (1+p·z)，正面静止时停在 z=+radius 处被整体缩到约
                  // 90%，四周留出缝隙、容器的底色从缝里露出来（即卡片
                  // 外圈那层白底）。这里按面的当前深度预放大
                  // s = 1/(1−p·z) 精确抵消（面上各点 z 相同的前提下
                  // 完全成立；翻转中面是斜的，中心点仍精确、边缘残留
                  // 极小误差，只存在于 0.9s 动画期间）。
                  final s = 1.0 / (1.0 - _perspective * item.z);
                  // 平移用显式矩阵相乘构造：vector_math 2.4 起 translate()
                  // 已弃用（info 级，会被 CI 的 analyze 判红），而替代的
                  // translateByDouble 只在 2.4+ 存在 —— translationValues
                  // 兼容两端。
                  final transform = Matrix4.identity()
                    ..setEntry(3, 2, _perspective)
                    ..multiply(Matrix4.diagonal3Values(s, s, 1.0))
                    ..rotateX(theta)
                    ..multiply(
                      Matrix4.translationValues(
                        0.0,
                        slot.y * radius,
                        slot.z * radius,
                      ),
                    )
                    ..rotateX(slot.angle);
                  rendered.add(
                    Positioned.fill(
                      child: Opacity(
                        // 带 key：Stack 的子节点按深度排序，位置会随帧变化；
                        // 固定 key 让 element 跟着「面」走而不是跟着槽位走。
                        key: ValueKey('spotlight-face-$i'),
                        opacity: facing,
                        child: Transform(
                          alignment: Alignment.center,
                          transform: transform,
                          child: _CubeFaceSurface(
                            shade: facing,
                            child: faces[i].build(context),
                          ),
                        ),
                      ),
                    ),
                  );
                }
                return Stack(clipBehavior: Clip.none, children: rendered);
              },
            );
          },
        ),
      ),
    );
  }

  BoxDecoration _boxDecoration() => BoxDecoration(
    // 长方体外观：淡蓝渐变盒身（与面同色系，翻转缝隙处露出的就是它）
    // + 圆角棱 + 轻投影。圆角与「总资产」卡一致（_cardRadius），不再
    // 用近直角的砖块造型。
    gradient: const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFEDF4FE), Color(0xFFD6E5F9)],
    ),
    borderRadius: BorderRadius.circular(_cardRadius),
    border: Border.all(color: const Color(0xFFC6D8EE)),
    boxShadow: const [
      BoxShadow(color: Color(0x22000000), offset: Offset(0, 3), blurRadius: 10),
    ],
  );

  /// 四个面，索引与 [_slots] 一一对应（0 前 / 1 上 / 2 后 / 3 下），
  /// 因此滚动顺序就是 今日最佳 → 今日最差 → 本月最佳 → 资产聚焦。
  List<_Face> _buildFaces(
    AsyncValue<List<DayHoldingValue>> todayAsync,
    AsyncValue<List<DayHoldingValue>> prevAsync,
    AsyncValue<List<ProductEarnings>> productsAsync,
    DateTime now, {
    required bool hidden,
  }) {
    final out = <_Face>[];
    final spot = _todaySpotlight(todayAsync.value, prevAsync.value);
    final monthBest = _monthBest(productsAsync.value, now);
    final emptyToday = _emptyTodayText(
      loading: todayAsync.isLoading || prevAsync.isLoading,
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
            ? _FaceContent(title: '本月最佳', emptyText: '本月暂无收益数据')
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
    required DateTime today,
  }) {
    if (loading) return '正在加载今日行情…';
    if (aShareSession(today) == MarketSession.weekend) {
      return '今日休市 · 无行情变动';
    }
    return '今日暂无涨跌数据';
  }

  static Widget _hintFace() =>
      const _FaceContent(title: '资产聚焦', emptyText: '点按卡片跳转 · 持仓与产品收益');

  /// 今日最佳/最差：按「今日 Δ(value)」取最大/最小（口径 A），排除负债。
  ({_SpotEntry? winner, _SpotEntry? loser}) _todaySpotlight(
    List<DayHoldingValue>? today,
    List<DayHoldingValue>? prev,
  ) {
    if (today == null || prev == null) return (winner: null, loser: null);
    final prevBy = {for (final p in prev) p.holdingId: p};
    _SpotEntry? winner;
    _SpotEntry? loser;
    for (final t in today) {
      if (t.liability) continue;
      final p = prevBy[t.holdingId];
      final delta = p == null ? t.value : (t.value - p.value);
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

  /// 本月最佳：月内 Δ(value−cost) 最大的产品。
  _SpotEntry? _monthBest(List<ProductEarnings>? products, DateTime now) {
    if (products == null) return null;
    final prefix = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _SpotEntry? best;
    for (final p in products) {
      double? first;
      double? last;
      for (final d in p.daily) {
        if (!d.date.startsWith(prefix)) continue;
        first ??= d.value - d.cost;
        last = d.value - d.cost;
      }
      if (first == null || last == null) continue;
      final delta = last - first;
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

/// 每个长方体面的实体材质：淡蓝渐变。正面（shade=1）接近白、只留一点
/// 蓝；侧面（shade=0，翻转进出时）压深一档 —— 四个面因此读起来像同一块
/// 淡蓝砖的不同受光面，而不是四张各自为政的卡片。
class _CubeFaceSurface extends StatelessWidget {
  const _CubeFaceSurface({required this.shade, required this.child});

  final double shade;
  final Widget child;

  static const _frontTop = Color(0xFFF6FAFF);
  static const _frontBottom = Color(0xFFE2EDFD);
  static const _sideTop = Color(0xFFD3E3F7);
  static const _sideBottom = Color(0xFFC0D5F0);

  @override
  Widget build(BuildContext context) {
    final top = Color.lerp(_sideTop, _frontTop, shade)!;
    final bottom = Color.lerp(_sideBottom, _frontBottom, shade)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [top, bottom],
        ),
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(
          color: Color.lerp(
            const Color(0xFFA8BFDF),
            const Color(0xFFDBE8FA),
            shade,
          )!,
          width: 1,
        ),
      ),
      child: child,
    );
  }
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
    const mainText = Color(0xFF20242E);
    const subText = Color(0xFF8A90A0);
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
              Icon(type!.icon, size: 22, color: type!.color),
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
                        fontSize: 15,
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
                  size: 15,
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
