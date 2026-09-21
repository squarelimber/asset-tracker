import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/core/enums.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/domain/holding_type_conversion.dart';
import 'package:asset_tracker/domain/portfolio_calculator.dart';
import 'package:asset_tracker/domain/smooth_history.dart';
import 'package:asset_tracker/services/history_backfill_service.dart';

/// Regression: editing a holding's *asset type* must convert the stored
/// numbers from the old type's semantics to the new one's, or the same row
/// silently switches meaning and the portfolio/history explode.
///
/// Amount-based types (现金/银行存款/活期理财) store:
///   quantity = current balance, costPrice = cumulative invested, latestPrice = 1
/// Share-based types (银行理财/基金/股票/…) store:
///   quantity = shares, costPrice = per-unit cost, latestPrice = NAV
///
/// 朝朝宝 (银行存款, 余额 50000 / 累计投入 50000) 改类型成 银行理财 used to keep
/// the same three digits: 50000 became *shares*, 50000 became the *unit
/// cost* (成本 = 50000 × 50000 = 25 亿), 1 became the NAV — a ~25 亿 fake
/// loss, and every history rebuild projected that unit cost onto the whole
/// curve. `convertHoldingTypeSemantics` is the fix: it converts the digits
/// the moment the switch crosses the amount-based boundary, so market value
/// and cost (and therefore the profit line) stay continuous.
HoldingRow _holding({
  required int id,
  required String assetType,
  String marketSource = 'manual',
  double quantity = 1,
  double cost = 90,
  double price = 100,
  String currency = 'CNY',
}) {
  return HoldingRow(
    id: id,
    accountId: 1,
    name: 'h$id',
    assetType: assetType,
    marketSource: marketSource,
    categoryOverride: null,
    symbol: null,
    quantity: quantity,
    costPrice: cost,
    latestPrice: price,
    currency: currency,
    archived: false,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

void main() {
  group('convertHoldingTypeSemantics — 金额型↔份额型换算', () {
    test('银行存款(余额50000/累计投入50000) → 银行理财：份额50000 / 单位成本1 / 净值1', () {
      final conv = convertHoldingTypeSemantics(
        from: AssetType.bankDeposit,
        to: AssetType.bankWealth,
        quantity: 50000,
        costPrice: 50000,
        latestPrice: 1,
      );
      expect(conv, isNotNull);
      expect(conv!.quantity, closeTo(50000, 1e-9)); // 余额 → 份额（净值1时同数）
      expect(conv.costPrice, closeTo(1, 1e-9)); // 累计投入 ÷ 份额 → 单位成本
      expect(conv.latestPrice, closeTo(1, 1e-9)); // 占位，用户填真实净值
    });

    test('银行理财(份额50000/单位成本1/净值1) → 现金：余额50000 / 累计投入50000', () {
      final conv = convertHoldingTypeSemantics(
        from: AssetType.bankWealth,
        to: AssetType.cash,
        quantity: 50000,
        costPrice: 1,
        latestPrice: 1,
      );
      expect(conv, isNotNull);
      expect(conv!.quantity, closeTo(50000, 1e-9)); // 份额 × 净值 → 余额
      expect(conv.costPrice, closeTo(50000, 1e-9)); // 份额 × 单位成本 → 累计投入
      expect(conv.latestPrice, closeTo(1, 1e-9));
    });

    test('银行理财(有浮盈) → 现金：余额=市值、累计投入=成本，收益保留', () {
      final conv = convertHoldingTypeSemantics(
        from: AssetType.bankWealth,
        to: AssetType.cash,
        quantity: 1000,
        costPrice: 1.5,
        latestPrice: 1.1,
      );
      expect(conv, isNotNull);
      expect(conv!.quantity, closeTo(1100, 1e-9)); // 市值
      expect(conv.costPrice, closeTo(1500, 1e-9)); // 成本
      // 收益 1000×1.1 − 1000×1.5 = −400 与换算后 1100 − 1500 = −400 一致。
    });

    test('从未记录本金的存款 → 银行理财：单位成本按有效本金算为 1，而不是 0', () {
      final conv = convertHoldingTypeSemantics(
        from: AssetType.cash,
        to: AssetType.bankWealth,
        quantity: 8000,
        costPrice: 0,
        latestPrice: 1,
      );
      expect(conv, isNotNull);
      expect(conv!.costPrice, closeTo(1, 1e-9)); // 有效本金 8000 / 8000
    });

    test('余额为 0 时无法换算成份额（返回 null，交由用户手填）', () {
      final conv = convertHoldingTypeSemantics(
        from: AssetType.cash,
        to: AssetType.bankWealth,
        quantity: 0,
        costPrice: 0,
        latestPrice: 1,
      );
      expect(conv, isNull);
    });

    test('净值缺失时无法换算成余额（返回 null）', () {
      final conv = convertHoldingTypeSemantics(
        from: AssetType.bankWealth,
        to: AssetType.cash,
        quantity: 50000,
        costPrice: 1,
        latestPrice: 0,
      );
      expect(conv, isNull);
    });

    test('同侧切换（现金→银行存款、基金→股票）不改变语义，返回 null', () {
      expect(
        convertHoldingTypeSemantics(
          from: AssetType.cash,
          to: AssetType.bankDeposit,
          quantity: 50000,
          costPrice: 50000,
          latestPrice: 1,
        ),
        isNull,
      );
      expect(
        convertHoldingTypeSemantics(
          from: AssetType.mutualFund,
          to: AssetType.stock,
          quantity: 100,
          costPrice: 2.5,
          latestPrice: 3,
        ),
        isNull,
      );
    });
  });

  group('换算后收益连续', () {
    test('朝朝宝 银行存款 → 银行理财：组合收益保持 0，而不是 −25 亿', () {
      final before = _holding(
        id: 1,
        assetType: AssetType.bankDeposit.storageName,
        quantity: 50000,
        cost: 50000,
        price: 1,
      );
      final conv = convertHoldingTypeSemantics(
        from: AssetType.bankDeposit,
        to: AssetType.bankWealth,
        quantity: before.quantity,
        costPrice: before.costPrice,
        latestPrice: before.latestPrice,
      )!;
      final after = before.copyWith(
        assetType: AssetType.bankWealth.storageName,
        marketSource: 'manual',
        quantity: conv.quantity,
        costPrice: conv.costPrice,
        latestPrice: conv.latestPrice,
      );
      final summary = const PortfolioCalculator().compute([after]);
      expect(summary.totalAssets, closeTo(50000, 1e-6));
      expect(
        summary.netWorth - summary.totalCost,
        closeTo(0, 1e-6),
        reason: '旧行为：成本 = 50000 份额 × 50000 元/份 = 25 亿，收益 −25 亿',
      );
    });

    test('换算后银行理财的平滑历史从单位成本(≈1)起插值，历史市值 ≈ 5 万而非 25 亿', () {
      final conv = convertHoldingTypeSemantics(
        from: AssetType.bankDeposit,
        to: AssetType.bankWealth,
        quantity: 50000,
        costPrice: 50000,
        latestPrice: 1,
      )!;
      final h = _holding(
        id: 1,
        assetType: AssetType.bankWealth.storageName,
        marketSource: 'manual',
        quantity: conv.quantity,
        cost: conv.costPrice,
        price: 1.05,
      );
      final from = DateTime(2025, 6, 1);
      final to = DateTime(2026, 9, 20);
      final startPrice = const SmoothHistoryCalculator().sharePrice(h, from, from, to);
      expect(startPrice, closeTo(1.0, 0.05),
          reason: '旧行为：起点单价 = 累计投入 50000，历史市值被放大到 25 亿');
      expect(50000 * startPrice, closeTo(50000, 2500));
    });
  });

  group('跨金额性切换强制全量重建历史', () {
    test('light 回填看到 history_full_rebuild 标记时也覆盖锚点之前的旧口径快照', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final dao = AssetDao(db);

      final accountId = await dao.createAccount(AccountsCompanion.insert(
        name: '测试账户',
        type: 'general',
      ));
      await dao.createHolding(HoldingsCompanion.insert(
        accountId: accountId,
        name: '朝朝宝',
        assetType: AssetType.bankDeposit.storageName,
        marketSource: const Value('manual'),
        quantity: const Value(50000),
        costPrice: const Value(50000),
        latestPrice: const Value(1),
        purchaseDate: Value(DateTime(2025, 6, 1)),
      ));

      final service = HistoryBackfillService(dao);
      // 第一次回填（9-15，银行存款）：全部按金额型 50000 恒定写入。
      final first = await service.backfill(now: DateTime(2026, 9, 15));
      expect(first.ok, isTrue);
      for (final s in await dao.getSnapshots()) {
        expect(s.totalValue, closeTo(50000, 1e-6));
      }

      // 模拟 9-16 有一次正常 light run（锚点推进到 9-16）。
      await dao.setSetting('backfill_last_run', '2026-09-16');

      // 9-21 用户把类型改成银行理财：对话框已把字段换算为
      // 份额50000 / 单位成本1 / 净值1.05，并设置全量重建标记。
      final holdings = await dao.getHoldings();
      await dao.updateHolding(holdings.single.copyWith(
        assetType: AssetType.bankWealth.storageName,
        marketSource: 'manual',
        quantity: 50000,
        costPrice: 1,
        latestPrice: 1.05,
      ));
      await dao.setSetting('history_full_rebuild', '1');

      // 普通 light 回填（forceRebuild: false）：因标记存在，必须全量重算。
      final second = await service.backfill(now: DateTime(2026, 9, 21));
      expect(second.ok, isTrue);

      // 锚点（9-16）之前、类型切换前的快照也被重新推导——否则曲线在此断层。
      final d15 = (await dao.getSnapshot('2026-09-15', 'CNY'))!;
      // 9-15 距买入日（6-01）106 天 / 窗口 112 天，净值插值 ≈ 1.0467 → 市值 ≈ 52330；
      // 若是 light 路径（不覆盖锚点之前），这里会保留旧值 50000。
      expect(d15.totalValue, greaterThan(50000),
          reason: '旧行为：锚点之前的旧口径快照残留，曲线在类型切换处永久断层');
      expect(d15.totalValue, closeTo(50000 * 1.05, 5000));

      // 全量重算后标记应被清除；下次 light run 恢复正常窗口。
      expect(await dao.getSetting('history_full_rebuild'), '0');
    });
  });
}