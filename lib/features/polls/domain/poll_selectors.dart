import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// Open polls the member has not voted in yet.
List<Poll> pollsToVote(AppController controller) => controller.polls
    .where((p) => !p.isClosed && p.selectedOptionId == null)
    .toList();
