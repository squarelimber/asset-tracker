import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The app bar follows the same navigator order as the system back action.
class SecondaryPageBackButton extends StatelessWidget {
  const SecondaryPageBackButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '返回',
    icon: const BackButtonIcon(),
    onPressed: () {
      final router = GoRouter.maybeOf(context);
      if (router == null) {
        Navigator.of(context).maybePop();
      } else {
        router.routerDelegate.popRoute();
      }
    },
  );
}
