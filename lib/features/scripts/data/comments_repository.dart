import 'package:flutter/foundation.dart';

import '../../../core/app_controller.dart';
import '../../../core/controller/pending_action.dart';
import '../../../core/json.dart';
import '../../../shared/feedback.dart';

/// A comment the ensemble left on one cue of a script.
class CueComment {
  const CueComment({
    required this.id,
    required this.cueId,
    required this.text,
    this.revision = '',
    this.authorId,
    this.authorName = '',
    this.createdAt,
  });
  final String id, cueId, revision, text, authorName;
  final int? authorId;
  final DateTime? createdAt;

  factory CueComment.fromJson(JsonMap json) => CueComment(
    id: textValue(json['id']),
    cueId: textValue(json['cueId']),
    revision: textValue(json['revision']),
    text: textValue(json['text']),
    authorId: json['authorId'] == null ? null : intValue(json['authorId']),
    authorName: textValue(json['authorName']),
    createdAt: dateValue(json['createdAt']),
  );
}

/// The comments of one production, loaded once and shared by the reader
/// (badges per cue) and the comment pages.
class CommentsRepository extends ChangeNotifier {
  CommentsRepository({required this.controller, required this.productionId});
  final AppController controller;
  final String productionId;

  List<CueComment> _comments = const [];
  Future<void>? _loading;
  bool _loaded = false, _busy = false, _disposed = false;
  String? _error;

  bool get loaded => _loaded;
  bool get loading => _busy;
  String? get error => _error;

  /// Comments can only be written with a connected account.
  bool get canWrite => !controller.isDemo && !controller.isOffline;

  /// The comments on [cueId], oldest first.
  List<CueComment> forCue(String cueId) =>
      _comments.where((c) => c.cueId == cueId).toList()..sort(
        (a, b) =>
            (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
      );

  int countFor(String cueId) => _comments.where((c) => c.cueId == cueId).length;

  /// Loads the comments unless they are already there. The demo has none.
  Future<void> ensureLoaded() {
    if (_loaded || controller.isDemo) return Future.value();
    return _loading ?? reload();
  }

  Future<void> reload() {
    if (controller.isDemo) return Future.value();
    return _loading ??= _fetch().whenComplete(() => _loading = null);
  }

  Future<void> _fetch() async {
    _busy = true;
    _notify();
    try {
      final data = await controller.remote(
        '/productions/${Uri.encodeComponent(productionId)}/comments',
      );
      _comments = jsonList(
        data['comments'],
      ).map((c) => CueComment.fromJson(jsonMap(c))).toList();
      _loaded = true;
      _error = null;
    } catch (e) {
      _error = userMessage(e);
    }
    _busy = false;
    _notify();
  }

  /// Saves a new comment on [cueId] and reloads the list once the server
  /// has it.
  Future<ActionOutcome> add({
    required String revision,
    required String cueId,
    required String text,
  }) async {
    final outcome = await controller.performAction({
      'action': 'comment.save',
      'productionId': productionId,
      'revision': revision,
      'cueId': cueId,
      'text': text,
    });
    if (outcome == ActionOutcome.synced) await reload();
    return outcome;
  }

  Future<ActionOutcome> delete(String id) async {
    final outcome = await controller.performAction({
      'action': 'comment.delete',
      'id': id,
    });
    _comments = _comments.where((c) => c.id != id).toList();
    _notify();
    return outcome;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
