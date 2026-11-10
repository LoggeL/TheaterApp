# Zweite Korrekturrunde der Skins

12 Porträts und 13 Spiel-Sheets wurden anhand des Feedbacks vom 10. November angepasst.

| Figur | Anpassung |
| --- | --- |
| Lucy im Bademantel | Feder aus der Hand entfernt; rote Haarfeder erhalten. |
| Mia im Waisenhauskleid | Geflicktes Kleid nach Claras bestehendem Waisenhaus-Skin, weiterhin mit Kerze. |
| Logge als Partygast | Deutlich mehr Locken, Kostüm und Maske erhalten. |
| Marcella als Dienerin | Porträt ohne Haube. |
| Johanna als Ritterin | Bluse, breiter Gürtel und schmale Lederriemen nach Bühnenfoto, Schwert am Gürtel; Körperbau nach bestehendem Anno-Skin. |
| Johanna im Strohkleid | Holzschwert in der Hand, Körperbau nach bestehendem Anno-Skin. |
| Dr. Adrian von Düsterwald, Explosion | Jacke und Mantel entfernt, ein Hosenbein abgerissen, rußiges Gesicht, zerzauste Haare und versengtes Hemd. |
| Nela als Gauklerin | Laufbilder mit der halboffenen, langen Frisur des Porträts. |
| Lena als Anno-Ensemble | Rostbraunes Gewand mit weiten cremefarbenen Ärmeln, Schultercape, grüner Borte und Kette nach Aufführungsfotos. |
| Jonas als Berthold, Sagenhaft | Kurzes dunkles Haar und Gesicht nach Anno-Berthold; dunkelblauer Mantel. |
| Nora als Chronistin | Porträt an das bestehende Nora-Gesicht angepasst. |
| Vanessa als Waldgeist | Offene Haare und Jubelpose in voller Körperhöhe. |
| Fernanda als Magd | Kleine Verbeugung mit Winken als neue Jubelpose. |
| Logge als Bote | Langer schwarzer Rüstmantel. |
| Tobias als Bär | Bärentatzen statt Turnschuhen; hochgereckte Arme in der Jubelpose erhalten. |
| Lina R. als Fiona, Creepshow | Aufrechte Jubelpose mit senkrechtem Hammer, Kopf und Körper im Verhältnis zum Laufskin. |

Die übrigen sieben Posen von Lina und Fernanda sind bildlich erhalten. Die neuen Sheets verwenden weiterhin die festen Atlasfelder; die Seilpunkte wurden passend gesetzt. Die anderen Bilddateien wurden nicht verändert.

## Captain Kuschels Weihnachtsedition

Die Weihnachtsedition hat die Seltenheit `unique` und wird einmalig für alle 23 übrigen Figuren des Adventskalenders vergeben. Sie selbst zählt nicht als Voraussetzung. Die vollständige Anforderung bleibt bei 23, auch wenn Einträge noch deaktiviert oder durch Veröffentlichungstermine gesperrt sind. Die Belohnung ist kein Inhalt von Kisten, Käufen oder Tauschgeschäften und bleibt bis zur Freischaltung verborgen. Die vorhandene Deaktivierung des Kalenders wird durch diese Korrektur nicht aufgehoben.

Der Katalog beschreibt diese Regel mit `unlock: { allAdventCalendar: true }`; die Prüfung leitet die festen IDs aus den 24 Kalendereinträgen ab. Die App nennt den Fortschritt entsprechend in Adventskalender-Skins.

## Referenzen und Prüfung

Für Anno wurden 46 Archivdatensätze erneut abgerufen und zehn bereits beschriftete Kostümausschnitte gelesen. Lenas Kostüm ist in `DSC05401.jpg` und `DSC06762.jpg` belegt. Johannas Ritterkostüm folgt `DSC06063.jpg`. Die Zuordnungen nutzen vorhandene Archivbeschriftungen; Referenzfotos und Schlüssel bleiben außerhalb des Repositorys.

784 Servertests bestanden, ein vorhandener Test übersprungen. 78 Flutter-Tests für Garderobe und Unique-Anzeige sowie neun Tests für Adminszene, Rollendarstellung und Renderprüfung bestanden. Der echte Spielrenderer zeigt alle 16 betroffenen Figuren beim Laufen, Fliegen, Hängen und Jubeln. Die Figurenübersicht meldet keine Hinweise. Bildgrößen, Transparenz, Atlasgrenzen, Seilpunkte und Thumbnails sind geprüft.
