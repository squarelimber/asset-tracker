import 'package:flutter/material.dart';

import '../tokens.dart';

/// Unified error state: icon + friendly message + optional retry action.
///
/// Pages should pass a human-readable message (never the raw exception)
/// and wire [onRetry] to re-running the failed load (e.g. `ref.invalidate`).
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.icon,
  });

  final String message;
  final VoidCallback? onRetry;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(T.s5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon ?? Icons.error_outline, size: 40, color: T.text3),
            const SizedBox(height: T.s3),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: T.text2, fontSize: 14),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: T.s4),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
