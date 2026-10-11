import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// Whether [message] is addressed to [user].
///
/// Members only receive messages meant for them. Admins receive every
/// message together with its reach (`recipientIds`), which then decides.
bool messageAddressedTo(AppUser? user, JsonMap message) {
  if (user?.isAdmin != true || !message.containsKey('recipientIds')) {
    return true;
  }
  final personId = user!.personId;
  return personId != null &&
      jsonList(message['recipientIds']).map(intValue).contains(personId);
}

/// Whether [message] still waits to be read by [user]. The author's own
/// messages and, for admins, messages to other people never count.
bool messageUnreadFor(AppUser? user, JsonMap message) {
  final personId = user?.personId;
  return message['read'] != true &&
      (personId == null || intValue(message['authorId'], -1) != personId) &&
      messageAddressedTo(user, message);
}

/// Messages the member has not read yet.
Iterable<JsonMap> unreadMessages(AppController controller) =>
    controller.messages.where((m) => messageUnreadFor(controller.user, m));

int unreadMessageCount(AppController controller) =>
    unreadMessages(controller).length;
