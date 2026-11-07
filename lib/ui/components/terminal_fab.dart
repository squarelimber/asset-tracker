import 'package:flutter/material.dart';

import '../tokens.dart';

/// Labeled primary action for pages that place it above their content.
class TerminalFab extends StatelessWidget {
  const TerminalFab({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback? onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: const ButtonStyle(
        backgroundColor: WidgetStateColor.fromMap({
          WidgetState.disabled: T.surface2,
          WidgetState.any: T.accent,
        }),
        foregroundColor: WidgetStateColor.fromMap({
          WidgetState.disabled: T.text3,
          WidgetState.any: T.bg,
        }),
        elevation: WidgetStatePropertyAll(0),
      ),
    );
  }
}
