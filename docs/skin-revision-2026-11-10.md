# Skin-Korrekturen vom 10. November 2026

Alle 13 Sagenhaft-Figuren und alle 24 Adventskalender-Skins erhalten eigenständige Porträts. Die Gesichtsreferenzen stammen aus den bereits vorhandenen Figuren derselben Person. Die Kartenbilder werden mit `tool/optimize-sprites.py` aus den fertigen Porträts erzeugt.

Zehn Sagenhaft-Sheets wurden an die Kostümfotos und die bestehenden Figuren angepasst. Die Jubelposen sind individuell gestaltet. Die freigegebenen Sheets von Tobias, Raphael und Niko sind unverändert.

14 Adventskalender-Sheets wurden angepasst:

| Skin | Korrektur |
| --- | --- |
| Yunus, Adrian explodiert | Weniger Sahne, ursprüngliches Gesicht und passender Anzug. |
| Sophie, Waisenhauskleid | Helles Kleid mit Kerze im Messingleuchter nach dem PDF-Entwurf. |
| Elena, Ritterin | Kein Ohrring. |
| Nele und Theresa, ägyptisches Abendkleid | Masken, Schmuck, drapierter Rock und goldene Sandalen nach dem PDF. Jeweils das eigene Gesicht, Theresa mit Brille. |
| Hendrik und Jakob, Partygast | Statur und Gesicht wie als Waisenhauskind. |
| Julian, Partygast | Dreispitz, weißes Jabot, roter Brokat und dunkler Mantel mit goldenen Verzierungen. |
| Theo, Dorfbewohner | Braune Stiefel, schwarze Bundhose, weißes Schnürhemd, blaue Gugel mit Zatteln. |
| Till, Diener | Gesicht, Brille und Statur der vorhandenen Till-Figur. |
| Logge, Partygast | Langer schwarzer Mantel mit goldenen Posamenten und dunkle Maske. |
| Niko, Butlerpraktikant | Keine Mütze, übergroßer langer Butlerfrack über rotem Pulli. |
| Elena, Lucy im Bademantel | Ursprüngliches Lucy-Gesicht, Locken und rote Haarfeder. |
| Lena, Anno-Ensemble | Ursprüngliches Lena-Gesicht mit geraderem braunem Haar und runder Brille. |

## Quellenzuordnung

- Kostümfotos der jeweiligen Aufführung und vorhandene Porträts/Figuren als Gesichts- und Stilreferenz.
- `adventskalender-skins.pdf`, 31 Seiten, SHA-256 `03173f1cf443959687fec69315e594fdf6e2f9471b0006bdf465d9851a56b2c8`. Seite 3 für die ägyptischen Abendkleider, Seite 4 für Sophie mit Kerze.
- Vom Nutzer bestätigte Zuordnung der nummerierten Schlussszenenfotos: Logge ist Nr. 6, Julian Nr. 23.
- Lena und Lucy wurden nach dem zusätzlichen Gesichtsfeedback direkt von ihren ursprünglichen Porträts abgeleitet.

Die acht festen Spielposen und das Atlasformat bleiben erhalten. Die Seilpunkte liegen auf den neuen Figuren. Veröffentlichungsdaten und Adventskalender-Zuordnungen werden durch diese Änderung nicht angepasst.

## Prüfung

781 Servertests bestanden, ein bestehender Test übersprungen. Neun Flutter-Tests bestanden, einschließlich Garderobenkarten, Adminszene und Renderprüfung aller 37 Figuren in drei Spielsituationen. Die lokale Figurenübersicht meldet keine Hinweise. Die 24 neuen Sheets bestehen die Prüfung auf Zellgrenzen, Transparenz und Seilpunkte; alle 13 nicht überarbeiteten Sheets sind bytegleich erhalten.
