import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'app_controller.dart';
import 'brand.dart';
import 'identity.dart';

/// Validated navigation targets; push payloads never execute external URLs.
class AppTarget {
  const AppTarget(this.kind, this.id);
  final String kind, id;
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
  // Native notification payloads are displayed by the OS. No credentials or
  // member data are persisted by this background handler.
  if (Firebase.apps.isEmpty) await FirebaseConfiguration.initialize();
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
        onForegroundMessage(
          message.notification?.title ?? 'Neues aus deinem Theater',
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
