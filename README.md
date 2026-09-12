# Theater-App

Flutter-App für das Kolpingtheater Ramsen. Web und Android verwenden denselben Server und Firebase Auth. Die laufende Testinstanz ist [theater-app.logge.top](https://theater-app.logge.top).

## Funktionen

- Selbstregistrierung mit E-Mail/Passwort und Google; manuelle Personenzuordnung und Freigabe durch einen Admin.
- Feste Termine, dabei/später/abgesagt, optionale Ankunftszeit und längere Abwesenheiten. Keine Terminabstimmungen.
- Verwaltung von Ensemble, Konten, Terminen, Produktionen und Besetzungen; tatsächliche Anwesenheit und spielbare Szenen.
- Minimalistischer Leser mit mehreren eigenen Rollen, Lernmodus, Kategorien, Suche, privaten Notizen, Kommentaren, Lesezeichen und PDF-Export.
- Drehbuchimport aus dem bestehenden Skriptdienst, gemeinsame Regiemarkierungen zwischen Flutter-Web, mobilen Apps und dem bestehenden Skript-Browser.
- Mitteilungen und Firebase-Push mit Erinnerungseinstellungen und passenden Links.
- Lokaler Cache und sichtbare Warteschlange für Rückmeldungen bei fehlender Verbindung.

Der [Abnahmestand](docs/implementation-status.md) unterscheidet implementierte, getestete und noch extern einzurichtende Funktionen.

## Lokal starten

Benötigt: Flutter 3.44.6, Node 24, Java 21 für den Firebase-Emulator.

```sh
flutter pub get
cd server
npm ci
npm run emulators
```

In einem zweiten Terminal:

```sh
cd server
FIREBASE_PROJECT_ID=demo-theater-app FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 DATABASE_PATH=./data/local-theater.sqlite node scripts/dev-seed.mjs
FIREBASE_PROJECT_ID=demo-theater-app FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 DATABASE_PATH=./data/local-theater.sqlite SCRIPT_SERVICE_URL=https://skript.logge.top/ npm start
```

Anschließend im Projektstamm:

```sh
node tool/configure.mjs config/local.json
flutter run -d chrome --web-hostname localhost --web-port 8080 --dart-define-from-file=config/local.json
```

Lokale, fiktive Testkonten: `admin@theater.test` (Admin), `sam@theater.test` (wartet auf Freigabe), `neu@theater.test` (unbestätigt). Passwort jeweils `TheaterProbe!2026`. Diese Konten existieren nur im Emulator. Für Webtests `localhost` verwenden.

## Prüfen und bauen

```sh
flutter analyze
flutter test
npm --prefix server test
node tool/configure.mjs config/production.web.json
flutter build web --release --dart-define-from-file=config/production.web.json
flutter build apk --release --dart-define-from-file=config/production.android.json
flutter build appbundle --release --dart-define-from-file=config/production.android.json
```

Flutter-Befehle nacheinander ausführen: gleichzeitige Test-/Release-Builds können die generierte Android-Pluginregistrierung überschreiben.

Für den nativen Integrationstest einen Android-Emulator starten, Backend und Firebase-Emulator wie oben starten und ausführen:

```sh
adb reverse tcp:8787 tcp:8787
adb reverse tcp:9099 tcp:9099
flutter test integration_test/app_flow_test.dart -d emulator-5554 --dart-define-from-file=config/local.json
```

Die tatsächliche Geräte-ID steht in `flutter devices`.

## Konfiguration und Betrieb

Öffentliche Firebase-Clientkonfiguration liegt unter `config/`, `android/app/google-services.json` und `ios/Runner/GoogleService-Info.plist`. Diese Identifikatoren sind keine Server-Anmeldeschlüssel. Der Server prüft ID-Token und die eigene Freigabe bei jedem geschützten Zugriff.

Private Server-Credentials und Android-Signierschlüssel liegen ausschließlich unter `.secrets/`; `android/key.properties` verweist auf den lokalen Keystore. Diese Dateien zusätzlich sicher sichern. Ohne denselben Android-Schlüssel lässt sich eine installierte Release-App nicht aktualisieren.

Das [Betriebshandbuch](docs/operations.md) beschreibt Dokploy, Datenbank-Backups, Wiederherstellung, Firebase und weitere Anmeldeanbieter. `python3 tool/deploy.py` baut das Web-Frontend, überträgt einen geprüften Docker-Kontext und aktualisiert ausschließlich den eigenen Dokploy-Dienst. Der Probenplan und der Skriptdienst laufen separat weiter.

## Design und Quellen

Die [Bildentwürfe](docs/design/README.md) dokumentieren die Designentwicklung. Historische Bilder können den früheren Sample-Namen enthalten. Der aktuelle Produktname ist Theater-App. Der Originaldownload liegt nur lokal unter `reference/` und wird nicht mit Git übertragen. Quellnachweise und Lizenzen stehen in `docs/source-evidence.json`, `server/src/script-engine/LICENSE.Skript` und `assets/fonts/LICENSE-DejaVu.txt`.
