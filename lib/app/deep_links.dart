import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/device_services.dart';
import '../features/accounts/ui/accounts_admin_screen.dart';
import '../features/events/ui/event_detail_screen.dart';
import '../features/messages/ui/message_detail_screen.dart';
import '../features/scripts/ui/script_reader_screen.dart';
import '../features/slots/ui/slot_pool_screen.dart';
import '../shared/navigation.dart';

/// Opens notification and link targets. Targets that arrive before the
/// member has access wait until [takePending] hands them back.
class DeepLinkRouter {
  DeepLinkRouter({
    required this.controller,
    required this.navigator,
    required this.messenger,
    required this.isMounted,
  });
  final AppController controller;
  final GlobalKey<NavigatorState> navigator;
  final GlobalKey<ScaffoldMessengerState> messenger;
  final bool Function() isMounted;
  AppTarget? _pendingTarget;

  bool get hasPending => _pendingTarget != null;

  /// Removes and returns the waiting target, if any.
  AppTarget? takePending() {
    final target = _pendingTarget;
    _pendingTarget = null;
    return target;
  }

  void handle(AppTarget target) {
    if (!controller.hasAccess ||
        controller.user!.mustChangePassword ||
        navigator.currentState == null) {
      _pendingTarget = target;
      return;
    }
    _pendingTarget = null;
    if (target.attendance != null && target.recipientUid != null) {
      unawaited(_respondToTarget(target));
    }
    final context = navigator.currentContext!;
    if (target.kind == 'events') {
      openPage(
        context,
        EventDetailScreen(controller: controller, eventId: target.id),
      );
    } else if (target.kind == 'accounts') {
      // New registrations: only admins can act on them.
      if (controller.user?.isAdmin != true) return;
      openPage(
        context,
        AccountsAdminScreen(
          controller: controller,
          initialView: 'accounts',
          initialFilter: 'pending',
        ),
      );
    } else if (target.kind == 'slots') {
      openPage(
        context,
        SlotPoolScreen(controller: controller, poolId: target.id),
      );
    } else if (target.kind == 'messages') {
      openPage(
        context,
        MessageTargetScreen(controller: controller, messageId: target.id),
      );
    } else {
      openPage(
        context,
        ScriptReaderScreen(controller: controller, productionId: target.id),
      );
    }
  }

  Future<void> _respondToTarget(AppTarget target) async {
    String message;
    try {
      message = await controller.respondFromNotification(
        target.id,
        target.attendance!,
        target.recipientUid!,
      );
    } catch (error) {
      message = error.toString();
    }
    if (isMounted()) {
      messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
