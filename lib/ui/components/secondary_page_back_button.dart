import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Secondary pages can be opened directly as well as pushed from a main page.
class SecondaryPageBackButton extends StatelessWidget {
  const SecondaryPageBackButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '返回',
    icon: const Icon(Icons.arrow_back),
    onPressed: () {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/portfolio');
      }
    },
  );
}
