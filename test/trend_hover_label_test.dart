import 'package:flutter_test/flutter_test.dart';

import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_widgets.dart';

/// SnapshotRow helper mirroring a real day (date yyyy-MM-dd).
SnapshotRow _s(String date, double value, {double liab = 0}) => SnapshotRow(
      date: date,
      currency: 'CNY',
      totalValue: value,
      totalCost: value,
      liabilities: liab,
      createdAt: DateTime(2026, 9, 21),
    );

void main() {
  final list = [
    _s('2026-09-15', 100000),
    _s('2026-09-16', 101000, liab: 500),
    _s('2026-09-17', 99500),
  ];
  final rates = [0.0, 1.0, -0.5]; // 累计收益率（百分数）

  test('净值模式：日期 / 金额 / 较前日（资产口径）', () {
    final lines = trendHoverLabelLines(
      list: list,
      isRate: false,
      rates: rates,
      index: 1,
      hideAmounts: false,
    );
    expect(lines, hasLength(3));
    expect(lines[0], contains('09-16'));
    expect(lines[1], contains('101,000'));
    // 较前日：101000+500 − 100000 = 1500（正号）。
    expect(lines[2], contains('较前日 +'));
    expect(lines[2], contains('1,500'));
  });

  test('净值模式：index 0 无较前日', () {
    final lines = trendHoverLabelLines(
      list: list,
      isRate: false,
      rates: rates,
      index: 0,
      hideAmounts: false,
    );
    expect(lines, hasLength(2));
    expect(lines[1], contains('100,000'));
  });

  test('净值模式：隐私掩码生效', () {
    final lines = trendHoverLabelLines(
      list: list,
      isRate: false,
      rates: rates,
      index: 1,
      hideAmounts: true,
    );
    expect(lines[1], startsWith('¥'));
    expect(lines[1], isNot(contains('101,000')));
    expect(lines[2], contains('较前日'));
    expect(lines[2], isNot(contains('1,500')));
  });

  test('收益率模式：累计涨跌 + 较前日百分点', () {
    final lines = trendHoverLabelLines(
      list: list,
      isRate: true,
      rates: rates,
      index: 2,
      hideAmounts: false,
    );
    expect(lines, hasLength(3));
    expect(lines[1], startsWith('-'));
    expect(lines[1], contains('-0.5'));
    expect(lines[2], contains('较前日 '));
    expect(lines[2], startsWith('较前日 -'));
    // 较前日：-0.5 − 1.0 = -1.5 个百分点 → -1.5%。
    expect(lines[2], contains('1.5'));
  });

  test('越界 index 返回空', () {
    expect(
      trendHoverLabelLines(
        list: list,
        isRate: false,
        rates: rates,
        index: 99,
        hideAmounts: false,
      ),
      isEmpty,
    );
  });
}