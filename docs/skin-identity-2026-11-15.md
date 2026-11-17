# Adventskalender: Identität und Statur, 15. November 2026

Aktueller Stand (17. November 2026): Nach Sebastians Rückmeldung vom 17. November wurden 21 Kalenderfiguren mit einem neuen, basisgestützten Verfahren (v3) neu aufgebaut. Gesicht, Haare, Hände und Körperumriss stammen dabei pixelweise aus der vorhandenen Figur; nur die Kleidung ist neu. Ergebnis und offene Punkte stehen im Abschnitt [Basisgestützte Neufassung (v3)](#basisgestützte-neufassung-v3). Diese Fassung liegt nur auf einem Arbeitszweig und ist weder veröffentlicht noch eingereicht.

Die folgenden Abschnitte bis „Erneute Identitätsprüfung“ beschreiben die beanstandete Fassung vom 15. November. Die veröffentlichte Fassung wurde vom Nutzer wegen weiterhin abweichender Gesichter und Körpermodelle beanstandet. Die frühere visuelle Abnahme war zu großzügig; die damaligen Prüfungen belegen keine erfolgreiche Übernahme des bestehenden Charaktermodells.

19 Spiel-Sheets und vier Porträts wurden mit dem Ziel überarbeitet, die vorhandene Figur derselben Person im selben Stück zu treffen. Vier Karten-Thumbnails wurden aus den Porträts erzeugt. Die Bearbeitung war auf 19 Agenten aufgeteilt, jeweils einer pro Person beziehungsweise Captain Kuschel; mehrere Varianten einer Person blieben zusammen.

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

Maren als Creepshow-Dienerin und Lena als Anno-Ensemble haben keine weitere unabhängige Figurenreferenz im selben Stück. Ihre Bilder blieben erhalten; das ist keine Identitätsfreigabe. Logge als Diener, Theresa als echter Falkenstein und Captain Kuschel blieben ebenfalls bytegleich. Die erneute Prüfung zeigt insbesondere bei Theresa auch in dieser unveränderten Fassung Abweichungen. Für Captain Kuschel ist keine eindeutige andere Gesichtsidentität belegt.

Die Seilpunkte der 19 überarbeiteten Sheets wurden auf den fertigen Bildern am oberen Rücken beziehungsweise an den sichtbaren Ösen geprüft und angepasst. Der Katalog enthält ausschließlich diese Änderungen an den Seilpunkten; Freischaltungen, Termine und Seltenheiten sind unverändert.

Die Generierung lief über das eingebaute `image_gen`. Vollständige Prompts, Referenz-IDs, Dateinamen und Einzelprüfungen stehen in [der Begleitdatei](design/advent-identity-2026-11-15.json). Verlustfreie Master, Originale und Vergleichsbilder liegen lokal unter `artifacts/advent-identity-2026-11-15/`. Die aktuelle [Figurenübersicht](runner-review.html#adventskalender) zeigt die integrierten Bilder.

## Prüfung

45 Servertests für Garderobenbilder, Thumbnails, Garderobe und Admin-Katalog sowie 26 Flutter-Tests für Adminszene, Skin-Viewer und Rollendarstellung bestanden. Der Skin-Viewer-Test rendert alle acht Atlasfelder sämtlicher Kalenderfiguren. `optimize-sprites.py --check` besteht, Bildgrößen und Dateibudgets passen. Die Atlasübersicht meldet für die 24 Kalenderfiguren keine Warnungen oder Fehler. Die bestehende Deaktivierung der Skins und ein gleichmäßiger transparenter Fußabstand von drei Pixeln erscheinen weiterhin als Informationen. Die Browserprüfung bestätigt den korrigierten Seilanschluss am Rücken.

Diese Fassung wurde mit Commit `63256e22000421461d9a1bc7c8e3f8911545f08d` und Server-Release `3b426bcf09feb889ce4a` veröffentlicht. Android 0.16.2 (68) wurde im geschlossenen Kanal `alpha` eingereicht; der damals zurückgelesene Google-Status war `IN_REVIEW`. Das ist keine Aussage zum späteren Prüfstatus.

## Erneute Identitätsprüfung nach Nutzerfeedback

Je ein Agent pro Charakter hat Referenz, ursprünglich freigegebenes Adventkostüm und veröffentlichte Fassung erneut verglichen. Die lokalen Einzelbefunde und Vergleichsbilder liegen unter `artifacts/advent-identity-v2/<charakter>/`. Wiederkehrende Fehler sind vergrößerte runde Augen und Köpfe, veränderte Nase/Kiefer, vereinheitlichte Haarzeichnung und übersteuerte Körperproportionen. Auch einzelne Gesten und Seilösen drifteten. Die ursprünglichen Outfit- und Posenfreigaben gelten weiterhin.

Ein neuer Einzelversuch verwendete Hendriks ursprüngliches Karl-Porträt als tatsächliches Bearbeitungsziel und ausschließlich einen Kleidungsausschnitt als zweite Eingabe. Er wurde ebenfalls verworfen: Augen, Lächeln, Kiefer, Ohr und Hände wurden erneut gezeichnet. Prompt, Kandidat und unabhängige Bewertung liegen unter `artifacts/advent-identity-v2/pilot/` sowie `artifacts/advent-identity-v2/hendrik/pilot-review.json`. Das eingebaute Bildwerkzeug hat auch mit dieser Eingabereihenfolge keine verlässliche Identitätserhaltung geliefert. Es wurde kein neuer Kandidat in Produktionsassets übernommen oder veröffentlicht.

Die App nutzt fertige Rasteratlanten, keine getrennten Körper-, Gesichts- und Kleidungsebenen. Ein weiterer Versuch muss erhaltene Originalbereiche bzw. technisch geschützte Bildbereiche ermöglichen und zunächst an einer Figur geprüft werden. Eine weitere pauschale Ganzbildgenerierung oder Kopfvergrößerung ist durch diese Ergebnisse nicht begründet. Die eigentliche Bildkorrektur bleibt offen.

## Basisgestützte Neufassung (v3)

Rückmeldung des Theaters (Sebastian, 17. November 2026): Jede Kalenderfigur muss dem vorhandenen Charaktermodell derselben Person im selben Stück entsprechen. Gesicht, Haare, Körperbau und Proportionen bleiben gleich, nur das Outfit wechselt. Die Fassung vom 15. November erfüllte das nicht.

### Verfahren

Die Bildgenerierung zeichnet Gesichter auch als Bearbeitungsziel immer neu. Deshalb erzeugt v3 nur noch die Kleidung und setzt alles andere aus der vorhandenen Figur zusammen:

1. Das Basis-Sheet der vorhandenen Figur wird verlustfrei auf ein 1536×1024-Raster gelegt (acht Felder, Faktor 1,75). Das Basis-Porträt wird auf 1024×1024 vergrößert.
2. Codex CLI mit dem imagegen-Skill führt genau einen eingebauten `image_gen`-Aufruf im Bearbeitungsmodus aus. Bild 1 ist das Basisraster bzw. -porträt als Bearbeitungsziel. Bild 2 ist das freigegebene Adventkostüm aus `artifacts/advent-identity-2026-11-15/originals/`, ausschließlich als Kleidungsvorlage. Die Personen sind nur im Text beschrieben; es wurden keine Personenfotos verwendet.
3. Weitere `image_gen`-Aufrufe färben in der Basis und im Ergebnis jeweils alle Kleidungsstücke magenta ein. Das ergibt je eine Kleidungsmaske.
4. Das Ergebnis wird auf die Basis registriert: Silhouette per Phasenkorrelation und ECC, danach Gesicht und Hände per Mustervergleich. Neue Kleidung über Basispixeln, etwa Augenmasken oder Hüte, steuert die Registrierung nicht mit. Zulässig sind nur nahezu identische Abbildungen. Danach wird der Kopfbereich lokal nachregistriert. Diese lokale Verschiebung wird zum Rand hin weich ausgeblendet, sodass Kopfbedeckungen auf dem Basiskopf sitzen.
5. Identitätsbereich = deckende Basispixel ohne Basis- und ohne neue Kleidung, soweit das Ergebnis dort die Figur zeigt. Dort übernimmt die Ausgabe die Basispixel unverändert. Außerhalb davon kommt die neue Kleidung aus der Generierung. Übergänge werden nur nach innen weich geblendet. Wo eine entfernte Kopfbedeckung Haut oder Haar freilegt, ist die Blendzone breiter: 5 Pixel im Sheet, 16 im Porträt. Neu gezeichnete Ränder von Haut und Haar dürfen nicht über die Basis-Silhouette hinausragen.
6. Die Zusammensetzung erfolgt in der Originalauflösung des Atlas (1124×577) bzw. des Porträts (512×512). In den verlustfreien Mastern ist jedes Pixel des Identitätsbereichs nachweislich gleich dem Basispixel.

Folgen des Verfahrens:

- Die acht Posen sind jetzt die Posen der vorhandenen Figur. Die zuvor freigegebenen Adventgesten in Jubel-, Hänge-, Flug- und Sturzpose entfallen.
- Requisiten der Basisfigur wurden entfernt; die Hände behalten ihre Griffhaltung. Das betrifft Paket, Speer, Fächer, Buch und Zigarre.
- Unter entfernten Kopfbedeckungen ist das Haar neu gezeichnet und nicht durch die Basis belegt. Betroffen sind die Mützen und Kappen bei Hendrik, Jakob, Logge und Niko sowie Carinas Kapuze. Bei Theo verdeckt die neue Kapuze das Haar.
- Augenmasken und Mumienbandagen verdecken Teile der Basis. Dort lässt sich die Identität nur am sichtbaren Rest prüfen.

Wenn eine Generierung Arme oder Kopf verschob, ein Requisit stehen ließ oder den Bildausschnitt änderte, wurde sie mit demselben Verfahren und strengeren Vorgaben wiederholt:

- Logge als Diener: Sheet und Porträt; Jubel-, Flug- und Sturzpose zusätzlich einzeln.
- Logge als Partygast: Porträt.
- Niko: Porträt.
- Nele im Ballkleid: Sheet, damit die Maske auf dem Kopf sitzt.
- Lina: Sheet und Porträt, damit das Buch verschwindet.
- Nela: Porträt.
- Yunus: Sheet und Porträt; die erste Anfrage wurde von der Moderation blockiert.
- Julian und Yunus: Basismasken, die die weißen Handschuhe erfassen.

Die endgültigen Prompts, Messwerte und Bewertungen je Figur stehen in [der Begleitdatei](design/advent-identity-v3-2026-11-17.json). Alle Zwischenstände (`-v1`, `-v2`), Masken und Berichte liegen lokal unter `artifacts/advent-identity-v3/_work/`.

### Lieferformat

Die verlustfreien Master sind zu groß für die Budgets der Garderobe (Porträt 80 KiB, Atlas 180 KiB). Die ausgelieferten Dateien sind daher verlustbehaftet in der Farbe und verlustfrei im Alphakanal, zunächst in der höchsten Qualität, die das Budget erlaubt. Danach hat `tool/optimize-sprites.py` einen Teil der Dateien nach seinem Qualitätsmaß weiter verkleinert. Durch diese Kompression weichen auch die Identitätspixel geringfügig vom Basisbild ab; die Spannweite steht im nächsten Abschnitt. Die Basisdateien selbst sind ebenfalls verlustbehaftet gespeichert.

### Ergebnis je Figur

Identitätspixel: Pixel im verlustfreien Master, die exakt aus der Basis übernommen sind (Atlas in Originalauflösung, Porträt 512×512); in allen 21 Figuren stimmen sie zu 100 % mit der Basis überein. Kopf-NCC: Übereinstimmung der Generierung mit der Basis im größten sichtbaren Körperbereich (meist das Gesicht) vor dem Einsetzen der Basispixel, als Hinweis auf Nahtstellen; unter 0,75 wurde jede Pose einzeln angesehen. Nach der Lieferkompression liegt die Abweichung der Identitätspixel vom Master zwischen 31,6 und 43,1 dB PSNR.

| Türchen | Figur | Bewertung Identität | Identitätspixel Sheet / Porträt | Kopf-NCC min. Sheet / Porträt | Befund |
| --- | --- | --- | --- | --- | --- |
| 1 | Yunus, Dr. Adrian von Düsterwald (Explosion) | übernommen | 8.917 / 13.801 | 0,94 / 0,98 | Gesicht, Brille, Haare, Hände und Umriss aus der Basis. Zerrissenes Hemd und Gurtzeug; weiße Handschuhe der Basis entfernt (nackte Hände wie im freigegebenen Kostüm). Atlasprüfung: Die Flugpose berührt links den Rahmen. |
| 2 | Nele, Prinzessin Iset (Mumie) | mit Einschränkung | 2.256 / 4.859 | 0,11 / 0,95 | Die Bandagen verdecken Haare und Unterkiefer; in den Sprites sind nur die Augenpartie und der Körperumriss aus der Basis prüfbar. Das Porträt zeigt das Basisgesicht in der Bandagenöffnung. Geringe Kopfübereinstimmung im Sheet ist durch das Kostüm bedingt. Atlasprüfung: Bandagenenden berühren in Lauf-, Jubel-, Hänge- und Flugpose den Rahmen; die Fußlinie im Laufzyklus springt um 7 px. Der Seilpunkt der Hängepose liegt jetzt auf der neu gezeichneten Öse. |
| 3 | Sophie, Mia im Waisenhauskleid | übernommen | 23.304 / 26.967 | 0,94 / 0,98 | Gesicht, Haare, Hände und Umriss aus der Basis. Die Kerze der Jubelpose stößt oben an den Zellenrand. Atlasprüfung: Die Fußlinie springt um 3 px. |
| 4 | Elena, Johanna als Ritterin | übernommen | 19.245 / 48.233 | 0,93 / 0,98 | Gesicht, Locken, Hände und Umriss aus der Basis; Schwert an der Hüfte. |
| 5 | Marcella, Dienerin | übernommen | 19.403 / 31.611 | 0,92 / 0,98 | Gesicht, Haare, Hände und Umriss aus der Basis. Atlasprüfung: Die Laufpose berührt links den Rahmen. |
| 6 | Carina, Mathilde | übernommen | 8.677 / 11.722 | 0,87 / 0,97 | Gesicht, Hände und Umriss aus der Basis. Wo die Kapuze der Basis entfernt wurde, ist das Haar teilweise neu gezeichnet. Atlasprüfung: Hänge- und Laufpose berühren links den Rahmen. Die Öse wurde neu gezeichnet; die Seilpunkte in Pass-, Hänge- und Flugpose wurden auf sie gesetzt. |
| 7 | Logge, Diener 3 | auffällig | 4.630 / 14.464 | 0,08 / 0,93 | Gesicht, Hände und Umriss aus der Basis, Zylinder lokal auf den Kopf ausgerichtet; Lauf-, Jubel-, Hänge- und Flugpose sowie das Porträt sind sauber. Sturzpose: Wo das Paket der Basis lag, ist ein Rest des neu gezeichneten Gesichts sichtbar (Mund/Kinn doppelt), die Schwindelsterne sind nur teilweise erhalten. Haar unter dem Zylinder teilweise neu. Atlasprüfung: Der Zylinder stößt in Lauf-, Pass- und Hängepose oben an den Rahmen und wird dort abgeschnitten; die Sturzpose berührt links den Rahmen. |
| 8 | Nele, Prinzessin Iset im Ballkleid | übernommen | 12.774 / 20.571 | 0,92 / 0,89 | Gesicht, Locken, Hände und Umriss aus der Basis; goldene Kopfmaske in allen Posen auf dem Kopf (Sheet neu generiert). Fächer der Basis entfernt. |
| 9 | Hendrik, Partygast | übernommen (Pilot) | 8.569 / 14.644 | 0,86 / 0,93 | Gesicht, Ohren, Hals, Hände und Umriss pixelgleich zu Karl. Der Haaransatz unter der entfernten Schiebermütze ist neu gezeichnet (kleine Stirnlocke). Keine Brille ergänzt. |
| 11 | Nela, Gauklerin | übernommen | 21.224 / 56.163 | 0,92 / 0,96 | Gesicht, Haare, Hände und Umriss aus der Basis; Porträt mit festem Bildausschnitt neu generiert. Atlasprüfung: Die Fußlinie springt um 3 px. |
| 12 | Lina R., Gauklerin | übernommen | 16.750 / 31.283 | 0,89 / 0,97 | Gesicht, Haare, Hände und Umriss aus der Basis. Das Buch der Basis ist in Sheet und Porträt entfernt (beides neu generiert). Atlasprüfung: Die Fußlinie springt um 3 px. |
| 13 | Theresa, Clara (Echter Falkenstein) | mit Einschränkung | 20.046 / 38.317 | 0,93 / 0,94 | Gesicht, Brille, Locken, Hände und Umriss aus der Basis. In der Sturzpose fehlen die Schwindelsterne der Basis (die Generierung hat sie nicht übernommen). |
| 14 | Jakob, Partygast | mit Einschränkung | 6.123 / 11.126 | 0,81 / 0,84 | Unterer Gesichtsbereich, Ohren, Hände und Umriss aus der Basis; die Augenmaske verdeckt die Augen. Das Haar unter der entfernten Schiebermütze ist neu gezeichnet. Atlasprüfung: Die Fußlinie springt um 4 px. |
| 15 | Julian, Partygast | mit Einschränkung | 5.795 / 8.961 | 0,81 / 0,86 | Gesicht, Haare und Umriss aus der Basis. Die Augenmaske des Kostüms erscheint nur im Porträt, nicht in den Sprites. Die weißen Handschuhe der Basis bleiben. Atlasprüfung: Die Fußlinie springt um 5 px; die Laufpose berührt links den Rahmen. |
| 16 | Elena, Johanna im Strohkleid | übernommen | 17.984 / 40.996 | 0,90 / 0,97 | Gesicht, Locken, Hände und Umriss aus der Basis; Holzschwert. Atlasprüfung: Die Jubelpose berührt oben den Rahmen. |
| 17 | Theo, Dorfbewohner | mit Einschränkung | 2.060 / 4.027 | 0,84 / 0,87 | Gesicht, Hände und Umriss aus der Basis. Die Kettenhaube der Basis wurde durch eine Kapuze ersetzt; Haar ist nicht sichtbar. Speer entfernt, die Hände bleiben in Griffhaltung. Atlasprüfung: Die Fußlinie springt um 4 px; die Laufpose berührt links den Rahmen. |
| 18 | Theresa, Clara in Isets Ballkleid | übernommen | 14.611 / 29.084 | 0,86 / 0,87 | Gesicht, Brille, Locken, Hände und Umriss aus der Basis; Kopfmaske auf dem Kopf. Atlasprüfung: Die Feder der Kopfmaske stößt in Jubel-, Hänge- und Flugpose oben an den Rahmen; die Fußlinie springt um 3 px. |
| 19 | Till, Diener 4 | übernommen | 15.118 / 24.909 | 0,91 / 0,96 | Gesicht, Brille, Bart, Haare, Hände und Umriss aus der Basis. Zigarre entfernt. |
| 20 | Logge, Partygast | mit Einschränkung | 3.079 / 7.492 | 0,76 / 0,78 | Nase, Mund, Kinn, Ohr und Umriss aus der Basis; die Augenmaske verdeckt die Augen. Das gesamte obere Haar unter der entfernten Kappe ist neu gezeichnet und nicht durch die Basis belegt. Porträt neu generiert. |
| 21 | Niko, Butlerpraktikant Emil | übernommen | 10.148 / 11.893 | 0,89 / 0,94 | Gesicht, Hände und Umriss aus der Basis; Porträt neu generiert (erste Fassung hatte einen verschobenen Kopf). Haar unter der entfernten Propellermütze neu gezeichnet; Rucksack entfernt. Atlasprüfung: Der Mantelschoß berührt in der Flugpose links den Rahmen. Der Seilpunkt der Flugpose liegt jetzt auf der neu gezeichneten Öse. |
| 22 | Elena, Lucy im Bademantel | übernommen | 20.353 / 33.187 | 0,77 / 0,96 | Gesicht, Locken, Federschmuck, Hände und Umriss aus der Basis. Atlasprüfung: Die Fußlinie springt um 7 px (Hausschuhe statt Absatzschuhen). |

Bewertung: „übernommen“ heißt: Gesicht, Haare, Hände und Umriss stammen sichtbar und messbar aus der Basis, und die Kopfübergänge sind sauber. „mit Einschränkung“ und „auffällig“ bleiben markiert, bis Sebastian sie gesehen hat. Die Atlashinweise in der Spalte „Befund“ sind davon unabhängig offen.

### Vergleichsbilder und Prüfung

Für jede Figur liegt unter `artifacts/advent-identity-v3/<Tag>-<Figur>/` Folgendes:

- `overview.jpg`: Basis und v3 in allen acht Posen sowie beide Porträts;
- `sheet-run.jpg` und `sheet-special.jpg`: Basis, bisherige Fassung und v3;
- `heads.jpg`: vergrößerte Köpfe;
- `portrait.jpg`;
- `harness.jpg`: Seilpunkte;
- `v3-sheet.png` und `v3-portrait.png`: verlustfreie Master.

Die Seilpunkte der v3-Figuren sind die der jeweiligen Basisfigur, weil Umriss und Haltung identisch sind. Ausnahme sind fünf Punkte, die auf neu gezeichnete Ösen versetzt wurden (siehe unten). Freischaltungen, Termine, Titel und Seltenheiten sind unverändert. Alle Kalendereinträge bleiben deaktiviert.

Prüfungen auf dem Arbeitszweig:

- Alle 785 Servertests laufen ohne Fehler (784 bestanden, einer übersprungen). Darin enthalten sind die 45 Tests für Garderobenbilder, Thumbnails, Garderobe und Admin-Katalog.
- 34 Flutter-Tests bestehen: Skin-Viewer, Adminszene, Rollenfiguren und Garderobenrollen.
- `tool/optimize-sprites.py --check` besteht. 42 Bilder und 21 Thumbnails liegen im Budget.

Die Atlasübersicht (`docs/runner-review.html`) meldet für die Kalenderfiguren gegenüber ihrer Basisfigur neue Hinweise. Sie stehen oben in der Tabelle:

- Kleidung berührt den Rahmen. Lange Mäntel, Bandagenenden, Zylinder und Federn reichen über den Umriss der Basis hinaus und werden am festen Atlasfeld abgeschnitten.
- Die Fußlinie springt. Neue Schuhe oder nackte Füße enden nicht auf derselben Höhe wie die Füße der Basis.

Die Fassung vom 15. November war ohne diese Warnungen. Die Hinweise sind nicht behoben: Eine Korrektur müsste die Basisfigur verschieben oder skalieren oder die Kleidung erneut erzeugen.

Die Seilpunkte in `harness.jpg` wurden für alle 21 Figuren angesehen. Wo die Generierung die Öse neu gezeichnet hat und der Basispunkt dadurch neben der Figur lag, wurde der Punkt auf die neue Öse gesetzt (Nele als Mumie: Hängepose; Carina: Pass-, Hänge- und Flugpose; Niko: Flugpose).

Nicht Teil dieser Fassung: Maren (Türchen 10), Lena (Türchen 23) und Captain Kuschel (Türchen 24) sind unverändert.
