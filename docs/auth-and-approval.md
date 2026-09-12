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

## Server, lokale Daten und Migration

Der Client übergibt sein Firebase-ID-Token über HTTPS. Das Backend prüft es mit dem Firebase Admin SDK einschließlich Widerrufsprüfung und liest anschließend den aktuellen Freigabe-, Personen- und Berechtigungsstand aus der eigenen Datenbank. Eine vom Client gesendete Personen-ID oder Rolle ist keine Berechtigung. [Firebase: Verify ID tokens](https://firebase.google.com/docs/auth/admin/verify-id-tokens)

Custom Claims können Rollen zusätzlich abbilden. Sie ersetzen die aktuelle Freigabeprüfung nicht: geänderte Claims erscheinen erst in einem neu ausgestellten Token. Ein serverseitig gesperrtes Konto muss auch mit einem alten gültigen Token am nächsten geschützten Zugriff scheitern. [Firebase: Custom claims](https://firebase.google.com/docs/auth/admin/custom-claims)

Vor Freigabe werden keine internen Inhalte zwischengespeichert. Cache und Offline-Warteschlange sind kontogebunden; Abmeldung und Kontowechsel entfernen den Zugriff auf Inhalte des vorigen Kontos. Die App überträgt keine vorgemerkte Änderung unter einer anderen Identität. Eine während vollständiger Offline-Nutzung ausgesprochene Sperrung kann das Gerät erst beim nächsten Kontakt erkennen; bereits heruntergeladene Inhalte lassen sich nicht aus der Ferne sofort zurückholen.

Das Referenzpaket verwendet bisher eine eigene Anmeldung und enthält Firebase Messaging. Die Anmeldemaske mit dem Hinweis auf durch die Verwaltung angelegte Konten wird durch Selbstregistrierung ersetzt. Die vorhandenen Personen-IDs und fachlichen Daten bleiben erhalten. Die Migration muss alte Mobile- und Web-Zugänge auf dieselbe Freigabeprüfung umstellen oder gezielt außer Betrieb nehmen. Passwörter werden nicht pauschal aus dem Altsystem übernommen; der konkrete Übergang wird anhand des vorhandenen Bestands festgelegt.

## Prüfung bei der Implementierung

Die durchgängigen Fälle stehen in [requirements.md](requirements.md#durchgängige-abnahmefälle). Zusätzlich werden E-Mail-Bestätigung und Wiederherstellung, abgebrochene Social Logins, Provider-Konflikte, doppelte Freigabeversuche, Sperrung bei bestehender Sitzung und Kontowechsel geprüft. Firebase Auth ist bisher weder eingerichtet noch mit Android-/iOS-Anmeldungen abgenommen.
