import 'package:flutter/material.dart';

const providerNames = {
  'google.com': 'Google',
  'apple.com': 'Apple',
  'microsoft.com': 'Microsoft',
  'facebook.com': 'Facebook',
  'github.com': 'GitHub',
  'twitter.com': 'X',
  'yahoo.com': 'Yahoo',
  'password': 'E-Mail & Passwort',
  'custom': 'Passkey',
};

IconData providerIcon(String provider) => switch (provider) {
  'custom' => Icons.key_outlined,
  'google.com' => Icons.g_mobiledata,
  'apple.com' => Icons.apple,
  'microsoft.com' => Icons.window,
  'facebook.com' => Icons.facebook,
  _ => Icons.login,
};
