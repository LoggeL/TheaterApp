# Betrieb und Zugang

## Laufende Instanz

- Web-App: https://app.kolpingtheater-ramsen.de
- Bisherige Web-Adresse, mit dauerhafter Weiterleitung: https://theater-app.logge.top
- Bisherige API für installierte Clients: https://theater-app.logge.top/api/
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

### Botschutz vor der Anmeldung

Vor dem ersten Anmelde- oder Registrierungsbildschirm eines Geräts fragt die App „In welchem Ort ist das Kolpingtheater?“. Frage, Hinweis, Antworten und zulässige Zusatzwörter stehen in `server/src/bot-check.json`; `BOT_CHECK_CONFIG_FILE` kann eine andere Datei angeben. Der Client erhält nur Frage und Hinweis, der Server prüft die Antwort. Groß-/Kleinschreibung, Leerzeichen, Satzzeichen, eine Postleitzahl, Klammerzusätze, Teile nach einem Komma und die Zusatzwörter (etwa „in“, „Pfalz“) spielen keine Rolle; ab fünf Buchstaben ist ein Tippfehler erlaubt. Nach drei falschen Antworten wartet die App 5 Sekunden, danach je weitere 5 Sekunden bis höchstens 30. Der Server erlaubt 10 Versuche je Adresse in 10 Minuten (`CLIENT_IP_HEADER=cf-connecting-ip` hinter Cloudflare) und hält dafür nur Hashwerte im Arbeitsspeicher.

Eine richtige Antwort liefert einen signierten Nachweis, 30 Minuten gültig und nur für ein neues Konto verwendbar. Das Gerät merkt sich die beantwortete Frage und die Antwort, um vor einer späteren Registrierung einen neuen Nachweis zu holen. Geräte mit bestehender Anmeldung werden nie gefragt. Neue Konten ohne gültigen Nachweis, etwa aus älteren App-Versionen, werden weiter angenommen, aber nicht per „Neue Registrierung“ gemeldet und in der Freigabe als „Ohne Botschutz“ markiert. Ein später nachgereichter Nachweis holt die Meldung nach. Das Anlegen eines Firebase-Kontos selbst kann der Server im Spark-Tarif nicht verhindern.

Zusätzlich gibt es eine unsichtbare Bot-Falle auf dem Botschutz-Bildschirm und im E-Mail/Passwort-Formular (Anmelden und Registrieren): ein Feld, das nicht gezeichnet wird, keinen Fokus und keine Taps annimmt, für Screenreader ausgeblendet ist und ohne Autofill-Hinweise nicht an Autofill teilnimmt (in Flutter-Web entsteht dafür nie ein DOM-Eingabefeld), sowie die Zeit vom ersten Anzeigen bis zum Absenden. Die App schickt beides als `botTrap: {filled, elapsedMs}` mit der Antwort (`POST /bot-check`) und der ersten Kontoanfrage (`POST /auth/session`). Ein gefülltes Feld oder weniger als 2 Sekunden (`minFillMs`) gilt als Verdacht. Beim Botschutz-Check bekommt eine richtige Antwort dann einen Köder-Nachweis, der wie ein normaler aussieht; beim Konto zählen Köder und Formularverdacht als `botCheck: 'trap'` mit `botTrap: 'honeypot'` oder `'fast'`. Solche Konten werden angenommen, aber nicht per „Neue Registrierung“ gemeldet und in der Freigabe als „Verdacht: Bot-Falle“ markiert; ein späterer gültiger Nachweis hebt das nicht auf. Fehlende Angaben (ältere Apps, automatische Erneuerung des Nachweises) gelten nicht als Verdacht. Falsche Antworten setzen die Zeitmessung nicht zurück.

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

In der Cloudflare-Zone `logge.top` ist die Single-Redirect-Regel "Theater-App: neue Web-Domain, API beibehalten" aktiv (ID `4d30fc4c7a0949659974a335fefbb77a`). Sie leitet HTTP- und HTTPS-Web-Aufrufe mit Status 301 auf die neue Domain um und erhält Pfad und Query-Parameter. Der Filter lautet `(http.host eq "theater-app.logge.top" and not starts_with(http.request.uri.path, "/api/") and http.request.uri.path ne "/api")`, das dynamische Ziel `concat("https://app.kolpingtheater-ramsen.de", http.request.uri.path)`, mit "Preserve query string" aktiviert. Die Ausnahme für `/api` und `/api/` ist für installierte Clients erforderlich, deren API-Client keine Redirects verfolgt. Der vorhandene proxied Wildcard-DNS-Eintrag `*.logge.top` bedient weiterhin den Tunnel. Zum Zurücksetzen nur diese Redirect-Regel deaktivieren; DNS, Tunnel und die zusätzliche Dokploy-Domain bleiben bestehen.

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

Auch Schriften, Bilder und CanvasKit erhalten Verzeichnisadressen mit einem Hash ihres Inhalts. Der Flutter-Einstieg und der Offline-Cache verwenden dieselben Adressen. So können Browser und vorgeschaltete Web-Caches keine Dateien einer früheren Version in einen neuen Build mischen. Der Server liefert diese gehashten Dateien (`main.<hash>.dart.js`, `main.<hash>.dart.wasm`, `main.<hash>.dart.mjs`, `flutter_bootstrap.<hash>.js`, `pwa.<hash>.js`, gehashte Icons sowie alles unter `web-renderer/<hash>/` und `web-assets/<hash>/`) mit `Cache-Control: public, max-age=31536000, immutable` aus. `index.html`, Service Worker, Manifeste und alle ungehashten `.js`/`.mjs`/`.json`-Dateien bleiben bei `no-store`. Die ursprünglichen Dateipfade bleiben für noch offene ältere App-Sitzungen vorhanden.

Der Web-Build entsteht mit `--wasm`. Chromium-Browser mit WasmGC (Chrome und Edge auf Android und Desktop, Samsung Internet) starten mit dart2wasm und dem Renderer skwasm. Safari, alle iOS-Browser und Firefox starten weiter mit dart2js und CanvasKit. Diese Auswahl trifft Flutters Loader. Der Service Worker legt beim Installieren nur den Renderer in den Offline-Cache, mit dem dieser Browser startet. Lädt der Browser doch einen anderen, speichert der Worker diesen beim ersten Laden nach. Der Server sendet bewusst keine COOP/COEP-Header: skwasm läuft deshalb mit einem Thread. Cross-Origin-Isolation würde die Google-Anmeldung per Popup und das Firebase-Auth-iframe brechen.

## Push aktivieren

„Mein Bereich → Darstellung & Erinnerungen → Push auf diesem Gerät aktivieren“. Danach unter Probenleitung die Push-Diagnose öffnen und einen Test senden. `accepted_by_provider` bedeutet, dass FCM die Nachricht angenommen hat. Es bestätigt weder sichtbare Zustellung noch das Lesen einer Mitteilung. Ungültige Gerätetokens werden entfernt, Wiederholungen senden nicht erneut an bereits akzeptierte Geräte.

Jede Push-Art lässt sich in denselben Einstellungen persönlich abschalten (für alle Geräte der Person). „Erinnere mich“ regelt wie bisher die Terminerinnerungen (`dayBefore`, `twoHours`, eigene Vorlaufzeit) und Terminänderungen (`changes`, siehe unten). Unter „Push-Nachrichten“ stehen für alle: „Neue Termine“ (`eventAnnouncements`: angekündigte neue Termine und Terminserien, Aufnahme ins Ensemble), „Fehlende Rückmeldung“ (`eventRequests`), „Terminfinder“ (`slots`: neue Terminfinder, Einteilung, Verschiebung, Wegfall, Nachfrage), „Mitteilungen“ (`messages`, mit Erinnerungen an Ungelesene), „Abstimmungen“ (`polls`, mit Erinnerungen), „Pushes der Leitung“ (`direct`, eigene Pushes auf Abruf) und „Antworten auf dein Feedback“ (`feedbackReplies`). Unter „Meldungen an die Leitung“ stehen „Kurzfristige Absagen melden“ (Admins und Regie, `lateDeclines`) sowie nur für Admins „Neue Registrierungen“ (`adminRegistrations`) und „Feedback“ (`adminFeedback`, neues Feedback und Rückmeldungen dazu). Immer zugestellt werden „Zugang freigegeben“ (die Person erfährt nur so von ihrer Freischaltung; abschalten könnte sie es ohnehin erst danach) und der selbst angeforderte Test-Push der Push-Diagnose. Anmeldung und Passwort laufen über Firebase Auth und erzeugen keine Pushes. Die Schalter liegen mit den Erinnerungen im Datensatz `reminders` der Person; ein fehlender Wert bedeutet „an“, und ältere Apps, die einen Schalter nicht kennen, lassen den gespeicherten Wert stehen. Der Versand (`server/src/push.mjs`) bestimmt die Art jedes Jobs in `server/src/push-kinds.mjs`, auch für Jobs, die vor dem Update in die Warteschlange kamen, und lässt Personen mit abgeschalteter Art aus. Die Schalter wirken nur auf Push; Termin-E-Mails folgen weiter ihrem eigenen Schalter und `changes`. Die App zeigt die neuen Schalter nur bei gemeldetem Feature `pushSettings`.

Terminänderungen (`changes`): Beim Bearbeiten eines Termins pusht der Server nur eine neue Zeit (Datum, Beginn, Ende) oder einen neuen Ort, und nur, wenn der Schalter „Neue Zeit oder neuen Ort per Push melden“ im Editor an ist (Standard). Ausgeschaltet geht kein Push raus; Änderungen an Titel, Beschreibung, Rückmeldesperre oder Einladung lösen nie einen Push aus (Antwort `pushSkipped: 'unchanged'`). Der Push geht wie bisher nur an Zugesagte und nur für Termine innerhalb der nächsten 14 Tage; die E-Mail für eine solche Änderung geht auch bei ausgeschaltetem Push-Schalter an alle, die Termin-E-Mails eingeschaltet haben. Wird ein noch nicht beendeter Termin gelöscht, bekommen alle Eingeladenen außer den Abgesagten und dem löschenden Admin einen Push „Termin abgesagt“, bei „Diesen und alle folgenden“ einen einzigen Push „Termine abgesagt“ mit Anzahl. Dieser Push hat keinen Deep Link, weil der Termin fehlt. Geplante Änderungs-Pushes älterer Serverstände mit `announce: 'changed'` zählen ebenfalls als `changes`.

Private Notizen verbleiben lokal. Kommentare und Mitteilungen liegen auf dem Server. Firebase wird für Anmeldung und Push verwendet; eine öffentlich lesbare Firestore-Datenbank wird nicht benötigt.

## Kalender-Abo

„Mein Bereich → Benachrichtigungen & Darstellung → Kalender abonnieren“ (nur bei gemeldetem Feature `calendarFeed`) gibt jedem freigegebenen Konto einen persönlichen Abo-Link `<APP_ORIGIN>/api/calendar/<token>.ics`. Die Seite bietet „In Google Kalender hinzufügen“ (`https://calendar.google.com/calendar/r?cid=webcal://…`), „In Apple-Kalender / Outlook öffnen“ (`webcal://…`), „Link kopieren“ und „Link neu erzeugen“. Der Server baut die Adresse aus `APP_ORIGIN`; ohne diese Variable antwortet `GET /api/mobile/v1/calendar-feed` mit 409 `calendar_unavailable`. Der Pfad liegt bewusst unter `/api/`, damit weder der Service Worker noch die Cloudflare-Weiterleitung von `theater-app.logge.top` ihn umleiten.

- **Token:** 24 zufällige Bytes (192 Bit), base64url, je Konto genau eines. Gespeichert als Eintrag `calendarFeeds` mit dem SHA-256 des Tokens als Schlüssel, zusammen mit `uid`, `personId` und dem Token selbst, damit die App denselben Link auf jedem Gerät wieder anzeigen kann. Der Feed enthält nichts, was nicht ohnehin in derselben Datenbank steht. `GET /calendar-feed` legt das Token beim ersten Aufruf an, `POST /calendar-feed/reset` ersetzt es (Audit `calendarFeed.reset`); der alte Link liefert sofort 404. Beim Löschen des Kontos verschwindet der Eintrag.
- **Abruf ohne Anmeldung:** Kalender-Apps senden keine Anmeldung, das Token ist der einzige Nachweis. Unbekannte Tokens, gesperrte, gelöschte, noch nicht freigegebene oder deaktivierte Konten sowie ein Konto, das inzwischen mit einer anderen Person verknüpft ist, ergeben dasselbe 404. Antwort `text/calendar; charset=utf-8` mit `ETag` (304 bei `If-None-Match`) und `Cache-Control: private, max-age=300`. Grenzen: 60 Abrufe je Token in 10 Minuten; 30 unbekannte Tokens je Client-Adresse in 10 Minuten (`CLIENT_IP_HEADER`, nur gehasht im Arbeitsspeicher). Danach 429 mit `Retry-After`. Fehlversuche einer Adresse blockieren gültige Links nie, weil sich etwa Googles Abrufer Adressen teilen.
- **Inhalt:** alle Termine, zu denen die Person eingeladen ist (wie `addressedToMe`; Admins bekommen nicht alle Termine), von Terminen, die vor höchstens 60 Tagen endeten, bis unbegrenzt in die Zukunft. Abgesagte Termine fehlen, auch automatische Absagen einer Abwesenheit; ohne eigene Antwort zählt eine Abwesenheit am Termintag ebenfalls als Absage, ein ausdrückliches „Dabei“ trotz Abwesenheit nicht. Gelöschte Termine fehlen einfach. Je Termin `UID` `<Termin-ID>@kolpingtheater.ramsen` (dieselbe wie beim Einzelexport „In Kalender übernehmen“), `SEQUENCE` = Terminversion − 1, `DTSTAMP`/`LAST-MODIFIED` aus `updatedAt` (ältere Termine ohne `updatedAt` bekommen die Abrufzeit), Zeiten in UTC, `SUMMARY` mit Stücktitel, `LOCATION`, `DESCRIPTION` mit Beschreibung und Deep Link, `URL`. Kalenderkopf mit `X-WR-CALNAME:Kolpingtheater Ramsen`, `X-WR-TIMEZONE:Europe/Berlin`, `REFRESH-INTERVAL`/`X-PUBLISHED-TTL` `PT1H`. Keine Erinnerungen (`VALARM`). Ganztägige Termine gibt es im Datenmodell nicht.
- **Datenschutz:** Wer den Link kennt, sieht Titel, Zeiten, Orte und Beschreibungen der Termine dieser Person. Die App weist darauf hin; bei Verdacht „Link neu erzeugen“. Wie oft ein Kalender nachlädt, entscheidet die Kalender-App (Google teils nur alle 12–24 Stunden).

## Gemeinsame Skript-Regie

Auf Dokploy ist `SCRIPT_FOCUS_BRIDGE=true` gesetzt. Das bestehende Regiepasswort liegt als eigene private Datei unter `secrets/script-director-password` auf HomeBox und wird ausschließlich im Server gelesen. Der Client erhält dieses Passwort nicht. App-Berechtigungen bleiben erforderlich, bevor der Server eine Regieübernahme weiterleitet.

Beim Öffnen der Regiesitzung verbindet sich die App mit dem gleichnamigen Stückraum im bestehenden Skriptdienst. Nur passende Textstellen-IDs und Fassungen werden übernommen. „Regie übernehmen“ und das Antippen einer Textstelle können eine andere Regie ablösen, entsprechend dem bestehenden Skript-Verhalten. Folgen bleibt eine persönliche Entscheidung. Eine unbenutzte Serververbindung wird nach zehn Minuten geschlossen. Technisch ist der bestehende Skriptdienst weiterhin die maßgebliche Quelle für gemeinsame Marker; dessen vorhandene Zugangsregeln werden durch die neue App nicht ersetzt.


## Personen, Rollen und Login-Verknüpfungen

Neue Konten geben einen Namen zur Zuordnung an. Bei E-Mail/Passwort steht das Pflichtfeld im Registrierungsformular, bei Google auf der Seite vor der Freigabe. Der Hinweis erklärt, dass dieser Name nur zur Kontozuordnung dient. Die Theaterleitung sieht ihn neben der Login-Adresse. Vor der Freigabe kann die Person ihn korrigieren; eine Korrektur macht bereits geöffnete Freigabeanfragen ungültig. Nach der Verknüpfung verwendet die App den Namen der Ensembleperson. Fehlt der selbst angegebene Name (typisch bei Google), kann die Theaterleitung das Konto trotzdem verknüpfen und freigeben; die Freigabeansicht zeigt dann den Namen laut Anmeldekonto mit dem Hinweis, die Zuordnung anhand der E-Mail-Adresse zu prüfen. Die Push-Nachricht „Neue Registrierung“ kommt einmal pro Konto, sobald die Identität bestätigt ist, auch ohne angegebenen Namen.

Unter „Admin → Zugänge & Rechte“ steht jede Person in einer Liste, auch ohne Login, gefolgt von Konten ohne Person (offene, unbestätigte und abgelehnte Registrierungen). Die E-Mail-Adresse gehört zum tatsächlich verknüpften Firebase-Konto. Eine gesperrte oder inaktive Person bleibt als verknüpft erkennbar; Kontostatus und „Person inaktiv“ stehen getrennt daneben. Mehrere Theaterrollen hängen an derselben Person. Filter nach Status, Rechten (Admin, Termine verwalten, Regie, nur Mitglied) und Rollen; die Zusammenfassung oben setzt den passenden Filter. „Drehbuchrollen“ zeigt die Besetzung je Produktion. Die Suche berücksichtigt Namen, Login-Adressen, Rollen und Produktionen. „Rechte bearbeiten…“ im Menü einer Zeile ändert Admin-Rolle und Rechte an einer Stelle und braucht eine Verbindung.

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

## Ensemble-Profile und Website-Abgleich

„Unser Ensemble“ öffnet zu jeder Person eine kurze Profilseite: eigenes Profilbild (sonst die Initialen), Aufgabenrollen, ein selbst geschriebener „Über mich“-Text (bis 600 Zeichen), die aktuelle Rolle, „Dabei seit“, alle Rollen je Stück und die Aufgaben hinter den Kulissen. Website-Rollen und Besetzungen der App werden pro Stück zu einem Eintrag zusammengeführt. Kontaktdaten, Rückmeldungen und Anwesenheiten erscheinen dort nicht. Unter „Profil bearbeiten“ schreibt jede Person ihren Text und kann die Website-Angaben in der App ausblenden; dann liefert der Server ihre Website-Rollen nicht aus.

Quelle ist die öffentliche Teamseite <https://kolpingtheater-ramsen.de/team>. Die Website rendert sie aus `src/data/team.json` des öffentlichen Repositorys `Kolpingtheater-Ramsen/next-theater`; der Abgleich liest diese Datei über `raw.githubusercontent.com` und übernimmt nur Profile, die auf der Live-Teamseite verlinkt sind. Fotos der Website werden bewusst nicht übernommen: Ohne eigenes Profilbild zeigt die App die Initialen. Der Server liefert Medien der Art `website` aus früheren Abgleichen nicht mehr aus, und `--apply` entfernt sie samt Datei aus `/data/media`. Selbst hochgeladene Profilbilder bleiben unberührt.

Der Abgleich läuft nicht automatisch. Nach Änderungen an der Website im Container zuerst den Probelauf, dann die Übernahme starten:

```sh
docker exec <container> node scripts/import-website-team.mjs /data/theater.sqlite
docker exec <container> node scripts/import-website-team.mjs /data/theater.sqlite --apply
```

Der Probelauf schreibt nichts; `photosToRemove` nennt noch vorhandene Website-Fotos früherer Abgleiche. Er listet zugeordnete, unsichere und nicht gefundene Profile sowie die erkannten Stücke. Zugeordnet wird nur eindeutig: gleicher Name ohne Widerspruch, ein Namenszusatz im Website-Kürzel („LinaK“ → „Lina K.“, „julian-technik“ → „Julian (Technik)“) oder ein Vorname, den die aktuelle Rolle, eine Aufgabe oder eine Besetzung in einem verknüpften Stück bestätigt. Widerspricht eine Besetzung der Website-Rolle, bleibt das Profil unverknüpft. Stücke werden über den Titel verknüpft („Sommerstück 2026 (Creepshow)“ → „Creepshow“) oder über die Besetzung, wenn mindestens drei bereits zugeordnete Personen dieselben Rollen spielen („Sommerstück 2025“ → „Anno 1146“). Unsichere Profile ordnet die Theaterleitung unter „Personen → Person bearbeiten → Website-Profil“ zu; solche Zuordnungen und ein bewusstes „Kein Website-Profil“ bleiben bei späteren Abgleichen erhalten. Profile, die von der Website verschwinden, werden entfernt. Für Tests oder ohne Netz lassen sich mit `--team team.json --team-page team.html` lokale Kopien einlesen.

## Original-Logo

Quelle: https://kolpingtheater-ramsen.de/presse, Originaldatei https://kolpingtheater-ramsen.de/img/logo.png. `assets/brand/kolpingtheater-ramsen.png` bleibt unverändert (SHA-256 `c22912bb9397371f959f23fd9caf75880be49ec2e639b1b2c81508c0a9626fab`). `node tool/brand-icons.mjs` erzeugt daraus lediglich passend skalierte Plattformicons auf weißen Flächen. Anmeldung, App-Kopf, Infoansicht und Plattformicons verwenden dieses Logo.

## Termine, Rollen und Abstimmungen (0.4.0)

Die Administration ist als eigener Navigationseintrag sichtbar. Auf breiten Bildschirmen steht die Navigation links; Formulare und Texte bleiben in einer begrenzten Lesebreite. Der Monatskalender zeigt am Desktop auch Termintitel.

Termine haben eine Beschreibung (bis 5.000 Zeichen), die auch in die Kalenderdatei übernommen wird. Zur Auswahl stehen Probe, Leseprobe, Technikprobe, Kostümprobe, Generalprobe, Aufführung, Besprechung, Workshop, Aufbau, Abbau, Feier / Ausflug und Sonstiges.

Unter „Administration → Rollen verwalten“ lassen sich Ensemble-Rollen anlegen und umbenennen. Jede Person kann mehrere davon haben; die Zuordnung erfolgt beim Bearbeiten der Person. Eine verwendete Rolle lässt sich erst nach dem Entfernen ihrer Zuordnungen löschen. Diese Aufgabenrollen ändern keine Kontoberechtigungen. Rollen im Drehbuch und Besetzungen bleiben mit der jeweiligen Produktion verbunden.

Allgemeine Abstimmungen stehen unter „Mein Bereich → Abstimmungen“ und in der Administration. Admins legen Frage, Beschreibung, zwei bis zwölf Antworten, die Abstimmungsart und optional ein Enddatum mit Uhrzeit fest. Anonyme Abstimmungen zeigen nur Stimmenzahlen; namentliche zeigen allen freigegebenen Mitgliedern die Namen bei der gewählten Antwort. Bestehende Abstimmungen bleiben anonym. Nach der ersten Stimme bleiben die Abstimmungsart und die Antworttexte erhalten. Jede Person hat eine veränderbare Stimme. Mit Erreichen der Frist endet die Abstimmung automatisch, auch wenn eine verspätete Stimme aus der Offline-Warteschlange ankommt. Admins können beenden und wieder öffnen; beim Wiederöffnen wird eine abgelaufene Frist entfernt. Terminabstimmungen werden nicht erzeugt.

Beim ersten Öffnen nach der Freigabe fragt die App nach Benachrichtigungen. Im Browser erscheint zuerst ein kurzer Dialog, dessen „Erlauben“-Schaltfläche die Browserberechtigung anfordert. Eine bestehende Ablehnung oder ausdrücklich deaktivierte Push-Einstellung wird respektiert. Ein neuer Versuch ist in den Erinnerungseinstellungen möglich.

Immich-Cover verwenden das explizite Album-Titelbild in Preview-Auflösung. Ist kein passendes Titelbild verfügbar, wird ein Foto des Albums verwendet. `tool/version-web.mjs` bricht das Deployment ab, wenn die Web-Implementierung des Bildpickers im kompilierten JavaScript fehlt. Nach Änderungen an Flutter-Plugins einen sauberen Webbuild erzeugen; Web- und Android-Builds nacheinander ausführen.

## E-Mail-Versand mit Resend

Die Theater-App verwendet den Absender `Kolpingtheater Ramsen <app-noreply@kolpingtheater-ramsen.de>` und Antworten gehen an `kolpingtheaterramsen@gmail.com`. Der eigene Resend-Schlüssel darf ausschließlich über die verifizierte Domain `kolpingtheater-ramsen.de` versenden. Er liegt auf HomeBox unter `/home/logge/projects/theater-app/secrets/resend-api-key`, Dateimodus 600, und wird im Container nur lesbar nach `/run/secrets/resend-api-key` eingebunden. `config/dokploy.json` enthält ausschließlich öffentliche Einstellungen. `email.enabled` schaltet den Versand im Deployment ein.

Firebase Authentication nutzt Resend als SMTP-Relay (`smtp.resend.com`, Port 465, SSL) für Bestätigung, Passwort-Zurücksetzen und Adressänderungen. `server/scripts/firebase-email-configure.mjs` richtet dies mit Firebase-Server-Credentials und `RESEND_API_KEY_FILE` ein, ohne Mitglieder anzulegen oder E-Mails zu senden. Die bisherige Benachrichtigungskonfiguration wird ohne Kennwörter unter `artifacts/resend-2026-10-10/` gesichert. Änderungen greifen auch für bereits installierte Clients, weil diese weiterhin den Firebase-Versand anfordern.

Unter „Mein Bereich → Darstellung & Erinnerungen → Termin-E-Mails“ aktiviert jedes Mitglied selbst den zusätzlichen E-Mail-Kanal. Er verwendet dieselben Vorlaufzeiten und den Schalter für Terminänderungen wie Push. Neue Termine, Änderungen, entfernte Termine und Erinnerungen werden nur an aktuell berechtigte, aktive Mitglieder mit bestätigter Anmeldeadresse und passender Einladung gesendet. Abgesagte Teilnehmer bekommen keine Erinnerungs-E-Mail. „Test-E-Mail an mich senden“ adressiert ausschließlich das eigene Konto.

Die dauerhafte Warteschlange `emailJobs` liegt in der bestehenden SQLite-Datenbank. Akzeptierte Empfänger werden bei Wiederholungen übersprungen; derselbe Versuch verwendet denselben Inhalt und Resend-Idempotenzschlüssel. Veraltete Terminversionen und Jobs älter als 23 Stunden werden nicht nachgesendet. Versandprotokolle werden nach 30 Tagen gelöscht. `GET /api/mobile/v1/admin/email/` zeigt der Theaterleitung den Zustand. `accepted_by_provider` bestätigt die Annahme bei Resend, keine Zustellung im persönlichen Postfach.
