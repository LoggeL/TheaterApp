import 'package:flutter/material.dart';

/// Calls [onUnlocked] after [taps] quick taps on [child]; a pause longer than
/// [window] between two taps starts the count again.
///
/// Deliberately invisible: no ink, no cursor change and nothing for screen
/// readers, so [child] looks and reads exactly as before.
class SecretTap extends StatefulWidget {
  const SecretTap({
    super.key,
    required this.child,
    required this.onUnlocked,
    this.taps = 7,
    this.window = const Duration(milliseconds: 900),
  });
  final Widget child;
  final VoidCallback onUnlocked;
  final int taps;
  final Duration window;

  @override
  State<SecretTap> createState() => _SecretTapState();
}

class _SecretTapState extends State<SecretTap> {
  int _count = 0;
  DateTime? _last;

  void _tap() {
    final now = DateTime.now();
    final last = _last;
    _count = last != null && now.difference(last) <= widget.window
        ? _count + 1
        : 1;
    _last = now;
    if (_count >= widget.taps) {
      _count = 0;
      _last = null;
      widget.onUnlocked();
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: _tap,
    child: widget.child,
  );
}
