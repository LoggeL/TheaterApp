import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../../app/brand.dart';
import '../../../core/app_controller.dart';
import '../../../data/api_client.dart';
import '../../../shared/widgets/brand_logo.dart';
import '../../../shared/widgets/privacy_links.dart';

/// A short knowledge question before the first sign-in or registration on a
/// device. The server checks the answer; a correct one leads to the sign-in.
class BotCheckScreen extends StatefulWidget {
  const BotCheckScreen({super.key, required this.controller});
  final AppController controller;

  /// Wrong answers before the screen asks for a short break.
  static const freeAttempts = 3;

  @override
  State<BotCheckScreen> createState() => _BotCheckScreenState();
}

class _BotCheckScreenState extends State<BotCheckScreen> {
  final _answer = TextEditingController();
  final _focus = FocusNode();
  BotCheckQuestion? _question;
  bool _loading = true, _busy = false;
  String? _loadError, _error;
  int _wrong = 0, _wait = 0;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _answer.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      // Null: the server does not ask; the sign-in replaces this screen.
      final question = await widget.controller.loadBotCheckQuestion();
      if (mounted) setState(() => _question = question);
    } catch (e) {
      if (mounted) {
        setState(
          () => _loadError = e is ApiException
              ? e.message
              : 'Die Frage konnte gerade nicht geladen werden.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pause(int seconds) {
    _ticker?.cancel();
    setState(() => _wait = seconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _wait--);
      if (_wait <= 0) {
        timer.cancel();
        _focus.requestFocus();
      }
    });
  }

  Future<void> _submit() async {
    if (_busy || _wait > 0) return;
    if (_answer.text.trim().isEmpty) {
      setState(() => _error = 'Bitte gib eine Antwort ein.');
      _focus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.controller.answerBotCheck(_answer.text);
      // The session gate now shows the sign-in.
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'bot_check_wrong') {
        _wrong++;
        _error = e.message;
        if (_wrong >= BotCheckScreen.freeAttempts) {
          _pause(min(30, 5 * (_wrong - BotCheckScreen.freeAttempts + 1)));
        }
      } else if (e.code == 'rate_limited') {
        _error = e.message;
        _pause(60);
      } else {
        _error = e.message;
      }
      _answer.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _answer.text.length,
      );
      // Toggling the field (e.g. read-only) would lose the web keyboard.
      if (_wait == 0 && !_focus.hasFocus) _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _notice(String text, {bool error = true}) {
    final scheme = Theme.of(context).colorScheme;
    final fg = error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      // Own nodes, so screen readers keep both notices apart.
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: error ? scheme.errorContainer : scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                error ? Icons.error_outline : Icons.hourglass_top,
                size: 20,
                color: fg,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: TextStyle(color: fg)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context) {
    final question = _question;
    if (_loading || (question == null && _loadError == null)) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(child: CircularProgressIndicator.adaptive()),
        ),
      ];
    }
    if (question == null) {
      return [
        _notice(_loadError!),
        const SizedBox(height: 18),
        FilledButton(onPressed: _load, child: const Text('Erneut versuchen')),
      ];
    }
    return [
      Semantics(
        header: true,
        child: Text(
          question.question,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      const SizedBox(height: 16),
      TextField(
        key: const ValueKey('bot-check-answer'),
        controller: _answer,
        focusNode: _focus,
        autofocus: true,
        maxLength: 100,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Deine Antwort',
          helperText: question.hint.isEmpty ? null : question.hint,
          counterText: '',
        ),
        onChanged: (_) {
          if (_error != null && _wait == 0) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      if (_error != null) _notice(_error!),
      if (_wait > 0)
        _notice(
          'Kurze Pause nach mehreren Versuchen. Danach kannst du es noch '
          'einmal probieren.',
          error: false,
        ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: _busy || _wait > 0 ? null : _submit,
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(_wait > 0 ? 'Noch $_wait s warten' : 'Weiter'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
              children: [
                const Row(
                  children: [
                    BrandLogo(size: 37),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        Brand.name,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 38),
                Semantics(
                  header: true,
                  child: Text(
                    'Bevor es losgeht',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Kurze Frage, damit wir wissen, dass du kein Bot bist.',
                ),
                const SizedBox(height: 28),
                ..._content(context),
                const SizedBox(height: 28),
                const PrivacyLinks(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
