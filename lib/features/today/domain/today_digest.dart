import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../events/domain/event_selectors.dart';
import '../../messages/domain/message_selectors.dart';
import '../../polls/domain/poll_selectors.dart' as polls;
import '../../slots/domain/slot_pool.dart';

/// Everything the start page shows, picked and ordered once so the screen
/// only lays it out.
class TodayDigest {
  const TodayDigest({
    required this.now,
    required this.next,
    required this.nextOpen,
    required this.openResponses,
    required this.moreOpenResponses,
    required this.laterEvents,
    required this.unread,
    required this.pollsToVote,
    required this.votedPoll,
    required this.slotPools,
    required this.registrations,
    required this.scriptProduction,
    required this.scriptEvent,
    required this.scriptSceneId,
  });

  /// At most this many further open events are answerable inline.
  static const maxOpenResponses = 3;

  /// At most this many events are previewed under "Weitere Termine".
  static const maxLaterEvents = 3;

  factory TodayDigest.from(AppController controller) {
    final now = controller.now;
    final upcoming = upcomingEvents(controller, now);
    // Admins also receive events they are not invited to; those are never
    // "Dein nächster Termin" but still appear among the later events. The
    // same goes for events the person declined or misses for an absence, and
    // for events an admin's queued deletion cancels.
    final deleting = _deleting(controller);
    final next = upcoming
        .where(
          (e) =>
              e.addressedToMe &&
              !deleting.contains(e.id) &&
              _attends(e, controller.absences),
        )
        .firstOrNull;
    final soon = now.add(responseBadgeWindow);
    final open = upcoming
        .where((e) => e != next)
        .where(
          (e) =>
              e.needsResponse &&
              controller.canRespondTo(e) &&
              (e.startsAt == null || e.startsAt!.isBefore(soon)),
        )
        .toList();
    final shownOpen = open.take(maxOpenResponses).toList();
    final shownIds = {for (final e in shownOpen) e.id};
    final toVote = polls.pollsToVote(controller);
    final (production, scriptEvent) = _script(controller, next);
    final scene = scriptEvent?.sceneIds.firstOrNull;
    return TodayDigest(
      now: now,
      next: next,
      nextOpen:
          next != null && next.needsResponse && controller.canRespondTo(next),
      openResponses: shownOpen,
      moreOpenResponses: open.length - shownOpen.length,
      // Events answerable above are not repeated in the preview.
      laterEvents: upcoming
          .where((e) => e != next && !shownIds.contains(e.id))
          .take(maxLaterEvents)
          .toList(),
      unread: unreadMessages(controller).toList(),
      pollsToVote: toVote,
      // Only a poll the member actually voted in counts as done; admins
      // also receive polls they were never asked to vote in (newer servers
      // mark those with `addressedToMe`).
      votedPoll: toVote.isEmpty
          ? controller.polls
                .where(
                  (p) =>
                      !p.isClosedAt(controller.now) &&
                      p.selectedOptionId != null,
                )
                .firstOrNull
          : null,
      slotPools: slotPoolsToChoose(controller),
      registrations: controller.user?.isAdmin == true
          ? controller.openRegistrationCount
          : 0,
      scriptProduction: production,
      scriptEvent: scriptEvent,
      scriptSceneId: scene,
    );
  }

  /// Whether the person still plans to come: not declined, and not left
  /// unanswered on a day of an own absence (which the server only declines
  /// while responses are still accepted). A confirmation keeps the event.
  static bool _attends(TheaterEvent event, List<Absence> absences) {
    if (event.response == 'no') return false;
    final start = event.startsAt;
    if (event.response != 'open' || start == null) return true;
    return !absences.any((a) => a.coversDay(start));
  }

  /// Ids of the events a queued, not yet confirmed `event.delete` removes;
  /// deletions are not projected, so the events still show until the sync.
  static Set<String> _deleting(AppController controller) {
    final ids = <String>{};
    for (final action in controller.outbox) {
      final body = action.payload;
      if (action.failed || body['action'] != 'event.delete') continue;
      final id = textValue(body['id']);
      ids.add(id);
      final first = controller.events.where((e) => e.id == id).firstOrNull;
      final series = first?.seriesId, start = first?.startsAt;
      if (body['series'] != 'following' || series == null || start == null) {
        continue;
      }
      // "This and all following" mirrors the server's choice of occurrences.
      ids.addAll(
        controller.events
            .where(
              (e) =>
                  e.seriesId == series &&
                  !e.fromSlotPool &&
                  e.startsAt != null &&
                  !e.startsAt!.isBefore(start),
            )
            .map((e) => e.id),
      );
    }
    return ids;
  }

  /// The script worth opening first: the one the next event rehearses, else
  /// an active production the person belongs to, else the newest active one.
  /// The event is only set when the production comes from it.
  static (Production?, TheaterEvent?) _script(
    AppController controller,
    TheaterEvent? next,
  ) {
    final linked = next?.productionId == null
        ? null
        : controller.productions
              .where((p) => p.id == next!.productionId)
              .firstOrNull;
    if (linked != null) return (linked, next);
    final active = controller.activeProductions;
    final personId = controller.user?.personId;
    final own = personId == null
        ? null
        : active.where((p) => p.ensemble.contains(personId)).firstOrNull;
    return (own ?? active.firstOrNull, null);
  }

  final DateTime now;

  /// The first event addressed to the person that has not ended yet and that
  /// they have not declined (themselves or through an absence).
  final TheaterEvent? next;

  /// Whether [next] still waits for an answer and can get one.
  final bool nextOpen;

  /// Further events still waiting for an answer within the badge window,
  /// at most [maxOpenResponses]; [moreOpenResponses] counts the rest.
  final List<TheaterEvent> openResponses;
  final int moreOpenResponses;

  /// The events after [next] that are not in [openResponses].
  final List<TheaterEvent> laterEvents;

  final List<JsonMap> unread;
  final List<Poll> pollsToVote;

  /// An open poll the person already voted in, while none waits for a vote.
  final Poll? votedPoll;
  final List<SlotPool> slotPools;

  /// Registrations an admin can link now; 0 for everyone else.
  final int registrations;

  final Production? scriptProduction;

  /// The next event when [scriptProduction] was chosen for it.
  final TheaterEvent? scriptEvent;

  /// The first scene linked to [scriptEvent], where the reader opens.
  final String? scriptSceneId;

  /// Whether anything still waits for the person.
  bool get hasPending =>
      nextOpen ||
      openResponses.isNotEmpty ||
      moreOpenResponses > 0 ||
      unread.isNotEmpty ||
      pollsToVote.isNotEmpty ||
      slotPools.isNotEmpty ||
      registrations > 0;
}
