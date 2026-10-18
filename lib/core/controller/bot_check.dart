part of '../app_controller.dart';

/// The knowledge question of the bot check, as the server asks it.
class BotCheckQuestion {
  const BotCheckQuestion(this.question, {this.hint = ''});
  final String question, hint;
}

/// A simple knowledge question before the first sign-in or registration on a
/// device ("Botschutz"). Only the server knows and checks the answers. A
/// correct answer returns a short-lived proof that a new account presents
/// once. The device remembers that the question was answered, and the answer
/// itself to request a fresh proof before a later registration.
extension BotCheckController on AppController {
  static const _key = 'botCheck';

  /// Whether the sign-in screens wait for the question. Never for signed-in
  /// members, devices that already had a session, the demo or older servers.
  bool get needsBotCheck =>
      usesFirebase &&
      !_isDemo &&
      _user == null &&
      !_botCheckPassed &&
      !_botCheckUnsupported;

  Future<void> _loadBotCheck() async {
    final saved = await _store.read('_device', _key);
    _botCheckPassed = saved?['passedAt'] != null;
    final answer = textValue(saved?['answer']);
    _botCheckAnswer = answer.isEmpty ? null : answer;
  }

  Future<void> _rememberBotCheck({String? answer}) async {
    _botCheckPassed = true;
    _botCheckAnswer = answer ?? _botCheckAnswer;
    final keep = _botCheckAnswer;
    await _write(
      () => _store.write('_device', _key, {
        'passedAt': _clock().toUtc().toIso8601String(),
        'answer': ?keep,
      }),
    );
  }

  /// Loads the question; null when the server has no bot check (older
  /// servers answer the unknown public route with 401 or 404).
  Future<BotCheckQuestion?> loadBotCheckQuestion() async {
    try {
      final r = await _api.request(_apiBaseUrl, 'GET', '/bot-check');
      final question = textValue(r['question']);
      if (question.isEmpty) throw const FormatException('No question');
      return BotCheckQuestion(question, hint: textValue(r['hint']));
    } on ApiException catch (e) {
      if (e.statusCode != 401 && e.statusCode != 404) rethrow;
      _botCheckUnsupported = true;
      _notify();
      return null;
    }
  }

  /// Sends [answer] to the server. Throws an [ApiException] with code
  /// `bot_check_wrong` for a wrong answer and `rate_limited` after too many.
  Future<void> answerBotCheck(String answer) async {
    final given = answer.trim();
    final r = await _api.request(
      _apiBaseUrl,
      'POST',
      '/bot-check',
      body: {'answer': given},
    );
    _botProof = textValue(r['proof']);
    _botProofExpiresAt = dateValue(r['expiresAt']);
    await _rememberBotCheck(answer: given);
    _notify();
  }

  /// A proof for the next sign-in, renewed with the remembered answer when
  /// needed. Never throws: without a proof a new account is still accepted.
  Future<String?> _freshBotProof() async {
    final proof = _botProof, expires = _botProofExpiresAt;
    if (proof != null &&
        proof.isNotEmpty &&
        expires != null &&
        expires.isAfter(_clock().add(const Duration(minutes: 2)))) {
      return proof;
    }
    final answer = _botCheckAnswer;
    if (answer == null || _botCheckUnsupported || _apiBaseUrl.isEmpty) {
      return null;
    }
    try {
      final r = await _api.request(
        _apiBaseUrl,
        'POST',
        '/bot-check',
        body: {'answer': answer},
      );
      _botProof = textValue(r['proof']);
      _botProofExpiresAt = dateValue(r['expiresAt']);
      return _botProof!.isEmpty ? null : _botProof;
    } on ApiException catch (e) {
      // A changed question: the old answer no longer counts.
      if (e.code == 'bot_check_wrong') {
        _botCheckAnswer = null;
        await _rememberBotCheck();
      }
      return null;
    }
  }

  /// A proof counts once; the next registration requests a new one.
  void _consumeBotProof() {
    _botProof = null;
    _botProofExpiresAt = null;
  }
}
