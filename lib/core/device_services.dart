import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/api_client.dart';
import 'app_controller.dart';
import '../app/brand.dart';
import 'identity.dart';

/// Validated navigation targets; push payloads never execute external URLs.
class AppTarget {
  const AppTarget(
    this.kind,
    this.id, {
    this.attendance,
    this.recipientUid,
    this.intent,
  });
  final String kind, id;
  final String? attendance, recipientUid;

  /// 'decline' opens the decline sheet of the event (the "Du bist eingeplant"
  /// reminder), 'checkin' its attendance check-in (the reminder to record
  /// it); null otherwise.
  final String? intent;

  static String? _intent(Object? value) =>
      value == 'decline' || value == 'checkin' ? value as String : null;

  static AppTarget? fromNotificationResponse(NotificationResponse response) {
    try {
      final data = Map<String, dynamic>.from(
        jsonDecode(response.payload ?? '{}') as Map,
      );
      final target = fromData(data);
      if (target == null) return null;
      final uid = data['recipientUid'];
      final action = response.actionId;
      // 'planned' (implicit attendance) offers "Ok", an explicit yes, and
      // "Komme nicht".
      final actions = switch (data['attendanceActions']) {
        'true' || 'planned' => const {'yes', 'no'},
        _ => const <String>{},
      };
      if (target.kind == 'events' &&
          uid is String &&
          uid.isNotEmpty &&
          actions.contains(action)) {
        return AppTarget(
          'events',
          target.id,
          attendance: action,
          recipientUid: uid,
        );
      }
      return target;
    } catch (_) {
      return null;
    }
  }

  static AppTarget? fromUri(Uri uri) {
    try {
      if (uri.scheme != 'theaterapp' ||
          uri.host != 'app' ||
          uri.userInfo.isNotEmpty) {
        return null;
      }
      final path = uri.pathSegments;
      if (path.length != 2 ||
          !const {
            'events',
            'productions',
            'messages',
            'accounts',
            'slots',
            'polls',
            'feedback',
            'admin-feedback',
          }.contains(path[0]) ||
          path[1].isEmpty ||
          path[1].length > 200) {
        return null;
      }
      return AppTarget(
        path[0],
        path[1],
        intent: path[0] == 'events'
            ? _intent(uri.queryParameters['intent'])
            : null,
      );
    } on FormatException {
      // A syntactically valid URI can still contain invalid UTF-8 segments.
      return null;
    }
  }

  static AppTarget? fromWebUri(Uri uri) {
    try {
      final link = uri.queryParameters['target'];
      if (link == null) return null;
      final target = Uri.tryParse(link);
      return target == null ? null : fromUri(target);
    } on FormatException {
      // Optional query parameters must not prevent the app from starting.
      return null;
    }
  }

  static AppTarget? fromData(Map<String, dynamic> data) {
    final link = data['deepLink'];
    if (link is String) return fromUri(Uri.tryParse(link) ?? Uri());
    final event = data['eventId'];
    if (event is String && event.isNotEmpty && event.length <= 200) {
      return AppTarget('events', event, intent: _intent(data['intent']));
    }
    final production = data['productionId'];
    if (production is String &&
        production.isNotEmpty &&
        production.length <= 200) {
      return AppTarget('productions', production);
    }
    final message = data['messageId'];
    if (message is String && message.isNotEmpty && message.length <= 200) {
      return AppTarget('messages', message);
    }
    final slotPool = data['slotPoolId'];
    if (slotPool is String && slotPool.isNotEmpty && slotPool.length <= 200) {
      return AppTarget('slots', slotPool);
    }
    final account = data['accountUid'];
    if (account is String && account.isNotEmpty && account.length <= 200) {
      return AppTarget('accounts', account);
    }
    final poll = data['pollId'];
    if (poll is String && poll.isNotEmpty && poll.length <= 200) {
      return AppTarget('polls', poll);
    }
    // An answer to the member's own feedback, or a ticket for the admins.
    final feedback = data['feedbackId'];
    if (feedback is String && feedback.isNotEmpty && feedback.length <= 200) {
      return AppTarget('feedback', feedback);
    }
    final adminFeedback = data['adminFeedbackId'];
    if (adminFeedback is String &&
        adminFeedback.isNotEmpty &&
        adminFeedback.length <= 200) {
      return AppTarget('admin-feedback', adminFeedback);
    }
    return null;
  }
}

@pragma('vm:entry-point')
Future<void> firebaseBackgroundMessage(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) await FirebaseConfiguration.initialize();
  if (message.notification == null &&
      message.data['notificationId'] is String) {
    await AndroidPushNotifications.initialize();
    await AndroidPushNotifications.show(message.data);
  }
}

abstract final class AndroidPushNotifications {
  static final plugin = FlutterLocalNotificationsPlugin();
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> initialize({
    void Function(NotificationResponse)? onResponse,
  }) async {
    if (!supported) return;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
      onDidReceiveNotificationResponse: onResponse,
    );
  }

  static Future<void> show(Map<String, dynamic> data) async {
    if (!supported) return;
    final title = data['title'];
    final body = data['body'];
    if (title is! String || body is! String) return;
    // Stable across isolates, so duplicate deliveries replace the same card.
    final key = '${data['notificationId']}';
    final id = key.codeUnits.fold(
      0,
      (int hash, unit) => (hash * 31 + unit) & 0x7fffffff,
    );
    await plugin.show(
      id: id,
      title: title,
      body: body,
      payload: jsonEncode(data),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'theater_updates',
          'Theatertermine und Mitteilungen',
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(body),
          actions: attendanceActions(data),
        ),
      ),
    );
  }

  /// The quick answers on an event notification: "Komme" and "Komme nicht"
  /// for open invitations; "Ok" and "Komme nicht" for implicit attendees
  /// (everyone counts as attending), where "Ok" sends an explicit yes.
  static List<AndroidNotificationAction>? attendanceActions(
    Map<String, dynamic> data,
  ) {
    if (AppTarget.fromData(data)?.kind != 'events') return null;
    const yes = AndroidNotificationAction(
      'yes',
      'Komme',
      showsUserInterface: true,
    );
    const ok = AndroidNotificationAction('yes', 'Ok', showsUserInterface: true);
    const no = AndroidNotificationAction(
      'no',
      'Komme nicht',
      showsUserInterface: true,
    );
    return switch (data['attendanceActions']) {
      'true' => const [yes, no],
      'planned' => const [ok, no],
      _ => null,
    };
  }
}

class DeviceServices {
  DeviceServices(
    this.controller, {
    required this.onTarget,
    required this.onForegroundMessage,
  }) {
    controller.beforeLogout = disablePush;
  }
  final AppController controller;
  final void Function(AppTarget) onTarget;
  final void Function(String) onForegroundMessage;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  StreamSubscription<String>? _tokenRefresh;
  String? _registeredToken;
  bool _firebaseReady = false;
  Future<void>? _pushInitialization, _pushRestore;
  Future<void> start() async {
    if (kIsWeb) {
      final target = AppTarget.fromWebUri(Uri.base);
      if (target != null) onTarget(target);
      return;
    }
    if (AndroidPushNotifications.supported) {
      await AndroidPushNotifications.initialize(
        onResponse: (response) {
          final target = AppTarget.fromNotificationResponse(response);
          if (target != null) onTarget(target);
        },
      );
      final launch = await AndroidPushNotifications.plugin
          .getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true &&
          launch?.notificationResponse != null) {
        final target = AppTarget.fromNotificationResponse(
          launch!.notificationResponse!,
        );
        if (target != null) onTarget(target);
      }
    }
    final links = AppLinks();
    try {
      final initial = await links.getInitialLink();
      if (initial != null) {
        final target = AppTarget.fromUri(initial);
        if (target != null) onTarget(target);
      }
      _subscriptions.add(
        links.uriLinkStream.listen((uri) {
          final target = AppTarget.fromUri(uri);
          if (target != null) onTarget(target);
        }, onError: (Object _) {}),
      );
    } catch (_) {
      /* Link handling is optional on test hosts. */
    }
  }

  Future<void> _initializePush() {
    if (_firebaseReady) return Future.value();
    return _pushInitialization ??= _initializePushOnce().whenComplete(() {
      _pushInitialization = null;
    });
  }

  Future<void> _initializePushOnce() async {
    if (_firebaseReady) return;
    if (!Brand.pushEnabled) {
      throw const ApiException('Push ist für diesen Build nicht eingerichtet.');
    }
    await FirebaseConfiguration.initialize();
    if (!await FirebaseMessaging.instance.isSupported()) {
      throw const ApiException(
        'Dieser Browser unterstützt keine Push-Mitteilungen.',
      );
    }
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundMessage);
    }
    _subscriptions.add(
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final target = AppTarget.fromData(message.data);
        if (target != null) onTarget(target);
      }),
    );
    _subscriptions.add(
      FirebaseMessaging.onMessage.listen((message) {
        if (message.notification == null &&
            message.data['notificationId'] is String) {
          unawaited(AndroidPushNotifications.show(message.data));
        }
        onForegroundMessage(
          message.notification?.title ??
              message.data['title'] as String? ??
              'Neues aus deinem Theater',
        );
      }),
    );
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      final target = AppTarget.fromData(initial.data);
      if (target != null) onTarget(target);
    }
    _firebaseReady = true;
  }

  /// Approved accounts and accounts still waiting for approval may register a
  /// device; the server only delivers once the account is linked and approved.
  bool get _canRegister =>
      !controller.isDemo &&
      (controller.hasAccess || controller.user?.status == 'pending');

  /// Registers this device for push. [restore] (at a start or account
  /// change) leaves out a registration the server already has, see
  /// [AppController.registerDevice].
  Future<String> enablePush({bool restore = false}) async {
    if (!_canRegister) {
      return 'Push benötigt ein angemeldetes Theaterkonto.';
    }
    final session = controller.sessionEpoch;
    await _initializePush();
    if (controller.sessionEpoch != session) return 'Bitte erneut anmelden.';
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (controller.sessionEpoch != session) return 'Bitte erneut anmelden.';
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      return 'Benachrichtigungen sind in den Geräteeinstellungen deaktiviert.';
    }
    if (kIsWeb && FirebaseConfiguration.vapidKey.isEmpty) {
      throw const ApiException('Der Web-Push-Schlüssel fehlt.');
    }
    final token = await FirebaseMessaging.instance.getToken(
      vapidKey: kIsWeb ? FirebaseConfiguration.vapidKey : null,
    );
    if (controller.sessionEpoch != session || controller.isDemo) {
      return 'Bitte erneut anmelden.';
    }
    if (token == null) {
      return 'Noch kein Gerätetoken erhalten. Bitte später erneut versuchen.';
    }
    await controller.registerDevice(
      token,
      kIsWeb
          ? 'web'
          : defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios'
          : 'android',
      notificationActions: AndroidPushNotifications.supported,
      ifStale: restore,
    );
    if (controller.sessionEpoch != session) return 'Bitte erneut anmelden.';
    _registeredToken = token;
    if (controller.preferences['pushEnabled'] != true) {
      await controller.setPreference('pushEnabled', true);
      if (controller.sessionEpoch != session) return 'Bitte erneut anmelden.';
    }
    await _tokenRefresh?.cancel();
    if (controller.sessionEpoch != session) return 'Bitte erneut anmelden.';
    _tokenRefresh = FirebaseMessaging.instance.onTokenRefresh.listen((
      next,
    ) async {
      if (controller.sessionEpoch != session || controller.isDemo) return;
      try {
        await controller.registerDevice(
          next,
          kIsWeb
              ? 'web'
              : defaultTargetPlatform == TargetPlatform.iOS
              ? 'ios'
              : 'android',
          notificationActions: AndroidPushNotifications.supported,
        );
        if (controller.sessionEpoch == session) _registeredToken = next;
      } catch (_) {
        /* User can explicitly retry enabling; never claim delivery. */
      }
    });
    return controller.pushConfigured
        ? 'Push ist für dieses Gerät aktiviert.'
        : 'Gerät registriert. Der Server hat den Push-Versand noch nicht aktiviert.';
  }

  Future<bool> preparePushPrompt() async {
    if (!Brand.pushEnabled ||
        controller.isDemo ||
        !controller.hasAccess ||
        controller.preferences['pushPromptSeen'] == true ||
        controller.preferences.containsKey('pushEnabled')) {
      return false;
    }
    final session = controller.sessionEpoch;
    try {
      await _initializePush();
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (session != controller.sessionEpoch) return false;
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        await enablePush();
        return false;
      }
      if (kIsWeb &&
          settings.authorizationStatus == AuthorizationStatus.denied) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Registers again at a start or account change when push was enabled.
  /// Calls while one runs share it.
  Future<void> restorePush() {
    final running = _pushRestore;
    if (running != null) return running;
    final task = _restorePush();
    _pushRestore = task;
    return task.whenComplete(() {
      if (identical(_pushRestore, task)) _pushRestore = null;
    });
  }

  Future<void> _restorePush() async {
    final session = controller.sessionEpoch;
    if (!Brand.pushEnabled ||
        controller.preferences['pushEnabled'] != true ||
        !_canRegister) {
      return;
    }
    try {
      await _initializePush();
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (controller.sessionEpoch != session) return;
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        await enablePush(restore: true);
      }
    } catch (_) {
      /* App stays usable when provider is unavailable. */
    }
  }

  Future<void> disablePush() async {
    final session = controller.sessionEpoch;
    await _tokenRefresh?.cancel();
    if (controller.sessionEpoch != session) return;
    _tokenRefresh = null;
    final token = _registeredToken;
    if (token != null && controller.user != null && !controller.isDemo) {
      try {
        await controller.unregisterDevice(token);
      } catch (_) {
        /* Server session logout also removes its device registrations. */
      }
    }
    if (controller.sessionEpoch != session) return;
    if (_firebaseReady) {
      try {
        await FirebaseMessaging.instance.deleteToken();
      } catch (_) {}
    }
    if (controller.sessionEpoch != session) return;
    _registeredToken = null;
    if (controller.user != null) {
      await controller.setPreference('pushEnabled', false);
    }
  }

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _tokenRefresh?.cancel();
  }
}
