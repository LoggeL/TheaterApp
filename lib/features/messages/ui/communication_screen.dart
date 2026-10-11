import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import 'messages_screen.dart';

/// The Mitteilungen tab of the app shell.
class CommunicationScreen extends StatelessWidget {
  const CommunicationScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) =>
      MessagesScreen(controller: controller, embedded: true);
}
