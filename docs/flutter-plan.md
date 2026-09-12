# Flutter-Umsetzung

Die vorhandene Flutter-App ist die technische Ausgangsbasis. Die UI-Entwürfe ersetzen weder den Backend-Abgleich noch die Prüfung auf Android und iOS.

## Client und Betrieb

Android und iOS erhalten native Flutter-Widgets. Für Tablets werden Navigation und Leser je nach verfügbarer Breite neu angeordnet; die Handyansicht wird nicht einfach vergrößert. Dieser Ansatz entspricht Flutters Unterscheidung zwischen anpassbarer Anordnung und einer für das Gerät passenden Bedienung. [Flutter: Adaptive and responsive design](https://docs.flutter.dev/ui/adaptive-responsive)

Firebase Auth übernimmt Registrierung und Anmeldung. Der vorhandene Probenserver bleibt zunächst die Heimat für Personen, Kontozuordnungen, Freigaben, Rechte und Termine; der Skript-Import bleibt bestehen. Der Backend-Overlay aus dem ZIP ist eine Prüfgrundlage. Er darf erst nach Abgleich mit dem aktuellen Backend übernommen werden. Eine PostgreSQL-Umstellung ist laut Paket vorbereitet, aber nicht durchgeführt; sie ist ein eigenes Migrationsvorhaben.

## Firebase Auth und Mitgliedsfreigabe

Der Flutter-Client verwendet `firebase_auth` für E-Mail/Passwort und die eingerichteten Social Logins. Eine zentrale Zugangskontrolle unterscheidet abgemeldet, E-Mail-Bestätigung nötig, Freigabe ausstehend, freigegeben und gesperrt/abgelehnt. Erst nach bestätigter Freigabe werden interne Repositories geladen. Die Kontoverwaltung kann weitere Anbieter mit derselben Firebase UID verknüpfen. [Firebase: Flutter Auth](https://firebase.google.com/docs/auth/flutter/start), [Firebase: Account linking](https://firebase.google.com/docs/auth/flutter/account-linking)

Der Server prüft Firebase-ID-Tokens mit dem Admin SDK und prüft anschließend die aktuelle Personenzuordnung, Freigabe und Berechtigung in der Anwendungsdatenbank. Die bestehende Mobile-Anmeldung und gegebenenfalls alte Web-Sitzungen dürfen diese Prüfung nicht umgehen. Firebase Messaging im Referenzpaket deckt diesen Ablauf noch nicht ab. Datenmodell, Admin-Ablauf und Migration sind in [Anmeldung und Freigabe](auth-and-approval.md) beschrieben.

## Module für den Leser

Das Sample bündelt große Teile des Lesers in `lib/ui/reader.dart`. Für die Überarbeitung bieten sich folgende Zuständigkeiten an:

| Modul | Verantwortung |
| --- | --- |
| `script_repository` | Fassungen, kanonische Textstellen, Download und Cache |
| `reader_preferences` | Mehrfachrollen, Kategorie-Kontext, Schrift und Farbschema pro Produktion |
| `reader_projection` | Sichtbare Zeilen und Navigation, ohne Originaldaten zu verändern |
| `practice_controller` | Eigene Texte verdecken/aufdecken; Lernzustand getrennt vom Dokument |
| `annotation_repository` | Private Notizen, Lesezeichen und ungelöste Zuordnungen nach Updates |
| `focus_session` | Regierechte, Marker, Verbindung, Folgen, Sequenz und Revision |
| `reader_widgets` | Kopfleiste, Szenenauswahl, Dialogzeilen und kompakte Hinweiszeilen |
| `stage_view` | Tablet-/Monitoransicht für aktuelle und kommende Einsätze |

Das ist ein Vorschlag für die nächste Implementierung, keine bereits angelegte Modulstruktur.

Lokale und entfernte Datenzugriffe sollten hinter den jeweiligen Repositories liegen. Widgets lesen einen gemeinsamen Zustand und melden Aktionen zurück. Flutters Offline-Leitfaden beschreibt Repositories als gemeinsamen Zugriffspunkt für Cache und API; die konkrete Konfliktregel bleibt Sache der App. [Flutter: Offline-first support](https://docs.flutter.dev/app-architecture/design-patterns/offline-first)

## UI-Vertrag

- App-Navigation zunächst wie im Sample: Heute, Termine, Drehbücher, Mein Bereich. Mitteilungen sind über Heute und das Postfach erreichbar; Verwaltung erscheint nur bei passender Berechtigung.
- Vor Freigabe: Registrierung, gegebenenfalls E-Mail-Bestätigung und Wartestatus. Die Admin-Verwaltung erhält eine Liste neuer Konten und die gemeinsame Aktion „Verknüpfen & freigeben“.
- Im geöffneten Leser tritt die globale Navigation zurück. Szenen, vorige/nächste eigene Textstelle und Lesezeichen stehen in einer eigenen Fußleiste.
- Oben stehen Produktion und eine kompakte Auswahl für Szene, eigene Rollen und aktuellen Modus. Lesen, Lernen und Technik sind über die Modusauswahl erreichbar. Eine zusätzliche dauerhaft sichtbare Segmentleiste entfällt im minimalistischen Leser.
- „Lernen“ verdeckt eigene Texte. „Eigene Texte“ filtert auf eigene Einsätze mit Kontext. Beide Funktionen haben unterschiedliche Zustände.
- Regie-Fokus erhält einen eigenen Rahmen/Marker. Eigene Rollen erkennt man am Rollennamen und einem schmalen Randstrich. Große Flächen und wiederholte „Dein Text“-Beschriftungen entfallen. Beide Zustände bleiben bei derselben Zeile unterscheidbar.
- Anweisungen stehen im Standardleser als schlichte kursive Zeilen im Textfluss. Kategorienamen wie „ANWEISUNG“ oder „LICHT“ stehen dort nicht vor jeder Zeile. Die Technikansicht kann Volltext und beschriftete Cues als Kontext zeigen.
- Notizen, Kommentarzugriff und Lesezeichen bleiben verfügbar. Vorhandene Anmerkungen bekommen ein dezentes Symbol an der Textstelle; der Bookmark-Button unten rechts benötigt keinen eigenen großen Rahmen.
- Die Mitgliedsrückmeldung unterscheidet dabei, komme später, abgesagt und offen. „Komme später“ kann eine Ankunftszeit tragen. Tatsächliche Anwesenheit wird für den konkreten Termin gesondert als da, fehlt oder nicht erfasst gespeichert. Änderungen einzelner Mitglieder dürfen nicht versehentlich unbekannte oder gleichzeitig bearbeitete Einträge überschreiben.
- Auf Tablets: Szenen links, Drehbuch in der Mitte, passende Technik-/Probeninformation rechts. Bei großer Schrift oder wenig Breite wechselt die Ansicht in weniger Spalten.
- Größen und Abstände müssen mit realen Widgets geprüft werden. Zielwerte: mindestens 48 logische Pixel große interaktive Flächen, skalierbarer Text, lesbarer Kontrast und kein rein farblicher Status.

## Reihenfolge

1. Entwürfe in echte Flutter-Ansichten mit fiktiven Daten übertragen und auf Handy/Tablet ansehen.
2. Firebase Auth, Selbstregistrierung, Kontoverknüpfung und Admin-Freigabe integrieren. Geschützte Datenzugriffe und die Migration bestehender Konten vor Anbindung produktiver Daten prüfen.
3. Rollen-Gruppen, Lernmodus, Notizen, Kategorie-Filter und eigene Einsatznavigation ergänzen. Bestehende Reader-Tests um diese Verhaltensfälle erweitern.
4. Aktuellen Skript-Import abgleichen. Kanonische IDs aus dem ZIP nicht ohne Prüfung auf den aktuellen Skriptstand übertragen. Für dauerhafte Notizen möglichst Quell-IDs einführen; unklare Migrationen sichtbar belassen.
5. Probe, Besetzung und Check-ins zu berechneten Szenenvorschlägen verbinden. Rückmeldungen zu festen Terminen erhalten „Komme später“ mit optionaler Ankunftszeit.
6. Gemeinsame Regiesitzung, Mitteilungen, Push und mobile Verwaltungsabläufe integrieren.
7. Reale Android-/iOS-Geräte und Mehrgeräte-Regie abnehmen, danach Release und Betrieb vorbereiten.

## Technische Grenzen des aktuellen Pakets

Der App-Fokus und der bestehende Browser-Fokus sind laut Paket noch getrennte Transporte. Ein funktionierendes App-Backend bedeutet daher nicht, dass der bisherige Bühnenmonitor bereits folgt. Ebenso sind ein gebautes APK, vorhandener Push-Code und ein SQL-Zielschema jeweils nur Teilnachweise. Das neue Design darf diese offenen Integrationen nicht als bereits produktiv darstellen.

## Datenvertrag für Späterkommen

Die neue Anforderung ist bislang als Design und Funktionsvertrag ergänzt. Die Referenz-App akzeptiert in `AppController.respond` nur `yes`, `no` und `open`. Ein zusätzlicher Button allein reicht daher für die Umsetzung nicht. Terminabstimmungen gehören nicht zum Zielumfang.

Vorgeschlagener Vertrag:

- Probenrückmeldung ergänzt `late` und eine optionale `expectedArrivalAt`. Die Zeit gehört zu Datum und Zeitzone des konkreten Termins. Sie wird zusammen mit Status und Versionsstand übertragen und gespeichert.
- Bei `yes`, `no` und `open` ist die Ankunftszeit leer. Bei `late` ist sie entweder unbekannt oder liegt nach Beginn und vor Ende des festgelegten Termins. Eine Änderung von Terminzeiten erfordert eine erneute Prüfung bestehender Ankunftsangaben.
- Anzeige ohne Zeit: „Später · Uhrzeit offen“. Eine fehlende Uhrzeit wird nicht durch die Startzeit ersetzt.
- Rückmeldesummen zählen `yes`, `late`, `no` und `open` getrennt. Eine zusätzliche Gesamtzahl der erwarteten Teilnehmer kann `yes + late` ausweisen, muss dann entsprechend beschriftet sein.
- Check-ins bleiben unabhängig. Für Szenenvorschläge anhand von Zusagen wird die erwartete Ankunft berücksichtigt; die Anwesenheitsansicht verwendet tatsächlich erfasste Check-ins.
- API-Validierung, Cache, Offline-Warteschlange, Konfliktbehandlung, Demo-Daten und Testfälle müssen denselben Vertrag unterstützen. Alte Clients dürfen `late` nicht als volle Zusage interpretieren.
