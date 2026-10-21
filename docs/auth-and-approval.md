# Anmeldung und Freigabe

Stand: 12. September 2026. Verbindliche Produktentscheidung: Selbstregistrierung mit Firebase Auth; eine Personenzuordnung und Freigabe durch einen Admin sind Voraussetzung für den Theaterzugang. Die folgenden Abläufe und Datenfelder sind der Umsetzungsvertrag, noch keine implementierte Funktion.

## Anmeldearten

E-Mail/Passwort, Google, Apple, Microsoft, Facebook und GitHub bilden die geplante Auswahl. Google, Apple und E-Mail sind direkt erreichbar; „Weitere Anmeldearten“ öffnet die übrigen eingerichteten Anbieter. X/Twitter und Yahoo sind mögliche Ergänzungen. Jeder Anbieter benötigt seine eigene Firebase- und Plattformkonfiguration. Die Anzeige folgt der tatsächlich eingerichteten Auswahl. [Firebase: Federated identity and social sign-in](https://firebase.google.com/docs/auth/flutter/federated-auth)

E-Mail/Passwort erhält E-Mail-Bestätigung, erneuten Versand und „Passwort vergessen“. Bestätigung und Theaterfreigabe sind getrennte Voraussetzungen. Social Logins verwenden die vom Anbieter bestätigte Identität. Eine fehlende oder verborgene E-Mail, etwa bei Apple, ist keine Grundlage für eine automatische Personenzuordnung. Der Admin sieht, welche Identitätsmerkmale vorliegen; eine Kontaktadresse kann bei Bedarf gesondert bestätigt werden.

Unter „Mein Bereich > Konto > Anmeldearten“ lassen sich weitere Anbieter nach erneuter Authentifizierung mit demselben Konto verbinden. Firebase unterstützt mehrere Zugangsdaten unter einer UID. Zugangsdaten, die bereits einem anderen Konto gehören, erfordern eine ausdrückliche Konfliktbehandlung; E-Mail-Gleichheit allein führt nicht zum Zusammenführen. Die letzte nutzbare Anmeldeart darf nicht ersatzlos entfernt werden. [Firebase: Account linking](https://firebase.google.com/docs/auth/flutter/account-linking)

## Konto und Person

Die Firebase UID bezeichnet das Login-Konto. Die bestehende Personen-ID bezeichnet den Menschen im Ensemble und bleibt Bezug für Rollen, Termine und Anwesenheit. Personen können weiterhin ohne Login existieren.

Vorgeschlagener Backend-Datensatz:

| Feld | Bedeutung |
| --- | --- |
| `firebaseUid` | Eindeutiger Bezug zur geprüften Firebase-Identität |
| `personId` | Vor Freigabe leer, danach ausgewählte bestehende Person |
| `status` | `pending`, `approved`, `rejected` oder `suspended` |
| `permissions` | Mitgliedszugriff sowie ausdrücklich vergebene Verwaltungsrechte |
| `approvedBy`, `approvedAt` | Nachweis der Admin-Freigabe |
| `version` | Erkennen gleichzeitiger Änderungen |

Als Ausgangsregel hat jede Person höchstens ein aktiv zugeordnetes Konto, das mehrere Anmeldearten haben kann. Diese Eindeutigkeit wird in der Datenbank erzwungen. Eine spätere Kontowiederherstellung oder Neuzuordnung läuft über einen gesonderten Admin-Ablauf und übernimmt keine Rechte allein anhand einer E-Mail.

## Ablauf

1. Mitglied registriert sich. Der Server legt für die verifizierte UID genau einmal einen Datensatz mit `pending` an. Wiederholte Aufrufe überschreiben keine bestehende Freigabe oder Sperrung.
2. Bis zur Freigabe sieht das Konto ausschließlich seinen eigenen Wartestatus und seine Kontofunktionen. Es erhält weder Ensemblelisten noch interne Termine, Drehbücher oder Mitteilungen. „Status aktualisieren“ und erneutes Öffnen prüfen den aktuellen Zustand.
3. Admin öffnet „Verwaltung > Neue Konten“. Angezeigt werden Kontoname, vorhandene bestätigte Identitätsmerkmale, Anmeldeart und Registrierungszeit.
4. Admin wählt eine vorhandene Person. Fehlt sie, führt eine Aktion zur Personenanlage. Die App kennzeichnet bereits gebundene Personen und schlägt keine stille Übernahme vor.
5. „Verknüpfen & freigeben“ prüft Adminrecht, aktuellen Status und freie Zuordnung und speichert Person, Berechtigung und Freigabenachweis gemeinsam in einer Transaktion. Bei einem Konflikt bleibt der vorherige Zustand erhalten.
6. Nach bestätigter Freigabe lädt die App die bestehenden Daten der zugeordneten Person. Standard ist Mitgliedszugriff; Adminrechte sind eine ausdrückliche zusätzliche Entscheidung.

Ablehnen setzt `rejected`; eine spätere Sperrung setzt `suspended`. Erneute Registrierung mit derselben UID hebt beides nicht auf. Eine Wiederfreigabe erfolgt ausdrücklich durch einen berechtigten Admin. Der erste Admin wird im vertrauenswürdigen Einrichtungsprozess angelegt; es gibt keine öffentliche Selbstvergabe dieser Rolle.

## Berechtigungen

Die Rolle (`role`: `member` oder `admin`) bleibt die Grundlage. Zusätzlich kann ein Admin einzelnen Mitgliedskonten Rechte geben, gespeichert als `permissions` im Konto (bisher nur `events`, „Termine verwalten“; Feature-Flag `accountPermissions`). Admins haben alle Rechte; `permissions` bleibt bei ihnen leer, das Profil meldet ihnen trotzdem alle Rechte. Unbekannte gespeicherte Werte meldet das Profil nicht.

Das Recht `events` gilt für alle Termine, nicht nur für eingeladene:

- `event.save` und `event.delete` (auch Serien), `event.remindOpen`, `event.script`, `checkin.save`
- Terminfinder: `slotPool.save`, `slotPool.close`, `slotPool.delete`, `slotPool.remindOpen`, `slot.assign`
- `GET /admin/events/:id` (Rückmeldungen mit Absagegründen, Anwesenheit und die Abwesenheiten der Eingeladenen am Termintag; Abwesenheiten anderer Personen liefert der Server auch Admins hier nicht mehr)
- im Snapshot alle Termine und Terminfinder (nicht eingeladene mit „nicht eingeladen“), `memberAttendanceByEvent`, `arrivalsByEvent`, `checkinsByEvent`, `checkinVersions`, `implicitAttendanceByEvent` und die Erinnerungszeitpunkte an Terminen und Terminfindern
- Push „Kurzfristige Absage“ (abschaltbar)

Admin-only bleiben Konten (`account.*`, `/admin/accounts`, Kontolöschung), Personen, Rollen, Produktionen einschließlich `production.scopeEvents`, Drehbuchimport, Mitteilungen, eigene Pushes, Abstimmungen, Feedback, Galerien, Website-Profile, offene Registrierungen, die Teilnahmeübersicht aller Personen sowie die Push-Arten „Neue Registrierungen“ und „Feedback“. Der Admin-Bereich der App bleibt Admins vorbehalten; Inhaber des Rechts erreichen die Terminverwaltung über den Reiter „Termine“.

Vergabe und Rücksetzung:

- `account.permissions` (`{ uid, version, permissions }`, nur Admins): für verknüpfte Konten im Status `approved` oder `suspended`; Admin-Konten lehnt der Server mit `admin_has_all` ab. Die Person erhält bei freigegebenem Konto einen Push beim Erhalten oder Verlieren des Rechts.
- `account.approve` übernimmt optional `permissions`, nur für die Rolle `member`.
- `account.role` zu `admin` leert `permissions`; zu `member` gilt das mitgesendete `permissions` (ältere Apps senden keins, dann bleibt kein Recht).
- `account.status` auf `suspended` behält die Rechte (sie ruhen und gelten nach erneuter Freigabe wieder), auf `rejected` werden sie gelöscht; `account.reconsider` leert sie ebenfalls.

Der Server prüft Rolle und Rechte bei jeder Anfrage aus der eigenen Datenbank; eine Änderung gilt sofort mit der nächsten Anfrage. Vorgemerkte Offline-Änderungen nach einem Entzug scheitern mit `forbidden` und bleiben als fehlgeschlagen sichtbar. Inhaber des Rechts können wie Admins Termine samt Push („Neuer Termin“, Änderungen, Absagen, Terminfinder) an die Eingeladenen auslösen. Deshalb speichert der Server an Terminen und Terminfindern `createdBy` und `updatedBy` (Personen-ID). Die App zeigt allen mit dem Recht unter „Probenleitung“ „Zuletzt geändert von …“; anderen Mitgliedern liefert der Server diese Felder nicht. Zusätzlich hält das Änderungsprotokoll jede Aktion mit ausführendem Konto fest.

## Übersicht „Zugänge & Rechte“

Admins sehen unter „Admin → Zugänge & Rechte“ jede Person mit ihrem Konto (oder „Kein Konto“) und danach die Konten ohne Person. Der Status kommt allein aus dem Konto: „Freigegeben“, „Wartet auf Freigabe“ (`pending` mit bestätigter Identität), „E-Mail unbestätigt“, „Gesperrt“, „Abgelehnt“ oder „Kein Konto“. Unabhängig davon stehen „Person inaktiv“ (der Server verweigert dann den Zugang) und „Konto ohne Person“ (`personId` leer, gleich welcher Status). „Wartet“ zählt wie Hub, Heute und die Registrierungs-Push nur Konten, die sich freigeben lassen.

Die Rechte einer Zeile erscheinen als Pillen: „Admin“, „Termine verwalten“, „Regie: <Stück>“ für nicht archivierte Produktionen (aus `directorMemberIds`, nur Anzeige) oder „Mitglied“. Rolle und Rechte gesperrter Konten sind gedämpft mit „ruht“ markiert, weil sie mit „Wieder freigeben“ wieder gelten. Abgelehnte Konten zeigen keine Rechte: Sie kommen nur über „Erneut prüfen“ als neue Registrierung zurück, die Rolle und Rechte zurücksetzt. Die Zusammenfassung zählt Admins und Rechte nur, wo sie gerade gelten (nicht bei gesperrten Konten oder inaktiven Personen); die Rechte-Filter finden gesperrte Inhaber weiterhin. Filter gibt es nach Status, Rechten und Rollen; die Zusammenfassung oben springt in den passenden Filter.

„Rechte bearbeiten…“ öffnet ein Blatt mit dem Schalter „Admin“ und je einem Kästchen pro Recht. Speichern fragt einmal nach und sendet `account.role` (beim Entziehen mit den behaltenen Rechten), sonst `account.permissions`. Rechteänderungen brauchen eine Verbindung: ohne Verbindung wird nichts vorgemerkt, damit eine zweite Änderung nicht an einer veralteten Version scheitert. Bei gesperrten Konten lassen sich nur die ruhenden Rechte ändern. Die eigene Zeile bietet nur „In Ensemble bearbeiten“. Die Übersicht liest `/admin/accounts` und braucht keine Serveränderung.

## Server, lokale Daten und Migration

Der Client übergibt sein Firebase-ID-Token über HTTPS. Das Backend prüft es mit dem Firebase Admin SDK einschließlich Widerrufsprüfung und liest anschließend den aktuellen Freigabe-, Personen- und Berechtigungsstand aus der eigenen Datenbank. Eine vom Client gesendete Personen-ID oder Rolle ist keine Berechtigung. [Firebase: Verify ID tokens](https://firebase.google.com/docs/auth/admin/verify-id-tokens)

Custom Claims können Rollen zusätzlich abbilden. Sie ersetzen die aktuelle Freigabeprüfung nicht: geänderte Claims erscheinen erst in einem neu ausgestellten Token. Ein serverseitig gesperrtes Konto muss auch mit einem alten gültigen Token am nächsten geschützten Zugriff scheitern. [Firebase: Custom claims](https://firebase.google.com/docs/auth/admin/custom-claims)

Vor Freigabe werden keine internen Inhalte zwischengespeichert. Cache und Offline-Warteschlange sind kontogebunden; Abmeldung und Kontowechsel entfernen den Zugriff auf Inhalte des vorigen Kontos. Die App überträgt keine vorgemerkte Änderung unter einer anderen Identität. Eine während vollständiger Offline-Nutzung ausgesprochene Sperrung kann das Gerät erst beim nächsten Kontakt erkennen; bereits heruntergeladene Inhalte lassen sich nicht aus der Ferne sofort zurückholen.

Das Referenzpaket verwendet bisher eine eigene Anmeldung und enthält Firebase Messaging. Die Anmeldemaske mit dem Hinweis auf durch die Verwaltung angelegte Konten wird durch Selbstregistrierung ersetzt. Die vorhandenen Personen-IDs und fachlichen Daten bleiben erhalten. Die Migration muss alte Mobile- und Web-Zugänge auf dieselbe Freigabeprüfung umstellen oder gezielt außer Betrieb nehmen. Passwörter werden nicht pauschal aus dem Altsystem übernommen; der konkrete Übergang wird anhand des vorhandenen Bestands festgelegt.

## Prüfung bei der Implementierung

Die durchgängigen Fälle stehen in [requirements.md](requirements.md#durchgängige-abnahmefälle). Zusätzlich werden E-Mail-Bestätigung und Wiederherstellung, abgebrochene Social Logins, Provider-Konflikte, doppelte Freigabeversuche, Sperrung bei bestehender Sitzung und Kontowechsel geprüft. Firebase Auth ist bisher weder eingerichtet noch mit Android-/iOS-Anmeldungen abgenommen.
