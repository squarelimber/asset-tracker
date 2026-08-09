import 'package:flutter/material.dart';

/// Risk levels for allocation analysis (4 tiers).
/// A holding's effective risk = its manual riskLevel override, or the
/// automatic mapping from its asset type.
enum RiskLevel {
  low('低风险', 'low', Color(0xFF26A69A)),
  mediumLow('中低风险', 'medium_low', Color(0xFF4DB6AC)),
  medium('中风险', 'medium', Color(0xFFFF9800)),
  high('高风险', 'high', Color(0xFFE53935));

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
        AssetType.bankWealth =>
          RiskLevel.low,
        AssetType.gold => RiskLevel.mediumLow,
        AssetType.mutualFund => RiskLevel.medium,
        AssetType.stock || AssetType.etf || AssetType.crypto => RiskLevel.high,
        AssetType.property || AssetType.liability => RiskLevel.mediumLow,
      };
}

/// Asset categories supported by the app.
enum AssetType {
  cash('现金', 'savings', Icons.payments_outlined, Color(0xFF42A5F5)),
  bankDeposit('银行存款', 'bank_deposit', Icons.account_balance_outlined, Color(0xFF26A69A)),
  liquidWealth('活期理财', 'liquid_wealth', Icons.savings_outlined, Color(0xFF29B6F6)),
  bankWealth('银行理财', 'bank_wealth', Icons.handshake_outlined, Color(0xFFAB47BC)),
  stock('股票', 'stock', Icons.show_chart, Color(0xFFEF5350)),
  etf('场内基金', 'etf', Icons.candlestick_chart_outlined, Color(0xFFFFA726)),
  mutualFund('场外基金', 'mutual_fund', Icons.pie_chart_outline, Color(0xFF5C6BC0)),
  gold('积存金', 'gold', Icons.workspace_premium_outlined, Color(0xFFFFC107)),
  crypto('加密货币', 'crypto', Icons.currency_bitcoin, Color(0xFFEC407A)),
  property('房产', 'property', Icons.home_outlined, Color(0xFF8D6E63)),
  liability('负债', 'liability', Icons.credit_card, Color(0xFF757575));

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
  expense('支出', 'expense', Icons.north_east);

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
