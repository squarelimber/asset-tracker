import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Invokes [onKeyDown] for physical key-down events (auto-repeat is a
/// separate [KeyRepeatEvent] type and is ignored), suppressed while a text
/// field has focus so typing is never intercepted.
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
    if (_isEditing()) return false;
    widget.onKeyDown(e.logicalKey);
    return false;
  }

  bool _isEditing() {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
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
