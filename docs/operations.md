# Betrieb und Zugang

## Laufende Instanz

- App: https://theater-app.logge.top
- Privater Quellcode: https://github.com/LoggeL/TheaterApp
- Dokploy: Projekt `kolping-ramsen`, Umgebung `production`, eigener Dienst `Theater-App`.
- Firebase-Projekt `theater-app-6fa5d`, derzeit Spark. Auth: E-Mail/Passwort und Google. FCM V1 und Web-VAPID sind eingerichtet.
- Web, Android und iOS sind in Firebase registriert. Android-Anwendungs-ID und iOS-Bundle-ID: `de.kolpingtheater.ramsen.theaterapp`.

## Dein Admin-Zugang

`hyper.xjo@gmail.com` ist mit der Person `Logge Louis` verknüpft und als Admin freigegeben. Die Anmeldung mit Google wurde auf der laufenden Instanz erfolgreich abgeschlossen. Die ursprünglich angelegten privaten Startdaten stehen lokal in `.secrets/admin-setup.json`. Nach der Google-Anmeldung ist E-Mail/Passwort gegebenenfalls über „Mein Bereich → Anmeldearten“ hinzuzufügen; ein unbestätigtes Passwortkonto kann durch den vertrauenswürdigen Google-Anbieter ersetzt werden.

Die Testinstanz enthält beide Sommerstücke aus dem bestehenden Skriptdienst sowie einen festen Termin „Testprobe“. Besetzungen und weitere Mitglieder lassen sich unter „Probenleitung“ anlegen. Bestehende Probenplan-Konten wurden nicht automatisch übertragen oder freigegeben.

## Neue Mitglieder

1. Die Person registriert sich selbst und bestätigt gegebenenfalls ihre E-Mail-Adresse.
2. Admin öffnet „Mein Bereich → Probenleitung → Konten & Freigaben“.
3. Ein bestehendes Ensemblemitglied auswählen oder neu anlegen. Erst „Verknüpfen & freigeben“ gewährt interne Daten.
4. Verwaltungsrechte ausdrücklich auswählen. Die Datenbank verhindert doppelte Kontoverknüpfungen auf dieselbe Person.

Eine Sperrung gilt für den nächsten geschützten Serverzugriff. Bereits offline gespeicherte Inhalte können technisch erst beim nächsten Kontakt widerrufen werden. Beim Abmelden oder Kontowechsel entfernt die App die lokalen Kontoinhalte.

## Aktualisieren

```sh
git pull --ff-only
flutter pub get
npm --prefix server ci --ignore-scripts
flutter analyze
flutter test
npm --prefix server test
python3 tool/deploy.py
curl --fail https://theater-app.logge.top/api/healthz
```

Das Deploymentwerkzeug nutzt den bestehenden SSH-Key `~/.ssh/id_ed25519_homebox` und den Keychain-Eintrag `dokploy.logge.top API Key`. Es überträgt ausschließlich explizit ausgewählte Docker-Quelldateien und `build/web`, erzeugt ein unveränderliches Image mit Inhalts-Hash und aktualisiert den bekannten Compose-Dienst. Ein Git-Push allein löst keine Serverbereitstellung aus. `artifacts/last-deploy.json` enthält den erwarteten Hash; `/api/healthz` muss ihn zurückgeben. In Dokploy muss der Dienst `done` und der Container `healthy` sein.

Die Daten und der Firebase-Schlüssel liegen auf HomeBox getrennt vom Image:

- `/home/logge/projects/theater-app/data/theater.sqlite`
- `/home/logge/projects/theater-app/secrets/firebase-service-account.json`
- `/home/logge/projects/theater-app/releases/<Inhalts-Hash>`

Die Datenbank wird mit WAL betrieben. Datenverzeichnis und Schlüssel sind nur für den Benutzer mit UID 1000 lesbar. SELinux-Bind-Mounts verwenden `:Z`. Der Container läuft als `node`, mit 512 MB RAM-Limit und einer CPU. TLS/Domain-Routing übernimmt Dokploy.

## Backup und Wiederherstellung

`python3 tool/backup.py` erzeugt über die SQLite-Backup-API eine konsistente lokale Sicherung unter `.secrets/backups/`. Die Sicherung zusätzlich auf ein separates verschlüsseltes Medium kopieren. Die Firebase- und Android-Schlüssel müssen ebenfalls separat gesichert werden.

Zur Wiederherstellung zuerst nur den Theater-App-Container stoppen, dessen Datenbank und WAL/SHM-Dateien als Rückfallkopie sichern und die Backup-Datenbank an ihren Platz kopieren. Eigentümer UID/GID 1000 und Dateimodus 600 wiederherstellen, dann den Dienst starten. Nicht eine Datenbankdatei über eine laufende WAL-Datenbank kopieren. Anschließend Integritätsprüfung, Anmeldung, Termine und Leser kontrollieren.

## Android

Die signierte Release-APK ist direkt installierbar. Für Updates denselben Keystore aus `.secrets/theater-upload.jks` und dieselbe App-ID verwenden. `android/key.properties` ist privat. Die SHA-1/SHA-256-Fingerprints für Debug und Release sind in Firebase registriert. Google Services wird bei Produktionsbuilds angewandt; Emulatorbuilds verwenden ausschließlich ihre explizite Testkonfiguration.

Für Google Play ist ein AAB vorgesehen. Play-App-Signing-Fingerprints müssen zusätzlich in Firebase hinterlegt werden, sobald die App in Play eingerichtet ist. Store-Eintrag und Veröffentlichung sind separate Schritte.

## iOS und weitere Anmeldeanbieter

Die Firebase-iOS-Datei, Google-URL-Scheme, Push-Entitlement und Background-Modus sind im Xcode-Projekt vorhanden. Für Gerätebuilds fehlen auf diesem Rechner Xcode/CocoaPods sowie ein ausgewähltes Apple-Entwicklerteam. Für iOS-Push ist zusätzlich ein APNs-Schlüssel oder Zertifikat in Firebase hochzuladen. Bis dahin ist iOS-Push nicht abgenommen.

Der Client unterstützt außerdem Apple, Microsoft, GitHub und Facebook. Sie werden erst sichtbar, wenn der jeweilige Anbieter in Firebase korrekt eingerichtet und in `AUTH_PROVIDERS` sowohl beim Backend als auch beim Client eingetragen wird. Dafür sind die jeweiligen OAuth-/Apple-Schlüssel und Callback-Konfigurationen erforderlich. Aktuell werden nur die eingerichteten Anbieter E-Mail/Passwort und Google angezeigt.

## Push

„Mein Bereich → Darstellung & Erinnerungen → Push auf diesem Gerät aktivieren“. Danach unter Probenleitung die Push-Diagnose öffnen und einen Test senden. `accepted_by_provider` bedeutet, dass FCM die Nachricht angenommen hat. Es bestätigt weder sichtbare Zustellung noch das Lesen einer Mitteilung. Ungültige Gerätetokens werden entfernt, Wiederholungen senden nicht erneut an bereits akzeptierte Geräte.

Private Notizen verbleiben lokal. Kommentare und Mitteilungen liegen auf dem Server. Firebase wird für Anmeldung und Push verwendet; eine öffentlich lesbare Firestore-Datenbank wird nicht benötigt.

## Gemeinsame Skript-Regie

Auf Dokploy ist `SCRIPT_FOCUS_BRIDGE=true` gesetzt. Das bestehende Regiepasswort liegt als eigene private Datei unter `secrets/script-director-password` auf HomeBox und wird ausschließlich im Server gelesen. Der Client erhält dieses Passwort nicht. App-Berechtigungen bleiben erforderlich, bevor der Server eine Regieübernahme weiterleitet.

Beim Öffnen der Regiesitzung verbindet sich die App mit dem gleichnamigen Stückraum im bestehenden Skriptdienst. Nur passende Textstellen-IDs und Fassungen werden übernommen. „Regie übernehmen“ und das Antippen einer Textstelle können eine andere Regie ablösen, entsprechend dem bestehenden Skript-Verhalten. Folgen bleibt eine persönliche Entscheidung. Eine unbenutzte Serververbindung wird nach zehn Minuten geschlossen. Technisch ist der bestehende Skriptdienst weiterhin die maßgebliche Quelle für gemeinsame Marker; dessen vorhandene Zugangsregeln werden durch die neue App nicht ersetzt.


## Personen, Rollen und Login-Verknüpfungen

Unter „Probenleitung → Konten & Verknüpfungen“ zeigt „Personen“ auch Mitglieder ohne Login. Die E-Mail-Adresse gehört zum tatsächlich verknüpften Firebase-Konto. Eine gesperrte oder inaktive Person bleibt als verknüpft erkennbar; der Zugangsstatus steht daneben. Mehrere Theaterrollen hängen an derselben Person. Über „Konten“ lassen sich ausstehende, freigegebene, gesperrte und abgelehnte Registrierungen filtern. „Rollen“ zeigt die Besetzung je Produktion. Die Suche berücksichtigt Namen, Login-Adressen, Rollen und Produktionen.

„Konto verknüpfen“ an einer Person öffnet die vorhandenen Registrierungen und anschließend die Freigabe mit vorausgewählter Person. Die Freigabe bleibt ein ausdrücklicher Admin-Schritt. Ohne Registrierung wird kein Firebase-Konto angelegt. Personen können sich mit ihrer eigenen E-Mail-Adresse oder Google registrieren. Die generierten alten Adressen `name@kolpingtheater-ramsen.de` sind keine bestätigten Postfächer und werden nicht übernommen.

### Einmaliger Stammdatenimport

`server/scripts/import-roster.mjs` übernimmt explizit ausgewählte Personenfelder und Besetzungen. Es übernimmt keine Passwörter, Login-Adressen oder Admin-Rechte. Die private Eingabedatei liegt außerhalb von Git in `.secrets/roster-import.json`. Sie enthält Quell-IDs, Namen, Gruppen, Aufgaben, explizite Zuordnungen vorhandener Personen und bestätigte Namensvarianten für die Skriptbesetzung.

Vor einer Anwendung `python3 tool/backup.py` ausführen. Vorschau und Anwendung:

```sh
node server/scripts/import-roster.mjs PFAD_ZUR_DATENBANK .secrets/roster-import.json
node server/scripts/import-roster.mjs PFAD_ZUR_DATENBANK .secrets/roster-import.json --apply
```

Die Anwendung läuft in einer SQLite-Transaktion. Bestehende abweichende Besetzungen werden als Konflikt abgewiesen. Eine erfolgreich angewendete Migration ist anhand von Quellname, Migrations-ID und Eingabe-Hash wiederholbar, ohne Personen doppelt anzulegen oder spätere Änderungen zu überschreiben. `member.save` erhält Quellbezüge und importierte Aufgaben bei späteren Namensänderungen.

Der Import vom 13. September 2026 umfasst 41 Personen der bisherigen Theaterverwaltung und sieben weitere Namen aus dem Stück von 2025. Die vorhandene Admin-Person bleibt erhalten und übernimmt den Quellbezug „Logge“. Auch die während der Arbeit angelegten Personen Yunus und Jonas sowie ihre Login-Verknüpfungen bleiben erhalten. Louis bleibt eine eigene Person. Die bestätigten Zuordnungen sind Maximilian → Max F., Max → Max H. und Lina → Lina R.; Sebastian/Sebbi und Tobias/Tobi ergeben sich aus den übereinstimmenden Rollen Wilson und Jacques. 67 Einzelrollen sind besetzt. Die drei Einträge für gemeinsame Sprechergruppen von 2025 bleiben ohne Einzelperson.


## Galerien und Profile

„Mein Bereich → Galerien → Album freigeben“ verbindet einen Immich-Freigabelink mit einem Titel und optional einem Stück. Alle freigegebenen Mitglieder sehen das Album. Im Albummenü können Admins die Freigabe beenden und wiederherstellen, Titel und Quelle ändern oder eigene Bilder hinzufügen. Ausgeblendete eigene Bilder lassen sich über das Admin-Menü wieder einblenden. Die Immich-Quelle selbst wird dabei nicht verändert.

Das Raster lädt jeweils 60 Einträge und nur sichtbare Vorschaubilder. Die Lightbox unterstützt Wischen, Pfeile und Zoom. „Original herunterladen“ übernimmt bei Immich die unveränderte Originaldatei, sofern die Quellfreigabe Downloads erlaubt. Videos öffnen sich im Originalalbum. Passwortgeschützte oder abgelaufene Immich-Freigaben melden einen Fehler; bereits hochgeladene lokale Bilder bleiben verfügbar. `GALLERY_HOSTS` begrenzt erlaubte Quellen, standardmäßig auf `photo.rittmann.cloud`. Freigabedaten werden fünf Minuten zwischengespeichert; Änderungen der Download-Erlaubnis in Immich greifen spätestens danach. Ein Entzug der Freigabe in der Theater-App gilt sofort beim nächsten Serverzugriff.

„Mein Bereich → Profil bearbeiten“ speichert ein eigenes Profilbild und eine Statuszeile bis 120 Zeichen. Name, Besetzung und Kontoverknüpfung bleiben Verwaltungsaufgaben. Bilder bis 8 MB werden beim Upload geprüft, ausgerichtet, von Metadaten befreit und als WebP gespeichert. Profilbilder werden quadratisch auf 512 Pixel zugeschnitten, Galeriebilder auf höchstens 2048 Pixel verkleinert. Downloads eigener Uploads enthalten diese normalisierte Datei. Binäre Bildabrufe benötigen einen freigegebenen Zugang. Vorschaubilder bleiben nur im begrenzten Arbeitsspeicher der App, ohne Tokens in URLs.

`/data/media` liegt im vorhandenen persistenten Datenvolume. `tool/backup.py` erzeugt zusätzlich zur SQLite-Sicherung ein gleich datiertes `-media.tar.gz` und prüft alle Datenbankreferenzen. Bei einer Wiederherstellung dieses Archiv zusammen mit der passenden Datenbank zurückspielen und UID/GID 1000 setzen. Immich-Originale werden nicht in diese Sicherung kopiert, ihre Sicherung bleibt Aufgabe des Fotoservers.

Der Probenplan wechselt zwischen Agenda und Monatskalender. Die Kalenderansicht zeigt auch vergangene Proben und alle Tage einer mehrtägigen Probe. Tippen auf einen Tag öffnet dessen Terminliste.

## Original-Logo

Quelle: https://kolpingtheater-ramsen.de/presse, Originaldatei https://kolpingtheater-ramsen.de/img/logo.png. `assets/brand/kolpingtheater-ramsen.png` bleibt unverändert (SHA-256 `c22912bb9397371f959f23fd9caf75880be49ec2e639b1b2c81508c0a9626fab`). `node tool/brand-icons.mjs` erzeugt daraus lediglich passend skalierte Plattformicons auf weißen Flächen. Anmeldung, App-Kopf, Infoansicht und Plattformicons verwenden dieses Logo.
