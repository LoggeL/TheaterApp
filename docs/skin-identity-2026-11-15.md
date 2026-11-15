# Adventskalender: Identität und Statur, 15. November 2026

19 Spiel-Sheets und vier Porträts wurden an die vorhandene Figur derselben Person im selben Stück angeglichen. Die visuelle Prüfung umfasst die freigegebenen Outfits, Requisiten und alle acht Zielposen. Vier Karten-Thumbnails wurden aus den fertigen Porträts erzeugt. Die Bearbeitung war auf 19 Agenten aufgeteilt, jeweils einer pro Person beziehungsweise Captain Kuschel; mehrere Varianten einer Person blieben zusammen.

| Türchen | Figur | Referenz | Änderung |
| --- | --- | --- | --- |
| 1 | Yunus, Dr. Adrian von Düsterwald (Explosion) | character.yunus | Spiel-Sheet |
| 2 | Nele, Prinzessin Iset (Mumie) | character.nele | Spiel-Sheet, Porträt, Thumbnail |
| 3 | Sophie, Mia im Waisenhauskleid | character.sophie | Spiel-Sheet |
| 4 | Elena, Johanna als Ritterin | character.elena--anno | Spiel-Sheet |
| 5 | Marcella, Dienerin | character.marcella | Spiel-Sheet, Porträt, Thumbnail |
| 6 | Carina, Mathilde | character.carina--anno | Spiel-Sheet |
| 7 | Logge, Diener 3 | character.logge | Unverändert |
| 8 | Nele, Prinzessin Iset im Ballkleid | character.nele | Spiel-Sheet |
| 9 | Hendrik, Partygast | character.hendrik | Spiel-Sheet, Porträt, Thumbnail |
| 10 | Maren, Dienerin | Keine unabhängige Figur im selben Stück | Unverändert |
| 11 | Nela, Gauklerin | character.nela--anno | Spiel-Sheet |
| 12 | Lina R., Gauklerin | character.lina--anno | Spiel-Sheet |
| 13 | Theresa, Clara (Echter Falkenstein) | character.theresa | Unverändert |
| 14 | Jakob, Partygast | character.jakob | Spiel-Sheet, Porträt, Thumbnail |
| 15 | Julian, Partygast | character.julian | Spiel-Sheet |
| 16 | Elena, Johanna im Strohkleid | character.elena--anno | Spiel-Sheet |
| 17 | Theo, Dorfbewohner | character.theo | Spiel-Sheet |
| 18 | Theresa, Clara in Isets Ballkleid | character.theresa | Spiel-Sheet |
| 19 | Till, Diener 4 | character.till | Spiel-Sheet |
| 20 | Logge, Partygast | character.logge | Spiel-Sheet |
| 21 | Niko, Butlerpraktikant Emil | character.niko | Spiel-Sheet |
| 22 | Elena, Lucy im Bademantel | character.elena | Spiel-Sheet |
| 23 | Lena, Ensemble | Keine unabhängige Figur im selben Stück | Unverändert |
| 24 | Captain Kuschel, Captain Kuschel (Weihnachtsedition) | character.unique-captain-kuschel | Unverändert |

Maren als Creepshow-Dienerin und Lena als Anno-Ensemble haben keine weitere unabhängige Figurenreferenz im selben Stück. Ihre Bilder bleiben erhalten. Logge als Diener, Theresa als echter Falkenstein und Captain Kuschel passen bereits zur jeweiligen Referenz und bleiben ebenfalls bytegleich.

Die Seilpunkte der 19 überarbeiteten Sheets wurden auf den fertigen Bildern am oberen Rücken beziehungsweise an den sichtbaren Ösen geprüft und angepasst. Der Katalog enthält ausschließlich diese Änderungen an den Seilpunkten; Freischaltungen, Termine und Seltenheiten sind unverändert.

Die Generierung lief über das eingebaute `image_gen`. Vollständige Prompts, Referenz-IDs, Dateinamen und Einzelprüfungen stehen in [der Begleitdatei](design/advent-identity-2026-11-15.json). Verlustfreie Master, Originale und Vergleichsbilder liegen lokal unter `artifacts/advent-identity-2026-11-15/`. Die aktuelle [Figurenübersicht](runner-review.html#adventskalender) zeigt die integrierten Bilder.

## Prüfung

45 Servertests für Garderobenbilder, Thumbnails, Garderobe und Admin-Katalog sowie 26 Flutter-Tests für Adminszene, Skin-Viewer und Rollendarstellung bestanden. Der Skin-Viewer-Test rendert alle acht Atlasfelder sämtlicher Kalenderfiguren. `optimize-sprites.py --check` besteht, Bildgrößen und Dateibudgets passen. Die Atlasübersicht meldet für die 24 Kalenderfiguren keine Warnungen oder Fehler. Die bestehende Deaktivierung der Skins und ein gleichmäßiger transparenter Fußabstand von drei Pixeln erscheinen weiterhin als Informationen. Die Browserprüfung bestätigt den korrigierten Seilanschluss am Rücken.

Die Änderungen sind lokal integriert. Es erfolgte keine Veröffentlichung oder Android-Einreichung.
