import 'package:flutter/material.dart';

import '../tokens.dart';

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(T.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 28, color: T.text3),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: T.text2, fontSize: 14, height: 1.8),
            ),
            if (action != null) ...[const SizedBox(height: T.s5), action!],
          ],
        ),
      ),
    );
  }
}
