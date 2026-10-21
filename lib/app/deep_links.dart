import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/device_services.dart';
import '../features/accounts/ui/accounts_admin_screen.dart';
import '../features/events/ui/event_detail_screen.dart';
import '../features/feedback/feedback.dart';
import '../features/messages/ui/message_detail_screen.dart';
import '../features/polls/ui/poll_detail_screen.dart';
import '../features/scripts/ui/script_reader_screen.dart';
import '../features/slots/ui/slot_pool_screen.dart';
import '../shared/feedback.dart';
import '../shared/navigation.dart';
import 'shell/app_section.dart';

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
    final (section, page) = switch (target.kind) {
      'events' => (
        AppSection.schedule,
        EventDetailScreen(
          controller: controller,
          eventId: target.id,
          // A quick answer from the notification needs no sheet.
          openDecline: target.intent == 'decline' && target.attendance == null,
        ),
      ),
      // New registrations: only admins can act on them.
      'accounts' when controller.user?.isAdmin == true => (
        AppSection.admin,
        AccountsAdminScreen(
          controller: controller,
          // The registration from the push, highlighted among the waiting.
          initialUid: target.id,
        ),
      ),
      'slots' => (
        AppSection.schedule,
        SlotPoolScreen(controller: controller, poolId: target.id),
      ),
      'messages' => (
        AppSection.messages,
        MessageTargetScreen(controller: controller, messageId: target.id),
      ),
      'polls' => (
        AppSection.messages,
        PollDetailScreen(controller: controller, pollId: target.id),
      ),
      'productions' => (
        AppSection.scripts,
        ScriptReaderScreen(controller: controller, productionId: target.id),
      ),
      'feedback' => (
        AppSection.me,
        FeedbackTicketScreen(controller: controller, ticketId: target.id),
      ),
      'admin-feedback' when controller.user?.isAdmin == true => (
        AppSection.admin,
        FeedbackTicketScreen(
          controller: controller,
          ticketId: target.id,
          admin: true,
        ),
      ),
      _ => (null, null),
    };
    if (section == null || page == null) return;
    if (target.attendance != null && target.recipientUid != null) {
      unawaited(_respondToTarget(target));
    }
    // One target at a time: the page opens above its section's start. A
    // page with unsaved input stays below the target instead.
    final context = navigator.currentContext!;
    final state = navigator.currentState!;
    selectSection(context, section);
    if (!hasUnsavedChanges(state)) state.popUntil((route) => route.isFirst);
    openPage(context, page);
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
      message = userMessage(error);
    }
    if (isMounted()) {
      messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
