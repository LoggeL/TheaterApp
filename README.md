# Theater-App

Flutter-App für das Kolpingtheater Ramsen. Web und Android verwenden denselben Server und Firebase Auth. Die Web-App läuft unter [app.kolpingtheater-ramsen.de](https://app.kolpingtheater-ramsen.de). [theater-app.logge.top](https://theater-app.logge.top) leitet Web-Aufrufe dauerhaft auf diese Adresse weiter; die bisherige API bleibt für bestehende Installationen erreichbar.

## Funktionen

- Selbstregistrierung mit E-Mail/Passwort und Google; manuelle Personenzuordnung und Freigabe durch einen Admin. Vorher fragt die App einmal pro Gerät eine einfache Botschutz-Frage (siehe [docs/operations.md](docs/operations.md#botschutz-vor-der-anmeldung)).
- Feste Termine mit Beschreibung und zwölf Terminarten für Rollen, das Ensemble eines Stücks (Besetzung, Regie und weitere Mitwirkende) und/oder einzelne Personen, dabei/später/abgesagt, optionale Ankunftszeit und längere Abwesenheiten (meldbar im Reiter „Termine“, über „Länger weg?“ beim Absagen und unter „Mein Bereich“); beim Anlegen oder Ändern kann die Leitung die Eingeladenen direkt per Push benachrichtigen. Serientermine (wöchentlich, alle 2 Wochen, monatlich bis zu einem Enddatum) mit einer einzigen Benachrichtigung; Löschen einzeln oder ab einem Termin. Optional „Alle gelten als zugesagt“: Eingeladene sagen nur ab und erhalten zwei Tage vorher eine Erinnerung „Du bist eingeplant“ mit Absage-Möglichkeit (unter Android direkt mit „Ok“ oder „Komme nicht“; abschaltbar als „Eingeplant-Erinnerung“); wer nicht absagt, bekommt auch die gewohnten Termin-Erinnerungen und Änderungen. Die Übersicht zeigt „N dabei, davon M automatisch“. Keine Terminabstimmungen.
- Serien als Ganzes: Beim Bearbeiten eines Serientermins wählt die Terminleitung „Nur dieser Termin“ oder „Ganze Serie“; die ganze Serie übernimmt geänderte Angaben und Uhrzeiten für alle noch nicht begonnenen Termine (vergangene bleiben unverändert) und lässt sich über „Wiederholen bis“ im gleichen Rhythmus verlängern oder früher beenden.
- Terminfinder als Slot-Buchung, z. B. für Fototermine: Zeitfenster mit Platzzahl, Einladung von Rollen und/oder Personen, je Person ein Fenster; belegte Fenster werden automatisch Termine. Erreichbar über den Reiter „Termine“ (Hinweis, solange eine Wahl aussteht, und Menü), „Heute“ und die Admin-Übersicht.
- Frei verwaltbare Mehrfachrollen pro Person und allgemeine Abstimmungen mit Frist, Stimmwechsel und Ergebnisübersicht; Abstimmungen liegen im Reiter „Mitteilungen“.
- Verwaltung von Ensemble, Konten, Terminen, Produktionen und Besetzungen; tatsächliche Anwesenheit und spielbare Szenen.
- Recht „Termine verwalten“: Admins können einzelnen Konten erlauben, alle Termine, Serien, Rückmeldungen, Anwesenheit und Terminfinder zu verwalten – ohne Zugriff auf Konten, Mitteilungen, Abstimmungen oder Produktionen. Einstieg über den Reiter „Termine“ (Schaltfläche „Termin anlegen“ und Menü „Termine verwalten“); sie erhalten auch die Meldungen zu kurzfristigen Absagen. Wer einen Termin zuletzt geändert hat, steht für alle mit diesem Recht unter „Probenleitung“.
- Admin-Seite „Personen & Zugänge“: oben die Registrierungen, die auf Zuordnung warten, darunter alle aktiven Personen mit Foto, Rollen, Status (freigegeben, unbestätigt, gesperrt, abgelehnt, ohne Konto, Konto ohne Person, Person inaktiv) und Rechten (Admin, Termine verwalten, Regie), am Ende eingeklappt die nicht aktiven Personen; Filter nach Status, Rechten und Rollen, Suche und „Person anlegen“. Ein Tipp auf eine Person öffnet den Personeneditor mit dem ganzen App-Zugang: Status, Login (E-Mail, Anbieter, Bestätigung, letzte Aktivität), „Rechte bearbeiten…“ (nur mit Verbindung), Sperren, Wieder freigeben, Konto löschen oder „Konto verknüpfen“. Die Drehbuchrollen mit ihrer Besetzung liegen unter „Produktionen & Besetzung“.
- Minimalistischer Leser mit mehreren eigenen Rollen, Lernmodus, Kategorien, Suche, privaten Notizen, Kommentaren, Lesezeichen und PDF-Export.
- Drehbuchimport aus dem bestehenden Skriptdienst, gemeinsame Regiemarkierungen zwischen Flutter-Web, mobilen Apps und dem bestehenden Skript-Browser.
- Eigener Reiter „Mitteilungen“ mit den Bereichen Mitteilungen und Abstimmungen, Ungelesen-Filter, optionalem Link, Lesestatus und Push-Erinnerung an Ungelesene für die Theaterleitung; eigene Pushes auf Abruf an alle, Rollen, Stück-Ensembles oder einzelne Personen.
- Formulare direkt in der App erstellen, speichern und beim Schreiben einer Mitteilung auswählen: Text, längere Antworten, Datum, Auswahl und Bestätigungsfelder, bei Bedarf mit gezeichneter Unterschrift. Eingeladene geben ihre Angaben online ab; nur sie selbst und Admins sehen die Antworten. Abgaben können gelöscht und danach neu abgegeben werden, solange das Formular offen ist. Der bearbeitbare Startentwurf „Probenfreizeit“ enthält auch freiwillige Angaben zu Allergien und Medikamenten mit gesonderter Einwilligung sowie ein festzulegendes Löschdatum. Änderungen an einer Vorlage verändern bereits verschickte Formulare und Abgaben nicht. PDF-Export für leere Formulare, Entwürfe und abgegebene Bestätigungen; Details unter [Formulare](docs/operations.md#formulare-in-mitteilungen).
- Firebase-Push mit Berechtigungsabfrage beim Öffnen, Erinnerungseinstellungen mit eigener Vorlaufzeit und passenden Links.
- Teilnahmeübersicht der letzten sechs Monate: Mitglieder sehen ihre eigenen Zahlen, Admins alle aktiven Personen; keine Rangliste, Absagen zählen nicht negativ, automatische Zusagen zählen als Zusage.
- Tägliche automatische Löschung nicht mehr benötigter Daten (Fristen in `server/src/retention.mjs` und der Datenschutzerklärung) und Löschen von Anmeldekonten durch Admins.
- Profilbilder und Galerien mit Immich-Titelbildern, eigenem Bildupload, Lightbox und Download.
- Ensemble-Profile unter „Unser Ensemble“: Foto, „Über mich“-Text, aktuelle und bisherige Rollen sowie Aufgaben hinter den Kulissen; ergänzt um die öffentlichen Angaben der Teamseite kolpingtheater-ramsen.de (Abgleich per `server/scripts/import-website-team.mjs`, siehe [Betrieb](docs/operations.md)).
- Fünf Reiter auf dem Telefon (Heute, Termine, Drehbücher, Mitteilungen, Mein Bereich); Admins öffnen die Verwaltung über die Schaltfläche „Admin“ in der Kopfleiste (nur Admins, auch mit dem Recht „Termine verwalten“ bleibt sie verborgen). Ab 900 px Breite eine Seitenleiste mit Admin-Eintrag, die auch auf Unterseiten sichtbar bleibt; Kalender mit Termintiteln.
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
flutter build web --release --wasm --dart-define-from-file=config/production.web.json --pwa-strategy=none
node tool/version-web.mjs
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

Der [Google-Play-Workflow](docs/google-play-ci.md) baut nach erfolgreichen Prüfungen auf `main` ein signiertes Android-Bundle und reicht es im geschlossenen Testkanal `alpha` zur Veröffentlichung ein. Die Einrichtung benötigt die dort beschriebenen GitHub-Secrets und Play-Console-Rechte.

## Design und Quellen

Die [Bildentwürfe](docs/design/README.md) dokumentieren die Designentwicklung. Historische Bilder können den früheren Sample-Namen enthalten. Der aktuelle Produktname ist Theater-App. Der Originaldownload liegt nur lokal unter `reference/` und wird nicht mit Git übertragen. Quellnachweise und Lizenzen stehen in `docs/source-evidence.json`, `server/src/script-engine/LICENSE.Skript` und `assets/fonts/LICENSE-DejaVu.txt`.
