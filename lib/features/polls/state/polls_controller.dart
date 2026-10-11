part of '../../../core/app_controller.dart';

/// Voting in polls.
extension PollsController on AppController {
  Future<ActionOutcome> vote(String pollId, String optionId) async {
    final poll = _polls.where((e) => e.id == pollId).firstOrNull;
    if (poll == null || !poll.options.any((e) => e.id == optionId)) {
      throw const ApiException(
        'Diese Abstimmungsoption ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    if (poll.isClosed) {
      throw const ApiException(
        'Die Abstimmung ist bereits beendet.',
        statusCode: 409,
      );
    }
    return performAction({
      'action': 'poll.vote',
      'pollId': pollId,
      'optionId': optionId,
    });
  }
}
