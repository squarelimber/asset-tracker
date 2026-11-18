import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'holding_kline_page.dart';

Future<void> openHoldingDetails(BuildContext context, int holdingId) =>
    openProductDetails(context, [holdingId]);

Future<void> openProductDetails(
  BuildContext context,
  List<int> holdingIds,
) async {
  final ids = holdingIds.toSet().toList();
  if (ids.isEmpty) return;
  final router = GoRouter.maybeOf(context);
  if (router == null) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HoldingKlinePage.group(holdingIds: ids),
      ),
    );
    return;
  }
  final path = ids.length == 1
      ? '/holdings/${ids.single}'
      : Uri(
          path: '/holdings/product',
          queryParameters: {'ids': ids.join(',')},
        ).toString();
  if (router.state.uri.toString() == path) {
    if (ModalRoute.of(context) is PopupRoute) {
      await Navigator.of(context).maybePop();
    }
    return;
  }
  await router.push<void>(path);
}
