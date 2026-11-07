import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Invokes [onKeyDown] for physical key-down events (auto-repeat is a
/// separate [KeyRepeatEvent] type and is ignored) on the visible page.
///
/// Works on desktop and web; harmless on touch-only devices.
class KeyShortcuts extends StatefulWidget {
  const KeyShortcuts({super.key, required this.onKeyDown, required this.child});

  final ValueChanged<LogicalKeyboardKey> onKeyDown;
  final Widget child;

  @override
  State<KeyShortcuts> createState() => _KeyShortcutsState();
}

class _KeyShortcutsState extends State<KeyShortcuts> {
  bool _handle(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed ||
        _hasInputFocus()) {
      return false;
    }
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    final navigator = Navigator.maybeOf(context);
    // A dialog on the root navigator can cover a still-current shell page.
    if (navigator != null &&
        ModalRoute.of(navigator.context)?.isCurrent == false) {
      return false;
    }
    widget.onKeyDown(e.logicalKey);
    return false;
  }

  bool _hasInputFocus() {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    return ModalRoute.of(ctx) is PopupRoute ||
        ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handle);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handle);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
