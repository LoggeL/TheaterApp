# Abnahmestand

Stand: 12. September 2026. Produktname: Theater-App. Flutter 3.44.6 / Dart 3.12.2, Node 24.18.0. Terminabstimmungen sind ausgeschlossen.

## Bereitgestellt

Die Flutter-Web-App und der SQLite-Backenddienst laufen auf dem vorhandenen Dokploy-Server unter https://theater-app.logge.top. Firebase-Projekt `theater-app-6fa5d` ist mit E-Mail/Passwort, Google und FCM eingerichtet. Die eigene Serveridentität liegt als private Datei außerhalb von Git. Der Admin `hyper.xjo@gmail.com` ist mit `Logge Louis` verknüpft. Seine Google-Anmeldung auf der laufenden Instanz wurde erfolgreich abgeschlossen.

Die beiden Sommerstücke 2025 und 2026 sind aus dem aktuellen Skriptdienst importiert: 24 Szenen / 1351 Cues und 28 Szenen / 1612 Cues. Eine als „Testprobe“ bezeichnete Probe dient zum Ausprobieren. Weitere Personen und verbindliche Besetzungen sind noch von der Theaterleitung zu pflegen. Bestehende Probenplan-Daten wurden nicht automatisch migriert.

## Ausgeführte Prüfungen

| Bereich | Ergebnis und Grenze |
| --- | --- |
| Flutter-Analyse | Ohne Befund |
| Flutter-Tests | 36 Tests bestanden, einschließlich 390-Pixel-Layout, Leser, Kontowechsel, Offline-Warteschlange und tatsächlicher Anwesenheit |
| Backend | 18 Tests bestanden: Rechte, Freigabe, Versionskonflikte, Idempotenz, Späterkommen, Push-Wiederholung und Regiebrücke |
| Android mit Firebase-Emulator | Durchgängiger Gerätetest bestanden: E-Mail-Anmeldung, Später-Zusage, Server-Read-back, Drehbuch, Abmeldung und Wartestatus eines anderen Kontos |
| Echtes Firebase / öffentlicher Server | Unbestätigte und wartende Konten erhalten HTTP 403 für interne Daten. Manuelle Personenzuordnung und Freigabe ermöglichen Zugriff. Späterkommen mit Uhrzeit, Empfängerbeschränkung, Lesebestätigung und anschließende Sperrung geprüft |
| Google im Browser | Eigener Admin erfolgreich angemeldet. Live-Startseite, Einstellungen, Verwaltung und Besetzungseditor geöffnet |
| Android-Push | Echter FCM-Versand an ein temporäres Gerätetestkonto und Empfang mit dem nativen Firebase-SDK bestätigt. Testkonto und Gerätetoken anschließend entfernt |
| Web-Push | Service Worker und VAPID konfiguriert. Test in Brave endet mit „Registration failed - push service error“. Web-Push daher nicht als zugestellt abgenommen |
| Skript-Regie | Bidirektionaler Live-Test in einem isolierten Raum des vorhandenen Skriptdienstes bestanden: App-Marker erreicht zweiten Socket-Teilnehmer; Marker und Löschen in Gegenrichtung erreichen App. Keine bestehende Produktion wurde dabei umgeschaltet |
| Web-Release | Produktionsbuild erstellt und auf Dokploy gestartet. Öffentlicher Healthcheck liefert den gebauten Release-Hash; geschützter Snapshot ohne Token HTTP 401 |
| Android-Release | Signierte APK und AAB erfolgreich gebaut. Debug- und Release-Signatur in Firebase registriert |
| Laufzeitabhängigkeiten | `npm audit --omit=dev`: keine bekannten Befunde. Ein gezieltes uuid-Override behebt die transitive gaxios-Abhängigkeit |
| Datensicherung | Konsistentes SQLite-Backup über die Backup-API geladen und mit `PRAGMA integrity_check` geprüft |

Die lokalen Prüfprotokolle liegen unter `artifacts/` und werden nicht in Git übertragen. Die CI führt Analyse, Flutter- und Servertests sowie den Webbuild erneut auf dem gepushten Stand aus.

## Verbleibende Grenzen

- Für iOS fehlen auf diesem Rechner Xcode und CocoaPods. Firebase-iOS-Konfiguration, URL-Scheme und Push-Entitlements sind vorbereitet. Apple-Team, Signierung und APNs-Schlüssel müssen noch eingerichtet und auf einem iPhone geprüft werden.
- Apple, Microsoft, GitHub und Facebook sind im Client unterstützt, aber ohne deren OAuth-/Apple-Konfiguration nicht aktiv. Sichtbar sind derzeit E-Mail/Passwort und Google.
- Die echte Push-Abnahme belegt Android-Empfang im Vordergrund. Hintergrunddarstellung, Benachrichtigungsklick bei vollständig geschlossener App und iOS-Push sind separat auf den gewünschten Geräten zu prüfen.
- Der Offline-Cache und die Wiederholungslogik sind automatisiert geprüft. Ein längerer realer Flugmodus-Durchlauf auf Handy und Tablet sowie eine native PDF-/Kalenderübergabe sind noch keine Geräteabnahme.
- Git-Push und Dokploy-Deployment sind getrennt. `tool/deploy.py` aktualisiert den Server nach erfolgreichem lokalem Build. Google Play und App Store wurden nicht veröffentlicht.
- Requisiten, Kostüme, Aufgaben, Kasse und Ticketverkauf sind im Anforderungsdokument als mögliche Fortsetzung beschrieben und gehören nicht zu den bereits konkret implementierten Screens.

Weitere Bedien- und Betriebsschritte stehen in [operations.md](operations.md). Die historische Anforderungsmatrix in [requirements.md](requirements.md) dokumentiert die Ausgangssichtung; dieser Abnahmestand beschreibt die tatsächliche Umsetzung.
