import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/core/formats.dart';
import 'package:asset_tracker/core/ui_prefs.dart';
import 'package:asset_tracker/domain/product_monthly_earnings.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';
import 'package:asset_tracker/ui/components/rotating_spotlight_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 立方体滚轮的相位回归测试。
///
/// 相位是 `_turns + _flip.value`，它必须连续：`_turns` 在**翻转开始时**
/// 前进（与动画值归零同时发生）。旧实现等翻转结束才 +1、而动画值仍停在
/// 1.0，于是相位多算 90° —— 停留期间只要重建一次，画面就跳到「后面第二
/// 面」，随后的翻转又把刚翻走的那面重新滚一遍。真实页面里 provider 随时
/// 会触发重建，所以这里在每次停留期主动 invalidate 一次来复现。
void main() {
  const faceKeys = [
    ValueKey('spotlight-face-0'), // 今日最佳
    ValueKey('spotlight-face-1'), // 今日最差
    ValueKey('spotlight-face-2'), // 本月最佳
    ValueKey('spotlight-face-3'), // 资产聚焦
  ];

  /// 某一面的当前不透明度；背面（z < 0）不参与渲染，视作 0。
  double opacityOf(WidgetTester tester, int i) {
    final f = find.byKey(faceKeys[i]);
    if (f.evaluate().isEmpty) return 0;
    return tester.widget<Opacity>(f).opacity;
  }

  /// 当前正对观众（不透明度最大）的面。
  int frontFace(WidgetTester tester) {
    var best = 0;
    var bestOpacity = -1.0;
    for (var i = 0; i < faceKeys.length; i++) {
      final o = opacityOf(tester, i);
      if (o > bestOpacity) {
        bestOpacity = o;
        best = i;
      }
    }
    return best;
  }

  /// 小步推进假时钟：一次大跳只会让 AnimationController 收到一帧，
  /// 不足以走完翻转。
  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    const step = Duration(milliseconds: 50);
    for (var elapsed = Duration.zero;
        elapsed < total;
        elapsed += step) {
      await tester.pump(step);
    }
  }

  testWidgets('四个面按 0→1→2→3 循环，停留期间不跳面', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 卡片的 family key 是归一化后的「当天 0 点」。
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final prevDay = DateTime(now.year, now.month, now.day - 1);

    final container = ProviderContainer(
      overrides: [
        // 卡片现在会读设置页的停留时长（走 daoProvider → 真库）；
        // 用例里直接钉成默认值，避免测试去碰数据库。
        spotlightHoldMsProvider.overrideWith(
          (ref) => Stream<int>.value(defaultSpotlightHoldMs),
        ),
        dayHoldingsBreakdownProvider(today)
            .overrideWith((ref) => const <DayHoldingValue>[]),
        dayHoldingsBreakdownProvider(prevDay)
            .overrideWith((ref) => const <DayHoldingValue>[]),
        productEarningsProvider(today.year)
            .overrideWith((ref) => const <ProductEarnings>[]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 360, child: RotatingSpotlightCard()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(frontFace(tester), 0, reason: '初始应停在「今日最佳」');

    // 每轮 = 停留 2.3s + 翻转 0.9s（多给 100ms 覆盖 ticker 首帧基线）。
    Future<void> nextFace() async {
      await pumpFor(tester, const Duration(milliseconds: 2300));
      await pumpFor(tester, const Duration(milliseconds: 1000));
      // 停留期强制重建一次：相位必须仍停在同一面（旧实现会跳到下一面）。
      container.invalidate(dayHoldingsBreakdownProvider(today));
      await tester.pump();
    }

    for (var expected = 1; expected <= 3; expected++) {
      await nextFace();
      expect(frontFace(tester), expected, reason: '翻转后应停在面 $expected');
      expect(opacityOf(tester, expected), closeTo(1.0, 0.001));
    }

    // 第四个周期回到第一面：确认是四面循环，而不是越走越远。
    await nextFace();
    expect(frontFace(tester), 0, reason: '一轮之后应回到「今日最佳」');

    // 用例内主动卸载 + 定时 pump，冲掉 Riverpod 在 unmount 时排下的零时长
    // dispose timer（binding 收尾的无时长 pump 永远不会推进假时钟）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('隐藏金额（小眼睛）时数字面遮罩，不泄露真实数值', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final prevDay = DateTime(now.year, now.month, now.day - 1);

    // 今日 +100（1100 − 1000），昨日 1000 ⇒ 今日最佳/最差都指向同一持仓。
    final container = ProviderContainer(
      overrides: [
        // 卡片现在会读设置页的停留时长（走 daoProvider → 真库）；
        // 用例里直接钉成默认值，避免测试去碰数据库。
        spotlightHoldMsProvider.overrideWith(
          (ref) => Stream<int>.value(defaultSpotlightHoldMs),
        ),
        dayHoldingsBreakdownProvider(today).overrideWith(
          (ref) => const [
            DayHoldingValue(
              holdingId: 1,
              name: '测试股票',
              type: AssetType.stock,
              value: 1100,
              cost: 1000,
              liability: false,
            ),
          ],
        ),
        dayHoldingsBreakdownProvider(prevDay).overrideWith(
          (ref) => const [
            DayHoldingValue(
              holdingId: 1,
              name: '测试股票',
              type: AssetType.stock,
              value: 1000,
              cost: 1000,
              liability: false,
            ),
          ],
        ),
        productEarningsProvider(today.year)
            .overrideWith((ref) => const <ProductEarnings>[]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 360, child: RotatingSpotlightCard()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // hideAmountsProvider 默认 true：卡片原先没订阅它，滚动到数字面时会把
    // 真实金额直接露出来 —— 这里锁死「默认必须遮罩」。
    expect(
      find.text(Formats.masked()),
      findsWidgets,
      reason: '隐藏态应显示遮罩',
    );
    expect(find.text('+100.00'), findsNothing, reason: '隐藏态不得出现具体金额');

    // 关掉小眼睛后恢复真实金额。
    container.read(hideAmountsProvider.notifier).state = false;
    await tester.pump();
    expect(find.text('+100.00'), findsWidgets, reason: '显示态应给出真实金额');
    expect(find.text(Formats.masked()), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('停留时长可配置：设为 1.5 秒后按新节奏翻转', (tester) async {
    tester.view.physicalSize = const Size(400, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final prevDay = DateTime(now.year, now.month, now.day - 1);

    final container = ProviderContainer(
      overrides: [
        // 设置页把「滚动卡停留时间」调成 1.5 秒。
        spotlightHoldMsProvider.overrideWith((ref) => Stream<int>.value(1500)),
        dayHoldingsBreakdownProvider(today)
            .overrideWith((ref) => const <DayHoldingValue>[]),
        dayHoldingsBreakdownProvider(prevDay)
            .overrideWith((ref) => const <DayHoldingValue>[]),
        productEarningsProvider(today.year)
            .overrideWith((ref) => const <ProductEarnings>[]),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 360, child: RotatingSpotlightCard()),
            ),
          ),
        ),
      ),
    );
    // 两次 pump：让 provider 的首个值到达、listen 回调把新时长装进定时器。
    await tester.pump();
    await tester.pump();
    expect(frontFace(tester), 0, reason: '初始应停在「今日最佳」');

    // 1.5s 停留 + 0.9s 翻转 ⇒ 2.6s 时早已翻面；若还在用旧的 2.3s 默认值，
    // 此刻仍停在第一面 —— 这条断言正是在区分「设置生效」与「没生效」。
    await pumpFor(tester, const Duration(milliseconds: 1600));
    await pumpFor(tester, const Duration(milliseconds: 1000));
    expect(frontFace(tester), 1, reason: '1.5 秒档位应已翻到第二面');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
