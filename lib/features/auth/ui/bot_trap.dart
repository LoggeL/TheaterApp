import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';

/// The invisible bot trap of a form: a honeypot field that people never see
/// and a timer from showing the form to sending it. The form sends its
/// [report]; only the server judges it, so people are never locked out.
class BotTrap {
  BotTrap(this._now) : _shownAt = _now();
  final DateTime Function() _now;
  final DateTime _shownAt;

  /// The honeypot's text; only automated form fillers type into it.
  final field = TextEditingController();

  BotTrapReport report() => BotTrapReport(
    filled: field.text.isNotEmpty,
    elapsed: _now().difference(_shownAt),
  );

  void dispose() => field.dispose();
}

/// The honeypot of a [BotTrap]. It is not painted, takes no taps or focus,
/// is hidden from screen readers and takes no part in autofill: without
/// autofill hints it leaves the form's autofill group, and on the web an
/// unfocusable field never gets an input element for browsers or password
/// managers to fill.
class BotTrapField extends StatelessWidget {
  const BotTrapField(this.trap, {super.key});
  final BotTrap trap;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ExcludeFocus(
      child: Offstage(
        child: TextField(
          key: const ValueKey('bot-trap'),
          controller: trap.field,
          canRequestFocus: false,
          autofillHints: null,
          autocorrect: false,
          enableSuggestions: false,
          enableInteractiveSelection: false,
          decoration: const InputDecoration(labelText: 'Webseite'),
        ),
      ),
    ),
  );
}
