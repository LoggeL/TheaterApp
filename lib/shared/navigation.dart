import 'package:flutter/material.dart';

/// Opens [screen] as a new page on top of the current route.
///
/// [fullscreen] marks experiences such as the image lightbox that cover the
/// whole window. It has no effect yet.
Future<T?> openPage<T>(
  BuildContext context,
  Widget screen, {
  bool fullscreen = false,
}) => Navigator.push<T>(context, MaterialPageRoute<T>(builder: (_) => screen));
