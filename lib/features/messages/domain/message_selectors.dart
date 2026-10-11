import '../../../core/app_controller.dart';
import '../../../core/models.dart';

/// Messages the member has not read yet.
Iterable<JsonMap> unreadMessages(AppController controller) =>
    controller.messages.where((m) => m['read'] != true);

int unreadMessageCount(AppController controller) =>
    unreadMessages(controller).length;
