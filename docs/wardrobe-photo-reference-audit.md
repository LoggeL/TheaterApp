# Kostümreferenzen für die fehlenden Skinpacks

Stand: 27.10.2026. Die Bestandsaufnahme erfolgte vor der Aktivierung der neuen Figuren. Sie umfasst 149 deaktivierte Katalogeinträge: 139 menschliche Rollen, vier Unique-Figuren und sechs Platzhalter für Bühnenbilder/Hindernisse. Für keinen dieser Einträge lag zu diesem Zeitpunkt die referenzierte Bilddatei vor.

## Quellen und Zugang

Die Quelle ist das geschützte [Theater-Fotoarchiv](https://photo.rittmann.cloud), Immich 3.3.5. Ein Leseschlüssel liegt im macOS-Schlüsselbund unter dem Dienst `photo.rittmann.cloud TheaterApp API`, Konto `Theater@rittmann.cloud`. Der Schlüssel gehört weder ins Repository noch in ein Export- oder Protokolldokument.

`tool/wardrobe-photo-references.py` liest den Schlüssel ausschließlich aus dem Schlüsselbund. Das Werkzeug kann Alben auflisten, Metadaten durchsuchen und ausgewählte Vorschauen mit bereits vorhandenen Personenbeschriftungen abrufen. Es verändert keine Alben, Bilder oder Personen. Downloads und Referenzmetadaten werden unter `.secrets/wardrobe-photo-references/` abgelegt; dieses Verzeichnis ist durch `.gitignore` ausgeschlossen. Fremde Weiterleitungsziele erhalten den Schlüssel nicht.

```sh
python3 tool/wardrobe-photo-references.py albums
python3 tool/wardrobe-photo-references.py album 63188669-f972-4dff-9d30-4ab7f9a919af --year 2024
python3 tool/wardrobe-photo-references.py download 270825e8-70f0-4ec4-9982-f0226495b3ae --faces
```

Die Zuordnung nutzt vorhandene Textbeschriftungen in Immich und ausdrücklich beschriftete Szenen auf der [offiziellen Hölle-Galerie](https://kolpingtheater-ramsen.de/gallery/hell). Es wurde keine Gesichtserkennung durchgeführt. Ein Personenname in einem Gruppenfoto allein legt noch nicht fest, welche Figur im Bild gemeint ist. Vorhandene beschriftete Koordinaten helfen beim Ausschnitt; Rollen und Kostüme müssen zusätzlich zum jeweiligen Stück passen.

## Eine höllische Herausforderung

Das Album "Kreativbühne Theaterfest" enthält 16 Bühnenfotos vom 27. und 28.12.2024. Die offizielle Galerie ergänzt die Professorin und Willi. Damit gibt es Bildvorlagen für die zehn zuvor eingetragenen menschlichen Rollen, die zusätzlich belegte Mammodia und Willi. Die Katalog- und Kostümkorrekturen beruhen auf den Szenenbeschriftungen:

- Fernanda spielt die Assistentin des Teufels. Die frühere Katalogrolle "Mammonia" war falsch. Das Kostüm besteht aus weißer Bluse, dunkler Weste und Hose; ein Klemmbrett ist auf dem Foto zu sehen (Szene 4).
- Mammodia wird in Szene 7 Hatice zugeordnet. Immich schreibt den vorhandenen Namen "Hatiche". Diese Figur ist von Fernandas Assistentin zu trennen.
- Vanessa ist ein Engel undercover. Schwarzes Kleid und rote Hörner sind daher das belegte Bühnenkostüm, obwohl die Rollenbezeichnung Engel lautet (Szene 6).
- Nora ist als Prof. Dr. Dr. Glutheiß beschriftet. Szene 4 zeigt einen roten Blazer über weißer Bluse, schwarze Hose, Brille und kleine rote Hörner.
- Willi ist die Handpuppe auf Szene 3, mit grünbraunem Körper, hellerem Bauch und rotem Maul.
- Der Katalogname Niko gehört zur Rolle, die in Szene 5 als Belzebub (Nikodem) bezeichnet wird. Die vorhandene Rollen-ID bleibt erhalten.

Die lokalen Dateien `hell-2024/role-references.json` und `hell-2024/*-reference.jpg` enthalten zwölf vorbereitete Zuordnungen bzw. Ausschnitte. Die JSON-Datei benennt jeweils Asset-ID, bestehende Beschriftung, Quelldatei und Ausschnitt. `website-scene-3.jpg` und `website-scene-4.jpg` bewahren die vollständigen Ergänzungsbilder. `hell-2024/contact-sheet.jpg` zeigt die 16 Archivfotos; `*-labels.jpg` zeigt vorhandene Immich-Beschriftungen an ihren gespeicherten Bildpositionen.

## Weitere Stücke

Die "Theaterfest"-Alben sind kuratierte Sammlungen alter Bühnenfotos, keine bloßen Fotos vom Theaterfest. Je zwei Bilder aus sieben historischen Alben wurden visuell geprüft. Die Anzahl schließt die jeweilige Titelfolie ein. "Namensbelege" bedeutet nur, dass der Katalogname bereits in den Personenmetadaten vorkommt; es ist keine Abnahme des Kostüms oder der Rollenzuordnung. Die drei Namensvarianten Niko/Nikodem, Carina/Caro und Tobias/Tobi sind gesonderte Kandidaten und wurden nicht automatisch als identische Personen zusammengeführt.

| Stück | Fehlende menschliche Rollen | Archivbilder in der geprüften Auswahl | Exakte Namensbelege | Weitere Namensvarianten | Offene Zuordnung in dieser Auswahl |
| --- | ---: | ---: | ---: | ---: | --- |
| Traum von Freiheit | 24 | 43 | 21 | 3 | Vollständige Kandidatenmenge, Kostüme einzeln prüfen |
| Goldfieber | 21 | 30 | 16 | 3 | Till, Maximilian |
| Malleus Maleficarum | 16 | 36 | 12 | 2 | Jonas, Maximilian |
| Der Kristall der Träume | 12 | 27 | 4 | 1 | Till, Maria, Maximilian, Nora, Sebastian, Tobias, Logge |
| Dystopia | 9 | 27 | 7 | 1 | Nora |
| Bluttribut | 9 | 25 | 5 | 1 | Julian, Nora, Logge |
| Verrat im Kloster | 8 | 16 | 3 | 1 | Till, Leon, Maximilian, Logge |
| Sagenhaft | 13 | 13 | 9 | 1 | Logge, Raphael, Tobias |
| Die Geschichte der Black Swan | 2 | 0 | 0 | 0 | Kein eigenes Album gefunden; Anton, Carina |
| Anno 1146 | 3 | 46 | 2 | 1 | Zusätzlich fehlt eine belegte Vorlage der Unique-Ritterpuppe |
| Nexus | 1 | 36 | 1 | 0 | Fynns frühere Ensemblerolle benötigt Kostümprüfung |
| Creepshow | 2 | 244 | 2 | 0 | Vorhandene Rollenfotos einzeln prüfen |
| Romeo und Julia | 9 | 0 | 0 | 0 | Album "Winterstück-2026" leer, echte Kostümfotos fehlen |

Die zusätzlichen Unique-Figuren Kristall und Rabe haben in dieser Prüfung noch keine eindeutig bezeichneten Bildvorlagen. Fehlende Namen in der Auswahl beweisen nicht, dass kein Foto der Person existiert: Weitere Szenen können unbeschriftet sein, und größere Alben enthalten zusätzliche Bilder. Daraus darf keine unbestätigte Zuordnung abgeleitet werden.

`source-coverage.json` im privaten Referenzverzeichnis enthält pro Rollen-ID die gefundenen Asset-Kandidaten. Für Hölle ist die ergänzte Datei `hell-2024/role-references.json` maßgeblich. `historical-samples/contact-sheet.jpg` dokumentiert die Sichtprüfung der alten Bühnenfotos.

## Freigabe der Bilder

Ein Skin wird erst aktiviert, wenn seine Rolle durch eine Textquelle zugeordnet, sein Kostüm anhand eines passenden Fotos umgesetzt und Atlas, Porträt sowie Seilpunkte im Spiel geprüft sind. Ein Referenztreffer allein ist noch kein fertiger Skin. Romeo und Julia bleibt bis zu echten Kostümfotos vorbereitet; der geplante Termin nach den Aufführungen ersetzt diese Voraussetzung nicht.

Geprüft wurden die Hilfe des Werkzeugs und ein echter Metadatenabruf für die 16 Hölle-Fotos. Der API-Schlüssel wurde nicht ausgegeben. Die privaten Referenzdateien wurden nicht in den Katalog übernommen oder als Spielgrafiken aktiviert.

## Fertiggestellte Spielgrafiken

Die elf Höllen-Rollen und Willi wurden anschließend mit dem eingebauten Imagegen anhand dieser Referenzen erstellt. Je Figur liegen ein Atlas mit acht Posen, ein Porträt und geprüfte Seilpunkte vor. Maße, Transparenz und Bildbudgets wurden geprüft; die Optimierung reduzierte die neuen Spielbilder ohne Änderung ihrer Atlasfelder. Die Figuren sind für die Freischaltung am 08.11.2026 vorbereitet. Die übrigen Packs bleiben in der dokumentierten Vorbereitung. Prompts und Integrationsdaten liegen lokal in `artifacts/hell-art-a` bis `artifacts/hell-art-d`; private Fotoquellen bleiben in `.secrets/`.
