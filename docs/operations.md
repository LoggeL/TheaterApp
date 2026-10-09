# Betrieb und Zugang

## Laufende Instanz

- Web-App: https://app.kolpingtheater-ramsen.de
- Bisherige App- und API-Adresse für installierte Clients: https://theater-app.logge.top
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

### Drehbucharchiv

Unter "Drehbücher" stehen die aktuellen Produktionen. "Drehbucharchiv" öffnet ältere Stücke, ebenfalls mit dem neuesten zuerst. Die Theaterleitung kann in "Produktionen & Besetzung" eine Produktion öffnen und über "Ins Archiv verschieben" oder "Aus Archiv zurückholen" ihren Status ändern. Der Status bleibt beim erneuten Drehbuchimport erhalten. Rollen, Besetzungen, Kommentare, lokale Markierungen, Offline-Drehbücher und Terminverknüpfungen bleiben bestehen; das Archiv ändert die Sichtbarkeit in der aktuellen Übersicht.

### Web-Build veröffentlichen

```sh
git pull --ff-only
flutter pub get
npm --prefix server ci --ignore-scripts
flutter analyze
flutter test
npm --prefix server test
python3 tool/deploy.py
curl --fail https://app.kolpingtheater-ramsen.de/api/healthz
```

Das Deploymentwerkzeug nutzt den bestehenden SSH-Key `~/.ssh/id_ed25519_homebox` und den Keychain-Eintrag `dokploy.logge.top API Key`. Es überträgt ausschließlich explizit ausgewählte Docker-Quelldateien und `build/web`, erzeugt ein unveränderliches Image mit Inhalts-Hash und aktualisiert den bekannten Compose-Dienst. Ein Git-Push allein löst keine Serverbereitstellung aus. `artifacts/last-deploy.json` enthält den erwarteten Hash; `/api/healthz` muss ihn zurückgeben. In Dokploy muss der Dienst `done` und der Container `healthy` sein.

Die Daten und der Firebase-Schlüssel liegen auf HomeBox getrennt vom Image:

- `/home/logge/projects/theater-app/data/theater.sqlite`
- `/home/logge/projects/theater-app/secrets/firebase-service-account.json`
- `/home/logge/projects/theater-app/releases/<Inhalts-Hash>`

Die Datenbank wird mit WAL betrieben. Datenverzeichnis und Schlüssel sind nur für den Benutzer mit UID 1000 lesbar. SELinux-Bind-Mounts verwenden `:Z`. Der Container läuft als `node`, mit 512 MB RAM-Limit und einer CPU.

Die Web-Domain nutzt den bestehenden, lokal verwalteten Cloudflare-Tunnel `local-server` auf HomeBox. Der DNS-CNAME `app` zeigt mit aktiviertem Proxy auf `0bbb6ff3-724e-4d75-b4c5-42769c3aa5c6.cfargotunnel.com`. In `/etc/cloudflared/config.yml` zeigt die genaue Hostname-Route auf `http://localhost:80`; Dokploy ordnet diesen Host dem Dienst `theater`, Port 8787, zu. Öffentlich erfolgt der Zugriff per HTTPS, der Tunnel verschlüsselt die Verbindung bis HomeBox, und der HTTP-Schritt bleibt auf dem lokalen Rechner. Für diese Route ist deshalb in Dokploy kein zusätzliches Origin-TLS konfiguriert.

`config/dokploy.json` enthält die Hauptdomain, die weiterhin bedienten zusätzlichen Hosts und die Hosts mit lokalem HTTP-Origin. Das Deployment übernimmt alle Hosts in `ALLOWED_ORIGINS` und verwendet die Hauptdomain als `APP_ORIGIN` für Push-Links. Firebase Authentication muss beide öffentlichen App-Domains in `authorizedDomains` führen. `server/scripts/firebase-configure.mjs` ergänzt diese Domains aus derselben Konfiguration. Die Android- und iOS-Konfigurationen behalten die bisherige API-Adresse; der nächste Webbuild verwendet die neue Domain.

## Backup und Wiederherstellung

`python3 tool/backup.py` erzeugt über die SQLite-Backup-API eine konsistente lokale Sicherung unter `.secrets/backups/`. Die Sicherung zusätzlich auf ein separates verschlüsseltes Medium kopieren. Die Firebase- und Android-Schlüssel müssen ebenfalls separat gesichert werden.

Zur Wiederherstellung zuerst nur den Theater-App-Container stoppen, dessen Datenbank und WAL/SHM-Dateien als Rückfallkopie sichern und die Backup-Datenbank an ihren Platz kopieren. Eigentümer UID/GID 1000 und Dateimodus 600 wiederherstellen, dann den Dienst starten. Nicht eine Datenbankdatei über eine laufende WAL-Datenbank kopieren. Anschließend Integritätsprüfung, Anmeldung, Termine und Leser kontrollieren.

## Android

Die signierte Release-APK ist direkt installierbar. Für Updates denselben Keystore aus `.secrets/theater-upload.jks` und dieselbe App-ID verwenden. `android/key.properties` ist privat. Die SHA-1/SHA-256-Fingerprints für Debug und Release sind in Firebase registriert. Google Services wird bei Produktionsbuilds angewandt; Emulatorbuilds verwenden ausschließlich ihre explizite Testkonfiguration.

Für Google Play ist ein AAB vorgesehen. Play-App-Signing-Fingerprints müssen zusätzlich in Firebase hinterlegt werden, sobald die App in Play eingerichtet ist. Store-Eintrag und Veröffentlichung sind separate Schritte.

## iOS und weitere Anmeldeanbieter

Die Firebase-iOS-Datei, Google-URL-Scheme, Push-Entitlement und Background-Modus sind im Xcode-Projekt vorhanden. Für Gerätebuilds fehlen auf diesem Rechner Xcode/CocoaPods sowie ein ausgewähltes Apple-Entwicklerteam. Für iOS-Push ist zusätzlich ein APNs-Schlüssel oder Zertifikat in Firebase hochzuladen. Bis dahin ist iOS-Push nicht abgenommen.

Der Client unterstützt außerdem Apple, Microsoft, GitHub und Facebook. Sie werden erst sichtbar, wenn der jeweilige Anbieter in Firebase korrekt eingerichtet und in `AUTH_PROVIDERS` sowohl beim Backend als auch beim Client eingetragen wird. Dafür sind die jeweiligen OAuth-/Apple-Schlüssel und Callback-Konfigurationen erforderlich. Aktuell werden nur die eingerichteten Anbieter E-Mail/Passwort und Google angezeigt.

## Installierbare Web-App (PWA)

Die Web-App bietet auf der Anmeldeseite und unter "Mein Bereich" die Installation oder eine zum Gerät passende Anleitung an. Chrome und Edge können ihren Installationsdialog direkt öffnen. Auf iPhone und iPad erfolgt die Installation über Teilen → Zum Home-Bildschirm, auf macOS in Safari über Ablage → Zum Dock hinzufügen. Nach dem Start im eigenen App-Fenster wird die Installationskarte ausgeblendet.

Das Manifest hat die stabile App-ID `/`, Startadresse und Geltungsbereich `/`, deutsche Sprache und den Anzeigemodus `standalone`. Die vorhandenen offiziellen Icons enthalten normale und maskierbare Varianten mit 192 und 512 Pixeln. Die Apple-Metadaten und das Touch-Icon stehen in `web/index.html`.

`tool/version-web.mjs` erzeugt zusätzlich zum versionierten Einstieg den eigenen Service Worker `theater-service-worker.js`. Alle Web-Builds verwenden `--pwa-strategy=none` und führen danach dieses Werkzeug aus. Der Worker speichert ausschließlich die explizite Liste öffentlicher App-Dateien und die fest versionierten Firebase-JavaScript-Bibliotheken. API-Antworten, angemeldete Anfragen und private Medien werden nicht im Service Worker gespeichert. Die bereits vorhandene lokale Datenspeicherung der Flutter-App bleibt für Offline-Inhalte zuständig; Anmeldung und Synchronisierung benötigen eine Verbindung.

Nach dem ersten vollständigen Laden lässt sich die Oberfläche offline öffnen. Die Standardschrift Roboto mit ihren Schriftschnitten und ihrer Lizenz liegt im App-Paket. Navigation fragt zuerst den Server nach der aktuellen Version. Neue Builds ersetzen den App-Cache, ohne ein offenes Formular neu zu laden. Der Push-Worker `firebase-messaging-sw.js` bleibt unter seinem separaten Firebase-Geltungsbereich. Manifest und Worker werden ohne HTTP-Cache ausgeliefert, fehlende Dateien liefern HTTP 404.

Auch Schriften, Bilder und CanvasKit erhalten Verzeichnisadressen mit einem Hash ihres Inhalts. Der Flutter-Einstieg und der Offline-Cache verwenden dieselben Adressen. So können Browser und vorgeschaltete Web-Caches keine Dateien einer früheren Version in einen neuen Build mischen. Die ursprünglichen Dateipfade bleiben für noch offene ältere App-Sitzungen vorhanden.

## Push aktivieren

„Mein Bereich → Darstellung & Erinnerungen → Push auf diesem Gerät aktivieren“. Danach unter Probenleitung die Push-Diagnose öffnen und einen Test senden. `accepted_by_provider` bedeutet, dass FCM die Nachricht angenommen hat. Es bestätigt weder sichtbare Zustellung noch das Lesen einer Mitteilung. Ungültige Gerätetokens werden entfernt, Wiederholungen senden nicht erneut an bereits akzeptierte Geräte.

Private Notizen verbleiben lokal. Kommentare und Mitteilungen liegen auf dem Server. Firebase wird für Anmeldung und Push verwendet; eine öffentlich lesbare Firestore-Datenbank wird nicht benötigt.

## Gemeinsame Skript-Regie

Auf Dokploy ist `SCRIPT_FOCUS_BRIDGE=true` gesetzt. Das bestehende Regiepasswort liegt als eigene private Datei unter `secrets/script-director-password` auf HomeBox und wird ausschließlich im Server gelesen. Der Client erhält dieses Passwort nicht. App-Berechtigungen bleiben erforderlich, bevor der Server eine Regieübernahme weiterleitet.

Beim Öffnen der Regiesitzung verbindet sich die App mit dem gleichnamigen Stückraum im bestehenden Skriptdienst. Nur passende Textstellen-IDs und Fassungen werden übernommen. „Regie übernehmen“ und das Antippen einer Textstelle können eine andere Regie ablösen, entsprechend dem bestehenden Skript-Verhalten. Folgen bleibt eine persönliche Entscheidung. Eine unbenutzte Serververbindung wird nach zehn Minuten geschlossen. Technisch ist der bestehende Skriptdienst weiterhin die maßgebliche Quelle für gemeinsame Marker; dessen vorhandene Zugangsregeln werden durch die neue App nicht ersetzt.


## Personen, Rollen und Login-Verknüpfungen

Neue Konten geben einen Namen zur Zuordnung an. Bei E-Mail/Passwort steht das Pflichtfeld im Registrierungsformular, bei Google auf der Seite vor der Freigabe. Der Hinweis erklärt, dass dieser Name nur zur Kontozuordnung dient. Die Theaterleitung sieht ihn neben der Login-Adresse. Vor der Freigabe kann die Person ihn korrigieren; eine Korrektur macht bereits geöffnete Freigabeanfragen ungültig. Nach der Verknüpfung verwendet die App den Namen der Ensembleperson.

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

„Mein Bereich → Profil bearbeiten“ speichert ein eigenes Profilbild. Statuszeilen und dekorative Slogans sind entfernt. Name, Besetzung und Kontoverknüpfung bleiben Verwaltungsaufgaben. Bilder bis 8 MB werden beim Upload geprüft, ausgerichtet, von Metadaten befreit und als WebP gespeichert. Profilbilder werden quadratisch auf 512 Pixel zugeschnitten, Galeriebilder auf höchstens 2048 Pixel verkleinert. Downloads eigener Uploads enthalten diese normalisierte Datei. Binäre Bildabrufe benötigen einen freigegebenen Zugang. Vorschaubilder bleiben nur im begrenzten Arbeitsspeicher der App, ohne Tokens in URLs.

`/data/media` liegt im vorhandenen persistenten Datenvolume. `tool/backup.py` erzeugt zusätzlich zur SQLite-Sicherung ein gleich datiertes `-media.tar.gz` und prüft alle Datenbankreferenzen. Bei einer Wiederherstellung dieses Archiv zusammen mit der passenden Datenbank zurückspielen und UID/GID 1000 setzen. Immich-Originale werden nicht in diese Sicherung kopiert, ihre Sicherung bleibt Aufgabe des Fotoservers.

Der Probenplan wechselt zwischen Agenda und Monatskalender. Die Kalenderansicht zeigt auch vergangene Proben und alle Tage einer mehrtägigen Probe. Tippen auf einen Tag öffnet dessen Terminliste.

## Original-Logo

Quelle: https://kolpingtheater-ramsen.de/presse, Originaldatei https://kolpingtheater-ramsen.de/img/logo.png. `assets/brand/kolpingtheater-ramsen.png` bleibt unverändert (SHA-256 `c22912bb9397371f959f23fd9caf75880be49ec2e639b1b2c81508c0a9626fab`). `node tool/brand-icons.mjs` erzeugt daraus lediglich passend skalierte Plattformicons auf weißen Flächen. Anmeldung, App-Kopf, Infoansicht und Plattformicons verwenden dieses Logo.

## Termine, Rollen und Abstimmungen (0.4.0)

Die Administration ist als eigener Navigationseintrag sichtbar. Auf breiten Bildschirmen steht die Navigation links; Formulare und Texte bleiben in einer begrenzten Lesebreite. Der Monatskalender zeigt am Desktop auch Termintitel.

Termine haben eine Beschreibung (bis 5.000 Zeichen), die auch in die Kalenderdatei übernommen wird. Zur Auswahl stehen Probe, Leseprobe, Technikprobe, Kostümprobe, Generalprobe, Aufführung, Besprechung, Workshop, Aufbau, Abbau, Feier / Ausflug und Sonstiges.

Unter „Administration → Rollen verwalten“ lassen sich Ensemble-Rollen anlegen und umbenennen. Jede Person kann mehrere davon haben; die Zuordnung erfolgt beim Bearbeiten der Person. Eine verwendete Rolle lässt sich erst nach dem Entfernen ihrer Zuordnungen löschen. Diese Aufgabenrollen ändern keine Kontoberechtigungen. Rollen im Drehbuch und Besetzungen bleiben mit der jeweiligen Produktion verbunden.

Allgemeine Abstimmungen stehen unter „Mein Bereich → Abstimmungen“ und in der Administration. Admins legen Frage, Beschreibung, zwei bis zwölf Antworten, die Abstimmungsart und optional ein Enddatum mit Uhrzeit fest. Anonyme Abstimmungen zeigen nur Stimmenzahlen; namentliche zeigen allen freigegebenen Mitgliedern die Namen bei der gewählten Antwort. Bestehende Abstimmungen bleiben anonym. Nach der ersten Stimme bleiben die Abstimmungsart und die Antworttexte erhalten. Jede Person hat eine veränderbare Stimme. Mit Erreichen der Frist endet die Abstimmung automatisch, auch wenn eine verspätete Stimme aus der Offline-Warteschlange ankommt. Admins können beenden und wieder öffnen; beim Wiederöffnen wird eine abgelaufene Frist entfernt. Terminabstimmungen werden nicht erzeugt.

Beim ersten Öffnen nach der Freigabe fragt die App nach Benachrichtigungen. Im Browser erscheint zuerst ein kurzer Dialog, dessen „Erlauben“-Schaltfläche die Browserberechtigung anfordert. Eine bestehende Ablehnung oder ausdrücklich deaktivierte Push-Einstellung wird respektiert. Ein neuer Versuch ist in den Erinnerungseinstellungen möglich.

Immich-Cover verwenden das explizite Album-Titelbild in Preview-Auflösung. Ist kein passendes Titelbild verfügbar, wird ein Foto des Albums verwendet. `tool/version-web.mjs` bricht das Deployment ab, wenn die Web-Implementierung des Bildpickers im kompilierten JavaScript fehlt. Nach Änderungen an Flutter-Plugins einen sauberen Webbuild erzeugen; Web- und Android-Builds nacheinander ausführen.
