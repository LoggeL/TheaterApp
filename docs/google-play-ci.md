# Google Play aus GitHub Actions

Der Workflow `.github/workflows/checks.yml` veröffentlicht nach einem erfolgreichen Prüfjob jeden Push auf `main` im internen Google-Play-Test. Pull Requests bekommen keine Release-Credentials und veröffentlichen nichts. Ein manueller Workflow-Start auf `main` veröffentlicht ebenfalls.

Die sichtbare Versionsnummer kommt aus `pubspec.yaml`. Der Android-Versionscode ist mindestens der dort eingetragene Code und immer höher als die bereits zu Google Play hochgeladenen Bundles. Auch ein erneut gestarteter Workflow erhält dadurch einen neuen Code. Play-Veröffentlichungen laufen nacheinander; ein inzwischen überholter Commit wird vor dem Build übersprungen.

## GitHub-Secrets

- `ANDROID_UPLOAD_KEYSTORE_BASE64`: Base64 des bestehenden Upload-Keystores.
- `ANDROID_SIGNING_JSON`: JSON mit `storePassword`, `keyPassword` und `keyAlias`.
- `PLAY_SERVICE_ACCOUNT_JSON`: Schlüssel eines eigenen Google-Play-CI-Servicekontos. Dieses Konto braucht in Play Console nur Zugriff auf die Theater-App, Leserechte und das Recht, Releases in Test-Tracks zu veröffentlichen. Keine Produktions-, Finanz- oder Nutzerverwaltungsrechte vergeben.

Die Google Play Android Developer API muss im Google-Cloud-Projekt aktiviert sein. Das CI-Konto braucht keine Firebase-Administratorrolle. Schlüsseldateien werden nur im temporären Runner-Verzeichnis angelegt und am Ende entfernt. Das Build-Artefakt enthält das signierte Bundle und einen Release-Nachweis, keine Schlüssel.

## Prüfung und Verwendung

Der Release-Job lädt das AAB hoch, validiert die Änderung, veröffentlicht im Track `internal` und liest anschließend den Track in einer neuen API-Transaktion zurück. Ein grüner Release-Job belegt, dass Google den Versionscode als veröffentlicht zurückgegeben hat. Die tatsächliche Installation auf einem Gerät und die zeitverzögerte Store-Verteilung sind separate Prüfungen.

Testlink: https://play.google.com/apps/internaltest/4701275968106617341

Tester müssen in der ausgewählten Play-Console-Liste stehen und den Testbeitritt annehmen. Geräte mit aktivierten Play-Auto-Updates erhalten veröffentlichte Versionen nach der Verteilung durch Google. Der Workflow veröffentlicht nicht in Produktion.

Der Workflow und `server/scripts/play-release.mjs` sind vertrauenswürdiger Release-Code: Änderungen daran auf `main` können auf die Release-Secrets zugreifen. Private Schlüssel niemals committen oder in Logs ausgeben.
