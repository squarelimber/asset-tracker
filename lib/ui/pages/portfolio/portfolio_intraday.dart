import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/formats.dart';
import '../../../data/asset_dao.dart';
import '../../../domain/holding_kline.dart';
import '../../../domain/portfolio_intraday.dart';
import '../../../services/market/kline_source.dart';
import '../../../services/market/market_data_source.dart';
import '../../../services/market/market_service.dart';

const _sampleKey = 'portfolio_intraday_samples';

final portfolioMinuteSourceProvider = Provider.autoDispose<KlineSource>((ref) {
  final source = KlineSource();
  ref.onDispose(source.close);
  return source;
});

final portfolioIntradayHistoryProvider = FutureProvider.autoDispose
    .family<PortfolioIntradayHistory, String>((ref, day) async {
      final dao = ref.watch(daoProvider);
      final market = ref.watch(marketServiceProvider);
      final source = ref.watch(portfolioMinuteSourceProvider);
      final start = DateTime.parse('${day}T00:00:00+08:00');
      final (holdings, transactions) = await dao.transaction(
        () async =>
            (await dao.getHoldings(), await dao.getTransactionsSince(start)),
      );
      final priceHoldings = intradayPriceHoldings(holdings, transactions);
      final symbols = {
        for (final holding in priceHoldings) klineSymbolForHolding(holding),
      }.whereType<String>().where(supportsMarketIntraday).toList();
      final currencies = {
        for (final holding in priceHoldings)
          if (holding.currency.toUpperCase() != 'CNY' &&
              symbols.contains(klineSymbolForHolding(holding)))
            holding.currency,
      };
      final quotes = <String, MarketIntraday>{};
      for (final batch in MarketFetchHelper.chunk(symbols, 8)) {
        final results = await Future.wait(
          batch.map((symbol) async {
            return (symbol, await source.fetchIntraday(symbol));
          }),
        );
        for (final (symbol, quote) in results) {
          if (quote != null && quote.date == day) quotes[symbol] = quote;
        }
      }
      final rates = quotes.isEmpty
          ? <String, double>{}
          : await market.loadCnyRates(currencies.toList());
      return rebuildPortfolioIntraday(
        day: day,
        now: DateTime.now(),
        priceHoldings: priceHoldings,
        transactions: transactions,
        quotes: quotes,
        rates: rates,
      );
    });

List<PortfolioSample> _readSamples(String? raw, String day) {
  if (raw == null) return const [];
  try {
    final data = jsonDecode(raw);
    if (data is! Map || data['day'] != day || data['points'] is! List) {
      return const [];
    }
    return [
      for (final p in data['points'] as List)
        if (p is List &&
            p.length == 2 &&
            p[0] is int &&
            p[1] is num &&
            ((p[0] as int) <= 690 || (p[0] as int) >= 780))
          (minute: p[0] as int, profit: (p[1] as num).toDouble()),
    ];
  } on FormatException {
    return const [];
  }
}

final portfolioIntradayProvider = StreamProvider.autoDispose
    .family<List<PortfolioSample>, String>((ref, day) {
      return ref
          .watch(daoProvider)
          .watchSetting(_sampleKey)
          .map((raw) => _readSamples(raw, day));
    });

Future<void> recordPortfolioSample(
  AssetDao dao,
  MarketService market,
  DateTime now,
) async {
  final marketTime = chinaMarketTime(now);
  final day = todayKey(marketTime);
  final previous = todayKey(marketTime.subtract(const Duration(days: 1)));
  final (baseline, holdings, transactions) = await dao.transaction(
    () async => (
      await dao.getSnapshot(previous, 'CNY'),
      await dao.getHoldings(),
      [
        for (final t in await dao.getTransactions())
          if (todayKey(t.occurredAt.toLocal()).compareTo(previous) > 0) t,
      ],
    ),
  );
  if (baseline == null) return;
  final rates = await market.loadCnyRates([
    ...{
      for (final h in holdings)
        if (h.currency != 'CNY') h.currency,
      for (final t in transactions)
        if (t.currency != 'CNY') t.currency,
    },
  ]);
  final profit = intradayPortfolioProfit(
    baseline: baseline,
    holdings: holdings,
    transactions: transactions,
    rates: rates,
    now: now,
  );
  if (profit == null) return;
  final minute = (marketTime.hour * 60 + marketTime.minute).clamp(570, 900);
  await dao.transaction(() async {
    final points = {
      for (final point in _readSamples(await dao.getSetting(_sampleKey), day))
        point.minute: point.profit,
      minute: profit,
    };
    final minutes = points.keys.toList()..sort();
    await dao.setSetting(
      _sampleKey,
      jsonEncode({
        'day': day,
        'points': [
          for (final m in minutes) [m, points[m]],
        ],
      }),
    );
  });
}
