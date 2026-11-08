import 'package:flutter/foundation.dart';
import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

import '../data/api_client.dart';
import 'models.dart';

/// The only platform seam: real OS/browser prompts in production, a fake device
/// in tests. Verification and account selection always happen on the server.
abstract interface class PasskeyDevice {
  Future<bool> supported(JsonMap configuration);
  Future<JsonMap> register(JsonMap options);
  Future<JsonMap> authenticate(JsonMap options);
}

class PlatformPasskeyDevice implements PasskeyDevice {
  final _authenticator = PasskeyAuthenticator();

  @override
  Future<bool> supported(JsonMap configuration) async {
    if (configuration['enabled'] != true) return false;
    try {
      final availability = _authenticator.getAvailability();
      if (kIsWeb) {
        if (!jsonList(configuration['webOrigins']).contains(Uri.base.origin)) {
          return false;
        }
        return (await availability.web()).hasPasskeySupport;
      }
      return switch (defaultTargetPlatform) {
        TargetPlatform.android =>
          configuration['android'] == true &&
              (await availability.android()).hasPasskeySupport,
        TargetPlatform.iOS =>
          configuration['apple'] == true &&
              (await availability.iOS()).hasPasskeySupport,
        _ => false,
      };
    } catch (_) {
      return false;
    }
  }

  Future<JsonMap> _run(Future<JsonMap> Function() action) async {
    try {
      return await action();
    } on PasskeyAuthCancelledException {
      throw const ApiException(
        'Passkey-Anfrage abgebrochen.',
        code: 'passkey_cancelled',
      );
    } on NoCredentialsAvailableException {
      throw const ApiException(
        'Kein passender Passkey gefunden. Melde dich mit Passwort oder Google an und hinterlege unter Anmeldearten einen Passkey.',
      );
    } on ExcludeCredentialsCanNotBeRegisteredException {
      throw const ApiException('Dieser Passkey ist bereits hinterlegt.');
    } on DomainNotAssociatedException {
      throw const ApiException(
        'Diese App ist noch nicht für Passkeys freigeschaltet. Bitte nutze vorerst Passwort oder Google.',
      );
    } on DeviceNotSupportedException {
      throw const ApiException('Dieses Gerät unterstützt Passkeys nicht.');
    } on AuthenticatorException {
      throw const ApiException(
        'Der Passkey konnte nicht verwendet werden. Prüfe deine Gerätesperre und versuche es erneut. Passwort und Google bleiben verfügbar.',
      );
    } catch (_) {
      throw const ApiException(
        'Die Passkey-Anfrage konnte nicht abgeschlossen werden. Bitte erneut versuchen.',
      );
    }
  }

  @override
  Future<JsonMap> register(JsonMap options) => _run(
    () async => (await _authenticator.register(
      RegisterRequestType.fromJson(options),
    )).toJson(),
  );

  @override
  Future<JsonMap> authenticate(JsonMap options) => _run(
    () async => (await _authenticator.authenticate(
      AuthenticateRequestType.fromJson(
        options,
        preferImmediatelyAvailableCredentials: false,
      ),
    )).toJson(),
  );
}
