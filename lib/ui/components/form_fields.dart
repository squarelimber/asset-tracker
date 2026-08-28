import 'package:flutter/material.dart';

import '../tokens.dart';

InputDecoration terminalDecoration(String label, {String? hint, Widget? suffix}) =>
    InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: T.text2),
      floatingLabelStyle: const TextStyle(color: T.text2),
      hint: hint == null ? null : Text(hint, style: const TextStyle(color: T.text3)),
      suffix: suffix,
    );

class TerminalTextField extends StatelessWidget {
  const TerminalTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.suffix,
    this.onChanged,
    this.obscureText = false,
    this.maxLines = 1,
    this.enabled = true,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final bool obscureText;
  final int maxLines;
  final bool enabled;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      maxLines: maxLines,
      keyboardType: keyboardType,
      onChanged: onChanged,
      enabled: enabled,
      autofocus: autofocus,
      style: T.mono(),
      decoration: terminalDecoration(label, hint: hint, suffix: suffix),
    );
  }
}
