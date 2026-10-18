import '../../../core/app_controller.dart';
import '../../../core/app_version.dart';
import '../../../core/models.dart';
import '../domain/feedback_ticket.dart';

/// Whether members can send feedback: the server must offer it, and the demo
/// has no server to send it to.
bool feedbackAvailable(AppController controller) =>
    !controller.isDemo && controller.supports('feedback');

/// Whether the server keeps feedback as tickets with answers. Older servers
/// only take feedback in; the app then explains instead of failing.
bool feedbackTicketsAvailable(AppController controller) =>
    feedbackAvailable(controller) && controller.supports('feedbackTickets');

String _path(String id) => Uri.encodeComponent(id);

/// Sends feedback to the admins; returns the id the server assigned.
Future<String> submitFeedback(
  AppController controller, {
  required String message,
  required String category,
}) async {
  final result = await controller.remote(
    '/feedback',
    method: 'POST',
    body: {
      'message': message,
      'category': category,
      'appVersion': appVersion,
      'platform': feedbackPlatform(),
    },
  );
  return textValue(result['id']);
}

// --- The member's own tickets ---

/// The member's own tickets, most recent activity first.
Future<List<FeedbackTicket>> loadOwnFeedback(AppController controller) async {
  final data = await controller.remote('/feedback');
  return [
    for (final t in jsonList(data['tickets']))
      FeedbackTicket.fromJson(jsonMap(t)),
  ];
}

Future<FeedbackTicket> loadOwnTicket(
  AppController controller,
  String id,
) async {
  final data = await controller.remote('/feedback/${_path(id)}');
  return FeedbackTicket.fromJson(jsonMap(data['ticket']));
}

/// A follow-up by the author; it reopens a closed ticket.
Future<FeedbackTicket> replyToOwnFeedback(
  AppController controller,
  FeedbackTicket ticket,
  String text,
) async {
  final data = await controller.remote(
    '/feedback/${_path(ticket.id)}/messages',
    method: 'POST',
    body: {'text': text},
  );
  return FeedbackTicket.fromJson(jsonMap(data['ticket']));
}

Future<FeedbackTicket> markOwnFeedbackRead(
  AppController controller,
  FeedbackTicket ticket,
) async {
  final data = await controller.remote(
    '/feedback/${_path(ticket.id)}/read',
    method: 'PUT',
  );
  return FeedbackTicket.fromJson(jsonMap(data['ticket']));
}

Future<FeedbackTicket> closeOwnFeedback(
  AppController controller,
  FeedbackTicket ticket,
) async {
  final data = await controller.remote(
    '/feedback/${_path(ticket.id)}',
    method: 'PUT',
    body: {'status': 'closed', 'version': ticket.version},
  );
  return FeedbackTicket.fromJson(jsonMap(data['ticket']));
}

// --- All tickets, for the admins ---

/// All feedback, most recent activity first as the server sends it.
Future<List<FeedbackTicket>> loadFeedback(AppController controller) async {
  final data = await controller.remote('/admin/feedback');
  return [
    for (final e in jsonList(data['feedback']))
      FeedbackTicket.fromJson(jsonMap(e)),
  ];
}

Future<FeedbackTicket> loadAdminTicket(
  AppController controller,
  String id,
) async {
  final data = await controller.remote('/admin/feedback/${_path(id)}');
  return FeedbackTicket.fromJson(jsonMap(data['feedback']));
}

/// An admin answer; the author gets a push.
Future<FeedbackTicket> answerFeedback(
  AppController controller,
  FeedbackTicket ticket,
  String text,
) async {
  final data = await controller.remote(
    '/admin/feedback/${_path(ticket.id)}/messages',
    method: 'POST',
    body: {'text': text},
  );
  return FeedbackTicket.fromJson(jsonMap(data['feedback']));
}

/// Closes [ticket] or opens it again; returns the updated ticket. Older
/// servers know the same as `done` and `new`.
Future<FeedbackTicket> setFeedbackClosed(
  AppController controller,
  FeedbackTicket ticket, {
  required bool closed,
}) async {
  final tickets = controller.supports('feedbackTickets');
  final data = await controller.remote(
    '/admin/feedback/${_path(ticket.id)}',
    method: 'PUT',
    body: {
      'status': closed
          ? (tickets ? 'closed' : 'done')
          : (tickets ? 'open' : 'new'),
      'version': ticket.version,
    },
  );
  return FeedbackTicket.fromJson(jsonMap(data['feedback']));
}
