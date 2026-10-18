import '../../../core/app_controller.dart';
import '../../../core/app_version.dart';
import '../../../core/models.dart';
import '../domain/feedback_entry.dart';

/// Whether members can send feedback: the server must offer it, and the demo
/// has no server to send it to.
bool feedbackAvailable(AppController controller) =>
    !controller.isDemo && controller.supports('feedback');

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

/// All feedback, newest first as the server sends it.
Future<List<FeedbackEntry>> loadFeedback(AppController controller) async {
  final data = await controller.remote('/admin/feedback');
  return [
    for (final e in jsonList(data['feedback']))
      FeedbackEntry.fromJson(jsonMap(e)),
  ];
}

/// Marks [entry] as done or open again; returns the updated entry.
Future<FeedbackEntry> setFeedbackDone(
  AppController controller,
  FeedbackEntry entry, {
  required bool done,
}) async {
  final data = await controller.remote(
    '/admin/feedback/${Uri.encodeComponent(entry.id)}',
    method: 'PUT',
    body: {'status': done ? 'done' : 'new', 'version': entry.version},
  );
  return FeedbackEntry.fromJson(jsonMap(data['feedback']));
}
