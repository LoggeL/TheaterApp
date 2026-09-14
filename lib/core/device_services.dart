import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_controller.dart';
import 'brand.dart';
import 'identity.dart';

/// Validated navigation targets; push payloads never execute external URLs.
class AppTarget {
  const AppTarget(this.kind, this.id, {this.attendance, this.recipientUid});
  final String kind, id;
  final String? attendance, recipientUid;

  static AppTarget? fromNotificationResponse(NotificationResponse response) {
    try {
      final data = Map<String, dynamic>.from(
        jsonDecode(response.payload ?? '{}') as Map,
      );
      final target = fromData(data);
      if (target == null) return null;
      final uid = data['recipientUid'];
      final action = response.actionId;
      if (target.kind == 'events' &&
          data['attendanceActions'] == 'true' &&
          uid is String &&
          uid.isNotEmpty &&
          const {'yes', 'no'}.contains(action)) {
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
    if (uri.scheme != 'theaterapp' ||
        uri.host != 'app' ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final path = uri.pathSegments;
    if (path.length != 2 ||
        !const {'events', 'productions', 'messages'}.contains(path[0]) ||
        path[1].isEmpty ||
        path[1].length > 200) {
      return null;
    }
    return AppTarget(path[0], path[1]);
  }

  static AppTarget? fromData(Map<String, dynamic> data) {
    final link = data['deepLink'];
    if (link is String) return fromUri(Uri.tryParse(link) ?? Uri());
    final event = data['eventId'];
    if (event is String && event.isNotEmpty && event.length <= 200) {
      return AppTarget('events', event);
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
    final actions =
        data['attendanceActions'] == 'true' &&
        AppTarget.fromData(data)?.kind == 'events';
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
          actions: actions
              ? const [
                  AndroidNotificationAction(
                    'yes',
                    'Komme',
                    showsUserInterface: true,
                  ),
                  AndroidNotificationAction(
                    'no',
                    'Komme nicht',
                    showsUserInterface: true,
                  ),
                ]
              : null,
        ),
      ),
    );
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
  Future<void>? _pushInitialization;
  Future<void> start() async {
    if (kIsWeb) {
      final target = AppTarget.fromUri(
        Uri.tryParse(Uri.base.queryParameters['target'] ?? '') ?? Uri(),
      );
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
      throw StateError('Push ist für diesen Build nicht eingerichtet.');
    }
    await FirebaseConfiguration.initialize();
    if (!await FirebaseMessaging.instance.isSupported()) {
      throw StateError('Dieser Browser unterstützt keine Push-Mitteilungen.');
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

  Future<String> enablePush() async {
    if (controller.isDemo || !controller.hasAccess) {
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
      throw StateError('Der Web-Push-Schlüssel fehlt.');
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
    );
    if (controller.sessionEpoch != session) return 'Bitte erneut anmelden.';
    _registeredToken = token;
    await controller.setPreference('pushEnabled', true);
    if (controller.sessionEpoch != session) return 'Bitte erneut anmelden.';
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

  Future<void> restorePush() async {
    final session = controller.sessionEpoch;
    if (!Brand.pushEnabled ||
        controller.preferences['pushEnabled'] != true ||
        controller.isDemo ||
        !controller.hasAccess) {
      return;
    }
    try {
      await _initializePush();
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      if (controller.sessionEpoch != session) return;
      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        await enablePush();
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
