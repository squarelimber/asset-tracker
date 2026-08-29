import 'package:flutter/material.dart';

import '../tokens.dart';

/// Terminal-styled floating action button: flat (no elevation), 8px
/// radius, accent fill with dark text — matches the flat card aesthetic
/// instead of the default M3 raised FAB.
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
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: T.accent,
        foregroundColor: Colors.black,
        disabledBackgroundColor: T.surface2,
        disabledForegroundColor: T.text3,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: T.s4, vertical: T.s3),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.rCard),
        ),
      ),
    );
  }
}
