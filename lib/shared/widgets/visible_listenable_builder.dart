import 'package:flutter/widgets.dart';

/// A [ListenableBuilder] that skips rebuilds while its subtree is hidden.
///
/// Hidden means [TickerMode] is off: an inactive tab of the app shell or a
/// page covered by another route. Changes in the meantime are remembered and
/// applied with a single rebuild once the subtree is shown again.
class VisibleListenableBuilder extends StatefulWidget {
  const VisibleListenableBuilder({
    super.key,
    required this.listenable,
    required this.builder,
    this.child,
  });
  final Listenable listenable;
  final TransitionBuilder builder;
  final Widget? child;
  @override
  State<VisibleListenableBuilder> createState() =>
      _VisibleListenableBuilderState();
}

class _VisibleListenableBuilderState extends State<VisibleListenableBuilder> {
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(VisibleListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Becoming visible again always rebuilds, which applies missed changes.
    _visible = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_visible) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}
