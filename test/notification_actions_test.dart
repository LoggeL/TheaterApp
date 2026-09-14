import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/data/api_client.dart';
import 'app_controller_test.dart' show TestServer, signIn;

void main() {
  test(
    'notification actions parse only allowed event responses and keep body taps passive',
    () {
      final data = {
        'eventId': 'e-1',
        'recipientUid': 'member-a',
        'attendanceActions': 'true',
      };
      NotificationResponse response(String? action, {String? payload}) =>
          NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotificationAction,
            actionId: action,
            payload: payload ?? jsonEncode(data),
          );
      for (final action in ['yes', 'no']) {
        final target = AppTarget.fromNotificationResponse(response(action))!;
        expect(target.id, 'e-1');
        expect(target.attendance, action);
        expect(target.recipientUid, 'member-a');
      }
      expect(
        AppTarget.fromNotificationResponse(response(null))!.attendance,
        isNull,
      );
      expect(
        AppTarget.fromNotificationResponse(response('delete'))!.attendance,
        isNull,
      );
      expect(
        AppTarget.fromNotificationResponse(response('yes', payload: '{broken')),
        isNull,
      );
      data.remove('recipientUid');
      expect(
        AppTarget.fromNotificationResponse(response('yes'))!.attendance,
        isNull,
      );
    },
  );

  for (final status in ['yes', 'no']) {
    test(
      'quick $status persists on server and reconciles in the app',
      () async {
        final server = TestServer();
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        final event = controller.events.first;
        final message = await controller.respondFromNotification(
          event.id,
          status,
          'member-a',
        );
        expect(server.actionBodies.last['status'], status);
        expect(server.data['attendanceByEvent'][event.id], status);
        expect(controller.outbox, isEmpty);
        expect(
          message,
          status == 'yes' ? 'Zusage gespeichert.' : 'Absage gespeichert.',
        );
      },
    );
  }

  test(
    'offline notification response is queued and later synchronized',
    () async {
      final server = TestServer();
      final c = server.controller();
      addTearDown(c.dispose);
      await signIn(c);
      server.offline = true;
      final message = await c.respondFromNotification(
        c.events.first.id,
        'no',
        'member-a',
      );
      expect(message, contains('vorgemerkt'));
      expect(c.pendingCount, 1);
      server.offline = false;
      await c.refresh();
      expect(c.pendingCount, 0);
    },
  );

  test(
    'another account and rejected changes cannot be reported as saved',
    () async {
      final server = TestServer();
      final c = server.controller();
      addTearDown(c.dispose);
      await signIn(c);
      final eventId = c.events.first.id;
      await expectLater(
        c.respondFromNotification(eventId, 'yes', 'someone-else'),
        throwsA(isA<ApiException>()),
      );
      expect(server.actionBodies, isEmpty);
      server.actionStatus = 409;
      await expectLater(
        c.respondFromNotification(eventId, 'no', 'member-a'),
        throwsA(isA<ApiException>()),
      );
      expect(c.failedCount, 1);
    },
  );
}
