import 'dart:async';

import 'package:asset_tracker/app/providers.dart';
import 'package:asset_tracker/data/asset_dao.dart';
import 'package:asset_tracker/data/database.dart';
import 'package:asset_tracker/services/market/market_service.dart';
import 'package:asset_tracker/ui/pages/portfolio/portfolio_page.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ControlledMarket extends MarketService {
  _ControlledMarket(super.dao);
  final requests = <Completer<MarketRefreshResult>>[];

  @override
  Future<MarketRefreshResult> refreshAll() {
    final request = Completer<MarketRefreshResult>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  testWidgets('manual refresh reports errors and handles disposal', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final market = _ControlledMarket(AssetDao(db));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        marketServiceProvider.overrideWithValue(market),
        historySyncProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PortfolioPage()),
      ),
    );
    await tester.pump();
    market.requests.single.completeError(Exception('offline'));
    await tester.pump();
    await tester.tap(find.byTooltip('刷新行情'));
    await tester.pump();
    market.requests.last.completeError(Exception('offline'));
    await tester.pump();
    expect(find.text('行情刷新失败，请稍后重试'), findsOneWidget);

    await tester.tap(find.byTooltip('刷新行情'));
    await tester.pump();
    final pending = market.requests.last;
    await tester.pumpWidget(const SizedBox.shrink());
    pending.completeError(Exception('offline'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
