import 'package:flutter/material.dart';

import '../../core/responsive.dart';
import '../tokens.dart';

/// Keyboard-focusable chart control, with a full touch target on phones.
class TerminalChoice extends StatelessWidget {
  const TerminalChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: TextButton(
      onPressed: onPressed,
      style:
          TextButton.styleFrom(
            minimumSize: Size(44, Responsive.isPhone(context) ? 44 : 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            foregroundColor: selected ? T.text1 : T.text2,
            backgroundColor: selected ? T.surface2 : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(T.rInput),
            ),
            textStyle: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ).copyWith(
            overlayColor: Theme.of(context).textButtonTheme.style?.overlayColor,
            side: WidgetStateBorderSide.fromMap({
              WidgetState.focused: const BorderSide(color: T.accent),
              WidgetState.any: selected
                  ? const BorderSide(color: T.border)
                  : BorderSide.none,
            }),
          ),
      child: Text(label),
    ),
  );
}
