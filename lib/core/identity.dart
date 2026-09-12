import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../data/api_client.dart';

abstract class IdentityService {
  Future<void> initialize();
  String? get uid;
  String? get email;
  bool get emailVerified;
  List<String> get linkedProviders;
  Future<String> token(String expectedUid);
  Future<void> signIn(String email, String password);
  Future<void> register(String name, String email, String password);
  Future<void> social(String provider, {bool link = false});
  Future<void> verifyEmail();
  Future<void> reload();
  Future<void> resetPassword(String email);
  Future<void> changePassword(String oldPassword, String nextPassword);
  Future<void> unlink(String provider);
  Future<void> addPassword(String password);
  Future<void> signOut();
}

abstract final class FirebaseConfiguration {
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const emulator = bool.fromEnvironment('USE_FIREBASE_EMULATORS');
  static const emulatorHost = String.fromEnvironment(
    'FIREBASE_AUTH_EMULATOR_HOST',
    defaultValue: '127.0.0.1',
  );
  static const providers = String.fromEnvironment(
    'AUTH_PROVIDERS',
    defaultValue: 'password,google.com',
  );
  static const vapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY');
  static FirebaseOptions get options => const FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
    appId: String.fromEnvironment('FIREBASE_APP_ID'),
    messagingSenderId: String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID'),
    projectId: projectId,
    authDomain: String.fromEnvironment('FIREBASE_AUTH_DOMAIN'),
    iosBundleId: 'de.kolpingtheater.ramsen.theaterapp',
    iosClientId: String.fromEnvironment('GOOGLE_IOS_CLIENT_ID'),
  );
  static Future<void> initialize() async {
    if (projectId.isEmpty || options.apiKey.isEmpty || options.appId.isEmpty) {
      throw const ApiException(
        'Die Firebase-Konfiguration fehlt. Bitte die App mit einer eingerichteten Build-Konfiguration starten.',
      );
    }
    if (kReleaseMode && emulator) {
      throw const ApiException(
        'Ein Release darf keine lokale Testanmeldung verwenden.',
      );
    }
    if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: options);
  }
}

class FirebaseIdentity implements IdentityService {
  bool _initialized = false, _googleInitialized = false;
  FirebaseAuth get _auth => FirebaseAuth.instance;
  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await FirebaseConfiguration.initialize();
    if (FirebaseConfiguration.emulator) {
      await _auth.useAuthEmulator(
        FirebaseConfiguration.emulatorHost,
        const int.fromEnvironment(
          'FIREBASE_AUTH_EMULATOR_PORT',
          defaultValue: 9099,
        ),
      );
    }
    await _auth.authStateChanges().first;
    _initialized = true;
  }

  @override
  String? get uid => _initialized ? _auth.currentUser?.uid : null;
  @override
  String? get email => _initialized ? _auth.currentUser?.email : null;
  @override
  bool get emailVerified =>
      _initialized && _auth.currentUser?.emailVerified == true;
  @override
  List<String> get linkedProviders => _initialized
      ? _auth.currentUser?.providerData.map((p) => p.providerId).toList() ?? []
      : [];
  @override
  Future<String> token(String expectedUid) async {
    final user = _auth.currentUser;
    if (user == null || user.uid != expectedUid) {
      throw const ApiException('Bitte erneut anmelden.', statusCode: 401);
    }
    final result = await user.getIdToken();
    if (_auth.currentUser?.uid != expectedUid || result == null) {
      throw const ApiException(
        'Die Anmeldung hat sich geändert.',
        statusCode: 401,
      );
    }
    return result;
  }

  @override
  Future<void> signIn(String email, String password) async =>
      _auth.signInWithEmailAndPassword(email: email.trim(), password: password);
  @override
  Future<void> register(String name, String email, String password) async {
    final result = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await result.user!.updateDisplayName(name.trim());
    await result.user!.sendEmailVerification();
    await reload();
  }

  Future<AuthCredential> _googleCredential() async {
    if (!_googleInitialized) {
      const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
      const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
      await GoogleSignIn.instance.initialize(
        serverClientId: webClientId.isEmpty ? null : webClientId,
        clientId: iosClientId.isEmpty ? null : iosClientId,
      );
      _googleInitialized = true;
    }
    final account = await GoogleSignIn.instance.authenticate();
    return GoogleAuthProvider.credential(
      idToken: account.authentication.idToken,
    );
  }

  @override
  Future<void> social(String provider, {bool link = false}) async {
    if (!FirebaseConfiguration.providers.split(',').contains(provider)) {
      throw const ApiException('Diese Anmeldeart ist noch nicht eingerichtet.');
    }
    if (provider == 'google.com' && !kIsWeb) {
      final credential = await _googleCredential();
      if (link) {
        await _auth.currentUser!.linkWithCredential(credential);
      } else {
        await _auth.signInWithCredential(credential);
      }
    } else {
      final AuthProvider authProvider = switch (provider) {
        'google.com' =>
          GoogleAuthProvider()
            ..setCustomParameters({'prompt': 'select_account'}),
        'apple.com' =>
          AppleAuthProvider()
            ..addScope('email')
            ..addScope('name'),
        'microsoft.com' => MicrosoftAuthProvider(),
        'facebook.com' => FacebookAuthProvider(),
        'github.com' => GithubAuthProvider(),
        'twitter.com' => TwitterAuthProvider(),
        'yahoo.com' => YahooAuthProvider(),
        _ => throw const ApiException('Diese Anmeldeart ist nicht verfügbar.'),
      };
      if (link) {
        if (kIsWeb) {
          await _auth.currentUser!.linkWithPopup(authProvider);
        } else {
          await _auth.currentUser!.linkWithProvider(authProvider);
        }
      } else {
        if (kIsWeb) {
          await _auth.signInWithPopup(authProvider);
        } else {
          await _auth.signInWithProvider(authProvider);
        }
      }
    }
    await reload();
  }

  @override
  Future<void> verifyEmail() async =>
      _auth.currentUser?.sendEmailVerification();
  @override
  Future<void> reload() async {
    await _auth.currentUser?.reload();
    await _auth.currentUser?.getIdToken(true);
  }

  @override
  Future<void> resetPassword(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());
  @override
  Future<void> changePassword(String oldPassword, String nextPassword) async {
    final user = _auth.currentUser!;
    await user.reauthenticateWithCredential(
      EmailAuthProvider.credential(email: user.email!, password: oldPassword),
    );
    await user.updatePassword(nextPassword);
  }

  @override
  Future<void> addPassword(String password) async {
    final user = _auth.currentUser!;
    if (password.length < 12 || user.email == null) {
      throw const ApiException(
        'Bitte ein Passwort mit mindestens 12 Zeichen eingeben.',
      );
    }
    await user.linkWithCredential(
      EmailAuthProvider.credential(email: user.email!, password: password),
    );
    await reload();
  }

  @override
  Future<void> unlink(String provider) async {
    if (linkedProviders.length < 2) {
      throw const ApiException(
        'Mindestens eine Anmeldeart muss erhalten bleiben.',
      );
    }
    await _auth.currentUser!.unlink(provider);
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    if (_googleInitialized) await GoogleSignIn.instance.signOut();
  }
}

String identityError(Object error) {
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'invalid-email' => 'Bitte eine gültige E-Mail-Adresse eingeben.',
      'weak-password' => 'Bitte ein längeres Passwort wählen.',
      'email-already-in-use' =>
        'Für diese E-Mail-Adresse gibt es bereits ein Konto. Bitte anmelden.',
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' => 'E-Mail-Adresse oder Passwort stimmen nicht.',
      'popup-closed-by-user' ||
      'web-context-canceled' => 'Anmeldung abgebrochen.',
      'popup-blocked' => 'Bitte das Anmeldefenster im Browser erlauben.',
      'account-exists-with-different-credential' ||
      'credential-already-in-use' =>
        'Diese Anmeldeart gehört bereits zu einem Konto. Bitte zuerst mit der bisherigen Anmeldeart anmelden.',
      'requires-recent-login' =>
        'Bitte erneut anmelden und die Änderung wiederholen.',
      'operation-not-allowed' =>
        'Diese Anmeldeart ist noch nicht freigeschaltet.',
      'too-many-requests' => 'Bitte kurz warten und dann erneut versuchen.',
      'network-request-failed' => 'Keine Verbindung zum Anmeldedienst.',
      'user-disabled' => 'Dieses Konto wurde gesperrt.',
      _ => 'Die Anmeldung konnte nicht abgeschlossen werden (${error.code}).',
    };
  }
  return error is ApiException
      ? error.message
      : 'Der Vorgang konnte nicht abgeschlossen werden. Bitte erneut versuchen.';
}
