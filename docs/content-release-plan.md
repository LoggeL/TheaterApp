# Geplante Bühnen und Skinpacks

Stand: 27. Oktober 2026. Alle Uhrzeiten gelten für Europe/Berlin. Die ersten drei Termine wurden vom Nutzer bestätigt. Romeo und Julia folgt nach der letzten Aufführung am 29. Dezember 2026, 21:30 Uhr; dieser Termin wurde am 27. Oktober aus der laufenden Theater-Datenbank zurückgelesen.

Die Freischaltung erfolgt im Server anhand seiner Uhr. Der Mac muss dafür nicht laufen. Neue Figuren eines Packs werden erst sichtbar, wenn das Datum erreicht ist und alle vorgesehenen Figuren ein tatsächlich ausgeliefertes Sprite haben. Ein fehlendes Bild verschiebt das betroffene Pack; es wird nicht durch eine Standardfigur ersetzt. Vor dem Termin sind auch Bildadressen und Kisteninhalte gesperrt. Bereits vorhandene reguläre Figuren bleiben verfügbar.

| Termin, jeweils 18 Uhr | Inhalt | Vorbereitung |
| --- | --- | --- |
| 30.10.2026 | Creepshow zu Halloween, Bühne für alle einschließlich vorhandener Kronleuchter | Bestehende Bühne |
| 08.11.2026 | Eine höllische Herausforderung, neues Skinpack und drei Set-Kisten | Elf Rollen und Willi fertig, anhand der Kostümfotos geprüft |
| 22.11.2026 | Traum von Freiheit | Historische Aufnahmen vorhanden |
| 29.11.2026 | Weihnachtsbühne für alle | Bühne, Hindernisse, Sammelobjekte und eigene Musik fertig |
| 06.12.2026 | Goldfieber | Historische Aufnahmen vorhanden |
| 20.12.2026 | Malleus Maleficarum | Historische Aufnahmen vorhanden |
| 30.12.2026 | Romeo und Julia, Bühne nach der Aufführungsserie und neues Skinpack | Kostümfotos fehlen noch; Fotoalbum ist derzeit leer |
| 17.01.2027 | Der Kristall der Träume | Historische Aufnahmen vorhanden |
| 31.01.2027 | Dystopia | Historische Aufnahmen vorhanden |
| 14.02.2027 | Bluttribut | Historische Aufnahmen vorhanden |
| 28.02.2027 | Verrat im Kloster | Historische Aufnahmen vorhanden |
| 14.03.2027 | Sagenhaft | Quellen und Rollen einzeln prüfen |
| 28.03.2027 | Die Geschichte der Black Swan, fehlende Rollen | Quellen und Rollen einzeln prüfen |
| 11.04.2027 | Anno 1146, fehlende Rollen | Ergänzungen zum bestehenden Set |
| 25.04.2027 | Creepshow, fehlende Rollen | Ergänzungen zum bestehenden Set |
| 09.05.2027 | Nexus, fehlende Rolle | Ergänzung zum bestehenden Set |

Die späteren Packs sind auf Wunsch des Nutzers als Folge eingeplant. Sie sind erst nach Fotoabgleich, Grafikerstellung, Sichtprüfung, Tests und Bereitstellung fertig. Ein Kalendereintrag allein belegt keinen fertigen oder veröffentlichten Inhalt.

## Ensembleziele und Kisten

Jedes Rollenpack erhält ein eigenes Ziel über 100.000 Meter. Nur vom Server angenommene Läufe, die nach der Freischaltung begonnen wurden, zählen. Alte Gesamtmeter und bestehende Ensemble-Kisten bleiben erhalten. Das Ziel endet, wenn die gemeinsame Strecke erreicht ist. Jedes dann aktive Mitglied mit einem Beitrag bekommt genau einmal drei Kisten aus dem festgehaltenen Figurenbestand dieses Packs. Spätere Beiträge oder neue Mitglieder erhalten diese Beteiligungsbelohnung nicht rückwirkend. Mehrfach übertragene Läufe und wiederholte Öffnungsanfragen dürfen nichts doppelt gutschreiben.

Der vorhandene langfristige Ensemble-Fortschritt läuft zusätzlich weiter. Noch zeitlich gesperrte Belohnungen bleiben auch dann geheim, wenn ihre Kilometergrenze bereits erreicht wurde. Ihre Enthüllung wird erst nach der Freischaltung bestätigt.

## Quellen und Zugang

Das Fotoarchiv läuft unter `https://photo.rittmann.cloud`. Sein API-Schlüssel liegt ausschließlich im macOS-Schlüsselbund unter dem Dienst `photo.rittmann.cloud TheaterApp API`, Konto `Theater@rittmann.cloud`. Er hat Leserechte für Fotos, Alben und vorhandene Beschriftungen. Keine Zugangsdaten in Git, Berichten oder Automationsprompts speichern.

`tool/wardrobe-photo-references.py` lädt Metadaten über diesen Schlüssel. Private Originale und Zuordnungen liegen im ignorierten Verzeichnis `.secrets/wardrobe-photo-references/`. Vorhandene Namensbeschriftungen und offizielle Bildunterschriften dienen als Zuordnung; unbeschriftete Gesichter werden nicht identifiziert. Bei fehlenden Kostümvorlagen bleibt eine Figur zurückgestellt.

Die [offizielle Höllen-Galerie](https://kolpingtheater-ramsen.de/gallery/hell) belegt auch die Korrektur von Fernandas Rolle und Hatices Mammodia. Der Figurenname Niko folgt der bestehenden App; die Galerie nennt die Rolle Belzebub mit Darsteller Nikodem.

## Betrieb

Der verbindliche maschinenlesbare Plan steht in `server/src/wardrobe/releases.json`. Änderungen an Terminen oder neuen Dateien benötigen eine Serverbereitstellung. Bereits bereitgestellte Termine werden ohne Neustart wirksam. Zeitangaben enthalten den zutreffenden UTC-Offset, auch nach der Sommerzeitumstellung 2027.

Vor jeder Veröffentlichung die vorgesehenen Figuren vollständig erzeugen und prüfen, `disabled` nur bei fertigen Bildern entfernen, Seilpunkte eintragen und `tool/optimize-sprites.py` ausführen. Server- und Flutter-Tests prüfen Zeitgrenzen, Zugriff, Set-Kisten, Wiederholungen und Alt-Clients. Vorbereitete Quellen sind nicht automatisch live: Web und Server benötigen `tool/deploy.py`, Android wird ausschließlich im geschlossenen Google-Play-Test `alpha` eingereicht. Googles tatsächlich zurückgelesener Status entscheidet, ob Tester die Version erhalten können.
