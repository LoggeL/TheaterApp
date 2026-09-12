# Anforderungen und Abgleich

Stand: 12. September 2026. Grundlage sind der aktuelle Nutzerauftrag, das Downloads-Paket, der frühere Gesamtplan und die aktuelle Skript-Oberfläche. Die Tabellen beschreiben den gelesenen Quellstand und beobachtete Oberflächen. Sie sind keine Abnahme des Gesamtprodukts.

## Verbindliche Richtung aus diesem Auftrag

- Eine gemeinsame Theater-App soll den Bedarf des Vereins abdecken.
- Flutter ist die technische Grundlage. Die PWA-/Capacitor-Empfehlung im früheren Plan ist dadurch für den neuen Client überholt.
- Die Samples im ZIP sind die visuelle Ausgangsbasis. Das Drehbuch soll näher an das bestehende System rücken.
- Zunächst werden Anforderungen abgeglichen und mit Imagegen mehrere Ansichten entworfen. Ergänzend gewünscht sind Zu-/Absage und mehrere Admin-Ansichten.
- Der Leser soll deutlich minimalistischer werden: fortlaufender Dialog, schlichte kursive Anweisungen und weniger dauerhafte Leisten/Kategorieüberschriften. Notizen, Kommentarzugriff und Lesezeichen bleiben erhalten.
- „Komme später“ gehört zur Rückmeldung für einen bereits festgelegten Termin. Die Entwürfe bieten dazu eine optionale voraussichtliche Ankunftszeit. Terminabstimmungen sind ausdrücklich nicht im Umfang.
- Konten können selbst erstellt werden, über E-Mail/Passwort und mehrere Social Logins mit Firebase Auth. Erst ein Admin verknüpft das Konto mit einer Person und gibt den Theaterzugang frei.

„Kompletter Theaterbedarf“ ist das Produktziel. Die bereits konkret beschriebenen Funktionen stehen unten. Die genaue Ausgestaltung weiterer Vereinsbereiche bleibt ein Vorschlag, solange dazu kein konkreter Ablauf vorliegt.

## Quellen

| Quelle | Verwendung | Grenze |
| --- | --- | --- |
| `Rampenlicht-Flutter-Paket.zip`, unverändert unter `reference/rampenlicht` | Flutter-Code, vier Screenshots, Architektur, Backend-Erweiterung | Frühere Testberichte sind keine hier wiederholten Tests |
| `skript/docs/theater-app.md`, Kopie unter `reference` | Zusammenführung, Offline-Regeln, Mitteilungen, Verwaltung, Abnahmefall | Frühere technische Empfehlung durch Flutter-Vorgabe ersetzt |
| [skript.logge.top](https://skript.logge.top/) | Live sichtbare Navigation, Szenenübersicht, Rollenwahl, Filter, Lernmodus und Einstellungen | Keine Mehrgeräteprüfung der Regie, kein produktiver Schreibzugriff |
| Lokales Projekt `skript` | Filter-Voreinstellungen und bestehende Funktionen | HEAD `572bb718d634cbebdbfc86025cc1f876e5a2791f`, zusätzlich lokale Änderungen; entspricht nicht zwangsläufig exakt dem Deploy |
| Originalpaket `docs/REMOTE_AUDIT_SKRIPT.md` | Frühere Integrationsannahmen | Referenziert einen anderen Commit (`3e84c698...`); keine aktuelle Kompatibilitätsgarantie |

## Gesamtumfang

„Vorhanden“ bedeutet hier im Sample-Code gefunden, nicht mit produktiven Daten abgenommen.

| Bereich | Benötigtes Verhalten | Stand im Flutter-Sample / Konsequenz |
| --- | --- | --- |
| Gemeinsame Anmeldung | Selbstregistrierung mit Firebase Auth, mehrere Anmeldearten, anschließende Personenzuordnung und Freigabe durch Admin | Sample verwendet bisher eigene Anmeldung; Firebase Messaging ist kein Firebase Auth. Anmeldung, Freigabe und Backend-Prüfung müssen umgestellt werden |
| Heute | Nächste Probe, offene Rückmeldungen, aktueller Hinweis und direkt ins passende Drehbuch | Probe, Rückmeldungen und Drehbuch vorhanden; dauerhaftes Mitteilungspostfach fehlt |
| Termine | Proben/Aufführungen, Details, dabei/später/Absage, optionale Ankunftszeit, freiwilliger Absagegrund, Rücknahme | Zu-/Absage vorhanden; eigener Später-Status und Ankunftszeit sind zu ergänzen |
| Abwesenheiten | Längere Abwesenheit angeben und in der Planung berücksichtigen | Aus dem bisherigen Gesamtplan; Fristen und Konflikte müssen auch nach Offline-Übertragung gelten |
| Kalender | Termine an den Systemkalender übergeben | ICS-Export vorhanden; native Dialoge auf Geräten prüfen |
| Anwesenheit | Konkreten Termin wählen; unbekannt, anwesend und abwesend unterscheiden | Check-in-Oberfläche vorhanden; Zusage und tatsächliche Anwesenheit bleiben getrennt |
| Probenplanung | Szenen aus Besetzung und tatsächlich erfasster Anwesenheit bestimmen | Produktion/Szenen einer Probe zuordnen vorhanden; berechnete spielbare Szenen nicht als fertige Funktion enthalten |
| Produktionen | Mehrere Stücke, Fassung, Szenen, Besetzung, gezielter Download | Liste, Leser und Cache vorhanden; vollständige Pflege erfolgt noch nicht in der App |
| Drehbuch | Bestehende Abläufe erhalten, siehe Detailtabelle | Gute Basis mit mehreren relevanten Funktionslücken |
| Mitteilungen | Leitung schreibt an alle oder eine erlaubte Gruppe/Produktion; Nachricht bleibt im Postfach | Kein durchgängiger Postfach-/Versandablauf im Client gefunden |
| Push | Hinweise und Erinnerungen mit passenden Deep Links | Registrierung, Empfang und Worker vorbereitet; echte Einrichtung und Zustellung fehlen laut Paket |
| Ensemble | Mitglieder finden und Besetzungen mit Personen verknüpfen | Mitgliederliste vorhanden; persönliche Leseauswahl ist keine verbindliche Besetzungsverwaltung |
| Verwaltung | Neue Konten einer Person zuordnen und freigeben; Mitglieder, Rechte, Produktionen, Besetzungen und Termine pflegen | Paket belässt wesentliche Verwaltungsabläufe im bisherigen Websystem; Freigabeprozess und vollständige mobile Verwaltung noch umzusetzen |
| Offline | Gespeicherte Inhalte lesen; erlaubte Änderungen sicher vormerken; Übertragung sichtbar | SQLite-Cache und Warteschlange vorhanden; reale Neustarts, Kontowechsel und Konflikte abnehmen |
| Darstellung | Hell/Dunkel/System, gut lesbare Schrift, Handy/Tablet, große Touchflächen | Theme und Schriftgrößen vorhanden; adaptives Tablet-Layout als Entwurf |

## Drehbuch: Nähe zum bestehenden System

| Funktion | Bestehendes Skript | Flutter-Sample | Anforderung an den neuen Leser |
| --- | --- | --- | --- |
| Rollenwahl | Personenweise Gruppen, auch mehrere Rollen pro Person | Einzelne Rolle mit Darstelleruntertitel | „Meine Rollen“ übernimmt alle zugeordneten Rollen; einzelne Rollen zusätzlich auswählbar |
| Dialog | Rollennamen, fortlaufender Text und eigene Hervorhebung | Eigene Rolle markiert, relativ großzügige Hinweisflächen | Fortlaufender Dialog; eigene Rolle über Rollenname und schmalen Randstrich erkennbar. Keine wiederholten „Dein Text“-Labels oder großen Farbflächen |
| Szenen | Inhaltsverzeichnis, Zusammenfassung, Besetzung, auch Szene `10.5` | Szenenliste und Rollen vorhanden | Szene direkt erreichbar; Originalbezeichnung und Reihenfolge erhalten, Besetzung einklappbar |
| Eigene Texte | Eigene Einsätze und Schnellnavigation | Modus „Mein Text“ mit Kontext | Als Filter erhalten; vorheriger/nächster eigener Einsatz direkt erreichbar |
| Text lernen | „Texte der gewählten Rolle verdecken“ im Schnellstart und in Einstellungen | Kein Verdecken/Aufdecken im gelesenen Leserpfad | Eigene Texte verdecken; einzeln aufdecken; erneut verbergen, ohne den Dialogpartnertext zu verlieren |
| Persönliche Notizen | Lokale Notizen, ausdrücklich ohne Synchronisierung | Lesezeichen, aber keine persönliche Textnotiz im Cue-Menü | Notiz an Textstelle, offline, privat; Lesezeichen bleiben eine eigene Funktion |
| Kategorien | Anweisung, Technik, Licht, Audio, Requisiten, manuelle/automatische Mikrofon-Cues getrennt | Ein Schalter für Regie und ein Sammelschalter für technische Einsätze | Kategorien einzeln steuerbar; sinnvolle Voreinstellungen für Schauspiel, Lesen, Lernen, Technik. Standardleser ohne wiederholte Kategorieüberschriften; Anweisungen kursiv im Text, Technik auf Wunsch |
| Kontext | Kontextzeilen je Kategorie | Eine Kontextzahl für eigene Texte | Kategorie-Kontext erhalten; Szenengrenzen und Reihenfolge müssen stimmen |
| Technik | Vollständiger Text und alle Cues in Technik-Voreinstellung | Technikmodus filtert Dialog aus | Volltext mit Cues und reine Cue-Liste ausdrücklich unterscheiden |
| Mikrofone | Nummern, manuelle und automatische Hinweise | Importierte Mikrofon-Cues vorhanden | Herkunft erkennbar; Ein/Aus ist ein Drehbuchhinweis, keine Messung am Funkmikrofon |
| Regie | Marker, Sprung zum Marker, wählbares Folgen, Übergabe | Eigener authentifizierter App-Fokus | Gemeinsame Browser-/App-Sitzung herstellen; verbunden, folgend und leitend getrennt anzeigen |
| Bühnenmonitor | Eigene Bühnen-/Schauspieleransichten, aktuelle/nächste Inhalte | Dunkler Bühnenmodus im Leser | Auf großen Flächen aktuelle/nächste Cues und Besetzung gezielt darstellen |
| Suche/Lesezeichen | Navigation und lokale Arbeitsfunktionen | Suche, Lesezeichen und Leseposition vorhanden | Beibehalten; nach Fassungswechsel verwaiste Verweise sichtbar behandeln |
| Fassungen | Quelle, Cache und Updatehinweis | Revisionen und Offline-Cache vorhanden | Eine Probe darf nicht unbemerkt auf eine andere Fassung springen |
| Drucken | Browserdruck | Nativer PDF-Export vorhanden | Bewusst auswählen, ob Volltext oder gefilterte Fassung gedruckt wird |
| Farbschema | Hell, Dunkel und Pink sichtbar | Hell/Dunkel/System | Hell/Dunkel als Entwurfsbasis; Pink als zusätzliche persönliche Option mitführen |

Die zentralen Belege im Sample liegen in `lib/ui/reader.dart`: `visibleScriptCues`, `_buildToolbar`, `_showRoles`, `_showSettings`, `_showCueActions` und `_exportPdf`. Im bestehenden Projekt ist `static/js/filter-presets.js` die Quelle für Schauspiel-, Lern-, Technik- und Lese-Voreinstellungen.

## Funktionen für den weiteren Vereinsbedarf

Der frühere Plan nennt Requisiten, Aufgaben, Kostüme und Dokumente als Erweiterung. Daraus ergibt sich folgende vorgeschlagene Fortsetzung, noch ohne behauptete Vollständigkeit:

| Bereich | Konkreter Einstieg |
| --- | --- |
| Requisiten | Gegenstand, Lagerort, Foto, Zustand, Zuständigkeit und Szenenbezug |
| Kostüme | Zuordnung zu Produktion/Rolle, Größen, Änderungen und Rückgabe |
| Aufgaben | Zuständigkeit, Termin, Status; aus Probe oder Szene anlegen |
| Dokumente | Freigegebene Fassungen, Pläne und technische Unterlagen pro Produktion |
| Aufführungsbetrieb | Ablauf, Aufbau/Abbau, Helferdienste und Show-Checklisten |

Ticketverkauf, Kasse/Buchhaltung und ein eigener Chat sind noch keine spezifizierten Teilprojekte. Für eine vollständige Bedarfserhebung müssen bestehende Werkzeuge und die gewünschten Abläufe dieser Bereiche erfasst werden.

## Späterkommen

Die Rückmeldung hat vier klar unterscheidbare Zustände: offen, dabei, komme später und abgesagt. „Offen“ bleibt der Zustand ohne Antwort. Bei „Komme später“ kann eine voraussichtliche Ankunft angegeben werden, beispielsweise 19:30 Uhr zu einer Probe um 19:00 Uhr. Die Uhrzeit ist eine Entwurfsentscheidung und freiwillig; ohne Angabe erscheint „Später · Uhrzeit offen“.

Die Antwort bezieht sich ausschließlich auf einen bereits festgelegten Termin. Die Leitung legt Proben an; Mitglieder melden dabei, später oder abgesagt zurück. Der zuvor gezeigte Entwurf einer Terminabstimmung ist zurückgezogen.

Die Probenleitung sieht Späterkommende separat mit ihrer geplanten Ankunft. Summen verwenden überschneidungsfreie Kategorien; niemand wird gleichzeitig als dabei und später gezählt. In der Planung anhand von Zusagen ist die Person frühestens ab ihrer erwarteten Ankunft eingeplant. Eine offene Ankunftszeit macht diese Verfügbarkeit ungeklärt.

Die tatsächliche Anwesenheit wird weiterhin gesondert erfasst. Das Erreichen von 19:30 Uhr setzt einen angekündigten Späterkommenden nicht automatisch auf „da“. Ein vorhandener Check-in hat für die Planung anhand von Anwesenheit Vorrang.

Zeit und Rückmeldung lassen sich innerhalb der geltenden Frist ändern oder zurücknehmen. Beim Wechsel auf dabei, abgesagt oder offen wird eine alte Ankunftszeit entfernt. Abbrechen verwirft nur die aktuelle Bearbeitung. Offline werden Status und Zeit zusammen vorgemerkt; „gespeichert“ setzt weiterhin eine Serverbestätigung voraus.

## Registrierung und Freigabe

Firebase Auth übernimmt die Anmeldung. Als Anmeldearten sind E-Mail/Passwort sowie Google, Apple, Microsoft, Facebook und GitHub vorgesehen; weitere unterstützte Anbieter können ergänzt werden. Auf dem Einstieg stehen E-Mail, Google und Apple, die übrigen Anbieter unter „Weitere Anmeldearten“. Sichtbar sind nur tatsächlich eingerichtete Anbieter. Firebase dokumentiert die Anbieter und ihre jeweilige Plattformkonfiguration. [Firebase: Social Sign-in](https://firebase.google.com/docs/auth/flutter/federated-auth)

Jedes neue Konto startet ohne Personenzuordnung im Zustand „Freigabe ausstehend“. Es darf nur den eigenen Kontostatus sehen und die eigenen Anmeldedaten verwalten. Ensemble, Termine, Drehbücher und interne Mitteilungen werden erst nach Freigabe zugänglich. E-Mail-Bestätigung allein erteilt keine Theaterberechtigung.

Ein Admin öffnet die Liste neuer Konten, wählt eine vorhandene Person und führt „Verknüpfen & freigeben“ aus. Fehlt die Person, kann sie im Verwaltungsablauf angelegt werden. Name und E-Mail helfen bei der Prüfung, lösen jedoch keine automatische Zuordnung aus. Die Freigabe erteilt zunächst Mitgliedszugriff; Verwaltungsrechte werden ausdrücklich vergeben. Ablehnung und spätere Sperrung sind eigene Zustände.

Mehrere Anmeldearten sollen zu demselben Konto hinzugefügt werden können, ohne Personen, Besetzungen oder Rückmeldungen zu duplizieren. Bestehende Personen bleiben auch ohne Login verwaltbar. Zuordnung und Freigabe werden auf dem Server geprüft. Details und Konfliktregeln stehen in [Anmeldung und Freigabe](auth-and-approval.md).

## Durchgängige Abnahmefälle

1. Mitglied öffnet die nächste Probe, sagt zu und gelangt mit einem Tippen zur verknüpften Szene. Die angezeigte Rolle passt zur gewählten Produktion.
2. Ein Darsteller mit mehreren Rollen sieht alle eigenen Einsätze. Im Lernmodus bleiben die Stichworte anderer Rollen lesbar; eigene Texte lassen sich einzeln aufdecken.
3. Gespeichertes Drehbuch, Notizen und Leseposition bleiben nach App-Neustart im Flugmodus verfügbar. Eine neue Fassung ordnet keine Notiz still einer falschen Stelle zu.
4. Leitung erfasst Anwesenheit für eine konkret gewählte Probe. Unbekannt wird nicht als anwesend gezählt. Spielbare Szenen beruhen auf tatsächlicher Besetzung und Check-ins.
5. Offline geänderte Rückmeldungen und Check-ins werden genau einmal übertragen. Widersprüche und Ablehnungen bleiben sichtbar.
6. Eine Regiemarkierung erreicht Browser, Handy und Tablet derselben Produktion/Fassung. Folgen lässt sich aussetzen; ein erneutes Verbinden stellt Marker oder gelöschten Marker korrekt her.
7. Eine Mitteilung bleibt im Postfach. Push öffnet das passende Objekt; angenommener Push wird nicht als gelesen dargestellt.
8. Leser funktioniert bei großer Systemschrift, auf einem schmalen Handy und im Tablet-Querformat. Szenenauswahl und eigener nächster Einsatz bleiben erreichbar.
9. „Komme später, 19:30“ erscheint bei der betreffenden Probe und in der Leitungsübersicht. Eine Änderung auf „Bin dabei“ entfernt die Ankunftszeit; Rücknahme setzt auf offen.
10. Späterkommende werden in Rückmeldesummen genau einmal gezählt und beim Erreichen der erwarteten Uhrzeit nicht automatisch eingecheckt. Offline-Übertragung bewahrt Status und Zeit gemeinsam.
11. Selbstregistrierung über jede eingerichtete Anmeldeart führt zum Wartestatus. Auch direkte API-Aufrufe liefern vor Freigabe keine internen Theaterdaten.
12. Admin ordnet das Konto einer Person zu und gibt es frei. Nach Aktualisieren des Status sieht das Mitglied seine bestehenden Rollen und Termine. Ein bereits angemeldetes Konto kann sich nicht selbst freigeben.
13. Zwei gleichzeitige Freigaben auf dieselbe Person erzeugen keine doppelte Verknüpfung. Fehler lassen weder eine halbe Zuordnung noch eine unberechtigte Freigabe zurück.
14. Eine zusätzliche Anmeldeart führt nach erfolgreicher Kontoverknüpfung zum selben Konto, denselben Rollen und denselben Rückmeldungen. Bereits anderweitig gebundene Zugangsdaten werden nicht still zusammengeführt.
15. Eine Sperrung verhindert den nächsten geschützten Serverzugriff auch bei noch gültigem Firebase-Token. Ein Kontowechsel zeigt keine lokalen Inhalte des vorigen Kontos.

Diese Fälle sind die Arbeitsgrundlage für die Implementierung. In dieser Sichtung wurden sie nicht als Gesamtkette ausgeführt.
