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
