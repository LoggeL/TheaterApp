/// Build-time display names are independent from store identifiers.
abstract final class Brand {
  static const name = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'Theater-App',
  );
  static const subtitle = String.fromEnvironment(
    'APP_SUBTITLE',
    defaultValue: 'Die App des Kolpingtheaters Ramsen',
  );
  static const organization = 'Kolpingtheater Ramsen';
  static const apiUrl = String.fromEnvironment('API_BASE_URL');
  static const pushEnabled = bool.fromEnvironment(
    'PUSH_ENABLED',
    defaultValue: false,
  );
}
