import 'package:flutter/material.dart';

/// Risk levels for allocation analysis (4 tiers).
/// A holding's effective risk = its manual riskLevel override, or the
/// automatic mapping from its asset type.
enum RiskLevel {
  low('低风险', 'low', Color(0xFF88A79D)),
  mediumLow('中低风险', 'medium_low', Color(0xFF9DB5AA)),
  medium('中风险', 'medium', Color(0xFFC9AC6E)),
  high('高风险', 'high', Color(0xFFC77D7D));

  const RiskLevel(this.label, this.storageName, this.color);

  final String label;
  final String storageName;
  final Color color;

  static RiskLevel? fromStorage(String? name) {
    if (name == null) return null;
    for (final r in RiskLevel.values) {
      if (r.storageName == name) return r;
    }
    return null;
  }

  /// Automatic risk mapping by asset type.
  static RiskLevel autoOf(AssetType type) => switch (type) {
    AssetType.cash ||
    AssetType.bankDeposit ||
    AssetType.liquidWealth ||
    AssetType.bankWealth => RiskLevel.low,
    AssetType.gold => RiskLevel.mediumLow,
    AssetType.bond => RiskLevel.mediumLow,
    AssetType.futures => RiskLevel.high,
    AssetType.mutualFund => RiskLevel.medium,
    AssetType.stock || AssetType.etf || AssetType.crypto => RiskLevel.high,
    AssetType.property || AssetType.liability => RiskLevel.mediumLow,
  };
}

/// Asset categories supported by the app.
enum AssetType {
  cash('现金', 'savings', Icons.payments_outlined, Color(0xFF819EBA)),
  bankDeposit(
    '银行存款',
    'bank_deposit',
    Icons.account_balance_outlined,
    Color(0xFF88A79D),
  ),
  liquidWealth(
    '活期理财',
    'liquid_wealth',
    Icons.savings_outlined,
    Color(0xFF89A3AC),
  ),
  bankWealth(
    '银行理财',
    'bank_wealth',
    Icons.handshake_outlined,
    Color(0xFFA79CBA),
  ),
  stock('股票', 'stock', Icons.show_chart, Color(0xFFC77D7D)),
  etf('场内基金', 'etf', Icons.candlestick_chart_outlined, Color(0xFFBAA17B)),
  mutualFund('场外基金', 'mutual_fund', Icons.pie_chart_outline, Color(0xFF8699B2)),
  gold('积存金', 'gold', Icons.workspace_premium_outlined, Color(0xFFC9AC6E)),
  bond('债券', 'bond', Icons.account_balance, Color(0xFF88A79D)),
  crypto('加密货币', 'crypto', Icons.currency_bitcoin, Color(0xFFAF90A1)),
  futures('期货', 'futures', Icons.trending_up, Color(0xFFB78E75)),
  property('房产', 'property', Icons.home_outlined, Color(0xFFA09A91)),
  liability('负债', 'liability', Icons.credit_card, Color(0xFF8B929B));

  const AssetType(this.label, this.storageName, this.icon, this.color);

  /// Display label (Chinese).
  final String label;

  /// Stable identifier persisted in the database.
  final String storageName;

  final IconData icon;
  final Color color;

  static AssetType fromStorage(String name) {
    return AssetType.values.firstWhere(
      (t) => t.storageName == name,
      orElse: () => AssetType.cash,
    );
  }

  /// Whether this asset type is priced by market data.
  bool get isMarketLinked => switch (this) {
    stock || etf || mutualFund || gold || crypto => true,
    _ => false,
  };

  /// Amount-based assets are tracked as a plain balance:
  /// quantity = current amount, costPrice = cumulative invested (optional).
  /// No price, no shares, no market code.
  bool get isAmountBased => switch (this) {
    cash || bankDeposit || liquidWealth => true,
    _ => false,
  };

  /// Default market code for asset types with a standard quote symbol.
  /// Used when the user leaves the code empty (e.g. gold -> AU99.99).
  String? get defaultSymbol => switch (this) {
    gold => 'AU99.99',
    _ => null,
  };

  /// High-level allocation category (债券/权益/黄金/商品/现金/房产/银行理财),
  /// grouping the finer asset types for the allocation view and the editable
  /// target-allocation plan. Liabilities never show up in the allocation
  /// view (they are deducted from net worth); the mapping below only exists
  /// to keep the switch exhaustive.
  AssetCategory get category => switch (this) {
    bond => AssetCategory.bond,
    stock || etf || mutualFund => AssetCategory.equity,
    gold => AssetCategory.gold,
    crypto || futures => AssetCategory.commodity,
    cash || bankDeposit || liquidWealth => AssetCategory.cash,
    property => AssetCategory.property,
    bankWealth => AssetCategory.bankWealth,
    liability => AssetCategory.cash,
  };
}

/// Top-level asset categories used by the allocation view and the editable
/// target-allocation plan (债券/权益/黄金/商品/现金/房产/银行理财).
enum AssetCategory {
  bond('债券', 'bond', Icons.account_balance, Color(0xFF88A79D)),
  equity('权益', 'equity', Icons.show_chart, Color(0xFFC77D7D)),
  gold('黄金', 'gold', Icons.workspace_premium_outlined, Color(0xFFC9AC6E)),
  commodity('商品', 'commodity', Icons.currency_bitcoin, Color(0xFFAF90A1)),
  cash('现金', 'cash', Icons.payments_outlined, Color(0xFF819EBA)),
  property('房产', 'property', Icons.home_outlined, Color(0xFFA09A91)),
  bankWealth(
    '银行理财',
    'bank_wealth',
    Icons.handshake_outlined,
    Color(0xFFA79CBA),
  );

  const AssetCategory(this.label, this.storageName, this.icon, this.color);

  final String label;
  final String storageName;
  final IconData icon;
  final Color color;

  static AssetCategory fromStorage(String name) =>
      AssetCategory.values.firstWhere(
        (t) => t.storageName == name,
        orElse: () => AssetCategory.bond,
      );

  /// Nullable lookup: null or an unrecognised name yields null so the caller
  /// can fall back (this is how a stored override is resolved — the value
  /// may also come from a newer app version). [fromStorage] keeps its
  /// non-null contract for call sites that need a value.
  static AssetCategory? fromStorageOrNull(String? name) {
    if (name == null) return null;
    for (final c in AssetCategory.values) {
      if (c.storageName == name) return c;
    }
    return null;
  }
}

/// Where the latest price comes from.
enum MarketSource {
  manual('手动净值', 'manual'),
  sina('新浪行情', 'sina'),
  eastmoney('天天基金', 'eastmoney'),
  sge('上金所金价', 'sge'),
  coingecko('CoinGecko', 'coingecko'),
  forex('汇率', 'forex');

  const MarketSource(this.label, this.storageName);

  final String label;
  final String storageName;

  static MarketSource fromStorage(String name) {
    return MarketSource.values.firstWhere(
      (s) => s.storageName == name,
      orElse: () => MarketSource.manual,
    );
  }
}

enum TransactionType {
  buy('买入', 'buy', Icons.add_circle_outline),
  sell('卖出', 'sell', Icons.remove_circle_outline),
  dividend('分红', 'dividend', Icons.redeem_outlined),
  transferIn('转入', 'transfer_in', Icons.south_west),
  transferOut('转出', 'transfer_out', Icons.north_east),
  income('收入', 'income', Icons.south_west),
  expense('支出', 'expense', Icons.north_east),
  consume('消费', 'consume', Icons.shopping_cart_outlined),
  split('份额折算', 'split', Icons.call_split_outlined);

  const TransactionType(this.label, this.storageName, this.icon);

  final String label;
  final String storageName;
  final IconData icon;

  static TransactionType fromStorage(String name) {
    return TransactionType.values.firstWhere(
      (t) => t.storageName == name,
      orElse: () => TransactionType.transferIn,
    );
  }
}

enum AlertRuleType {
  concentration('集中度风险', 'concentration'),
  assetRatio('配置比例偏离', 'asset_ratio'),
  drawdown('单日跌幅预警', 'drawdown'),
  cashflow('现金流提醒', 'cashflow');

  const AlertRuleType(this.label, this.storageName);

  final String label;
  final String storageName;

  static AlertRuleType fromStorage(String name) {
    return AlertRuleType.values.firstWhere(
      (t) => t.storageName == name,
      orElse: () => AlertRuleType.concentration,
    );
  }
}
