import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// Whether the signed-in member belongs to the audience of [poll].
///
/// Members only receive polls meant for them. Admins receive every poll; the
/// server marks the ones meant for them (`addressedToMe`). Older servers do
/// not, so there the roles, invited people and production ensembles decide.
bool pollAddressesUser(AppController controller, Poll poll) {
  if (poll.addressedToMe != null) return poll.addressedToMe!;
  final user = controller.user;
  if (user?.isAdmin != true || !poll.hasAudience) return true;
  final personId = user!.personId;
  if (personId == null) return false;
  final member =
      controller.members.where((m) => m.id == personId).firstOrNull ??
      TheaterMember(id: personId, name: user.name, roleIds: user.roleIds);
  return member.inAudience(
    poll.roleIds,
    poll.personIds,
    controller.ensemblesOf(poll.productionIds),
  );
}

/// Open polls the member may vote in and has not voted in yet.
List<Poll> pollsToVote(AppController controller) => controller.polls
    .where(
      (p) =>
          !p.isClosedAt(controller.now) &&
          p.selectedOptionId == null &&
          pollAddressesUser(controller, p),
    )
    .toList();
