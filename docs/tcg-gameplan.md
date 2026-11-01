# Gameplan: Theater-TCG „Premiere“

Stand 25.10.2026. Schwerpunkt ist das **Game Design** (Abschnitte 1–3); Technik und Umsetzung stehen ab Abschnitt 4. Entstanden aus einer Analyse der Codebasis (nur lesend), drei unabhängigen Entwürfen (MVP-zuerst, Design-zuerst, Risiko-zuerst), einer Synthese und einer Gegenprüfung gegen den Code. Zahlen stammen aus der Live-Sicherung `.secrets/backups/theater-20261019T164256Z.sqlite` (read-only) und aus `server/src/wardrobe/catalog.json`. Rechtliche Einschätzungen sind keine Rechtsberatung.

## 1. Kurzfassung

- Jede Karte ist eine **Figur** (Rolle · Stück · Jahr), nie der Darsteller.
- Kosten, Werte und Schlüsselwörter rechnet ein Skript **automatisch aus den Drehbüchern** aus: Textanteil, Wörter pro Zeile, Szenen, Fragenanteil, gemeinsame Szenen.
- Die Regeln laufen **nur auf dem Node-Server** als deterministische JS-Engine (`server/src/tcg/`). Flutter zeigt die Spielersicht und die erlaubten Züge an.
- Fast alles rund um das Spiel existiert schon im Bühnenlauf: Kisten-Ziehung, Seltenheiten, Glanz, Gage, Missionen, Push, Idempotenz, Feature-Flags, Porträts. **Es fehlt das eigentliche Spiel**: Engine, Kartenwerte, Spielfeld, KI, Deckbau. Außerdem fehlen die Klärung von Einwilligungen und Textrechten.
- Reihenfolge: Daten + Papier-Probe → MVP gegen die KI (Anno 1146 vs. Creepshow) → Sammeln/Deckbau → asynchrones PvP → weitere Sets.
- **Bedarfs-Schranke:** Den Bühnenlauf haben laut Sicherung erst **6 Personen** gespielt (27 freigegebene Konten). Nach dem MVP messen, bevor die großen Phasen starten.

## 2. Spielkonzept

### Regelkern (MVP)
- 1 gegen 1, je 20 **Publikum**. Bei 0 ist die Partie verloren, ebenso beim Ziehen aus leerem Deck („Texthänger“).
- **Textbuch** (Deck): 40 Karten, davon 16–17 Kulissen. Von jeder anderen Karte höchstens 2 Exemplare. Hauptrollen sind legendär (1×). Die Legendenregel greift über die Karten-ID, nicht über den Namen (es gibt „Graf“ in beiden Stücken).
- 5 Handkarten, Mulligan auf 4. Der Startspieler zieht im ersten Zug nicht. Der Zweite bekommt einen Ausgleich (z. B. eine „Souffleur“-Münze: einmal +1 Applaus). Der Simulator muss die Gewinnquote **je Sitzplatz** messen (Ziel ±5 %).
- Zugablauf: **Vorhang auf** (aufrichten, ziehen) → **1. Akt** (1 Kulisse spielen, Karten spielen) → **Auftritt** (Angriff, Verteidiger blockt wie bei MTG) → **2. Akt** → **Vorhang zu** (Handlimit 8).
- **Lampenfieber:** Neu ausgespielte Rollen greifen erst im nächsten Zug an.
- **Reaktionen:** Im MVP ein festes Fenster nach dem Ansagen der Blocker, kein Stack mit Priorität. Für asynchrones PvP kommen verdeckte **Stichwort-Fallen** dazu (bis zu 2 im Souffleurkasten), damit kein Kampf eine zusätzliche Push-Rundreise braucht.

### Ressource: Kulissen als Länder (Stand 25.10.)
Nach der Sprachnachricht vom 25.10. gibt es **echte Länder wie bei MTG**: fünf Farben, und jedes Grundland ist eine Kulisse aus einem eurer Stücke. Das ersetzt den automatischen Applaus und die Fraktionssymbole.
- Jede Kulisse bringt beim Tappen 1 **Applaus** ihrer Farbe. Pro Zug darf man 1 Kulisse ausspielen.
- Deck mit **40 Karten, davon 16–17 Kulissen**, wie im MTG-Limited-Format. Für Grund-Kulissen gilt die 2-Exemplare-Grenze nicht.
- **Gegen Mana-Pech** in kleinen Decks: Die Starthand wird geglättet wie in MTG Arena Bo1 (aus mehreren gezogenen Händen nimmt die Engine die mit der passendsten Kulissenzahl). Außerdem ist der Mulligan kostenlos, wenn die Hand 0 oder mindestens 6 Kulissen hat.
- Kosten = Zahl + Farbsymbole. Die Zahl der Farbsymbole wächst mit der Seltenheit: Common 1, Uncommon 1–2, Rare und Mythic 2–3.
- Die Farbe einer Karte kommt aus dem **Schauplatz ihres Stücks**, nicht aus dem Stücktitel. Ein Stück kann deshalb zwei Farben haben.

### Die fünf Farben

Die Zuordnung stammt aus der Sprachnachricht. Sie wurde gegen die Regieanweisungen geprüft: Gezählt wurden Schauplatz-Wörter je Farbe in den Zeilen ohne Dialog.

| Farbe | Grundland → Kulisse | Stücke (Hauptfarbe) | Zweitfarbe | Beleg aus den Drehbüchern |
|---|---|---|---|---|
| **Rot** | Gebirge → „Wüste“ (Goldfieber) | Goldfieber 2022, Eine höllische Herausforderung 2024 | Sagenhaft (G/R) | Goldfieber: 100 % der Treffer sind Mine, Saloon, Berg. Hölle: „Die Bühne färbt sich rot“, der Teufel |
| **Blau** | Insel → „Piratenbucht“ (Traum von Freiheit) | Traum von Freiheit 2023, Der Kristall der Träume 2020 | – | Traum von Freiheit ist das Piratenstück (Blackbeard, Anne Bonny; Schiff und Hafen 60 %). Kristall: Träume, Portal, Wissenschaftler |
| **Schwarz** | Sumpf → „Kanalisation“ (Nexus) | Nexus 2024, Creepshow 2026, Bluttribut 2018 | Höllische (R/B), Schicksalsfäden (W/B) | Nexus: „Wir müssen schnell in die Kanalisation“ (92 % dunkle Schauplätze). Bluttribut: Vampire, „Blutsaugen für Anfänger“ |
| **Weiß** | Ebene → „Klosterhof“ (Malleus Maleficarum) | Malleus Maleficarum 2021, Schicksalsfäden 2025, Romeo und Julia 2026 (?) | Anno 1146 (G/W) | Malleus: 47 % Kloster, Kirche, Hof, mit Inquisitor Heinrich als Mythic. Schicksalsfäden: die Moiren und der goldene Schicksalsfaden |
| **Grün** | Wald → „Wald“ (Anno 1146) | Anno 1146 2025, Sagenhaft 2023 | Bluttribut (B/G), Malleus (W/G) | Anno: 78 % Wald, Dorf, Burg. Sagenhaft: ein Bergmann im Eistal, das Monster |

Die Kulissennamen sind Vorschläge. Rot und Blau haben je nur zwei Stücke als Hauptfarbe (die Theater-AG 2025 ist auf Wunsch raus). Weiß hattest du offen gelassen („irgendwas Helles, vielleicht ein Mittelalterstück“); Malleus Maleficarum passt zu beidem.

### Farbidentität (Vorschlag, 25.10.)

Wie sich jede Farbe spielt. Thema aus den Stücken, Daten aus den 10 Drehbüchern (Anteil der Rollen mit dem Schlüsselwort, zweifarbige Stücke halb gezählt). Die Signaturen sind Vorschläge für je ein farbeigenes Schlüsselwort.

| Farbe | Motto | Spielweise | Signatur (Vorschlag) | Schwäche | Auffällig in den Daten |
|---|---|---|---|---|---|
| **Weiß** | Ordnung und Schicksal | schützen und blocken, Publikum zurückgewinnen, Predigt/Prophezeiung als Monolog | **Beifall:** Blockt diese Rolle, erhältst du 1 Publikum. | wenig Schaden | Monolog 42 % |
| **Blau** | Träume und Tricks | Karten ziehen, Textbuch ordnen, Abgang (zurück auf die Hand), Tricks im Reaktionsfenster | **Traumsequenz:** Sieh dir die obersten 3 Karten an, nimm 1 auf die Hand. | kleine Werte | Stichwortgeber 27 %, Duett 30 % |
| **Schwarz** | Schatten und Grusel | Monolog-Schaden, Rollen opfern, von der Hinterbühne zurückholen | **Wiedergänger:** Zahle 2 Publikum: Hole diese Rolle von der Hinterbühne zurück. | kostet eigenes Publikum | nah am Schnitt, das Thema prägt |
| **Rot** | Rausch und Tempo | früh und oft angreifen, Duos stürmen gemeinsam, Direktschaden aus Pyro-Cues | **Goldrausch:** Hast du in diesem Zug eine Kulisse gespielt: +1/+0. | geht die Puste aus | Rampensau 56 %, Duett 30 % |
| **Grün** | Dorf und Gemeinschaft | breit aufbauen mit Ensemble, Requisiten anlegen, große Rollen ab Zug 5 | **Dorffest:** Deine Ensemble-Spielsteine erhalten +1/+1. | kaum Tricks | Monolog 43 %, Rampensau 40 % |

Schlüsselwort-Anteile je Farbe (% der Rollen):

| | Rampensau | Monolog | Stichwortgeber | Duett | Kleiner Auftritt (< 1 %) | Rollen |
|---|---|---|---|---|---|---|
| Weiß | 38 | 42 | 16 | 18 | 11 | 22 |
| Blau | 24 | 36 | 27 | 30 | 18 | 33 |
| Schwarz | 39 | 34 | 20 | 21 | 14 | 38 |
| Rot | 56 | 37 | 11 | 30 | 11 | 27 |
| Grün | 40 | 43 | 19 | 15 | 8 | 26 |
| **alle** | **39** | **38** | **19** | **23** | **13** | **147** |

### Zonen
Textbuch (Bibliothek) · Hand · Bühne (max. 7 Rollen) · Souffleurkasten (Fallen) · Hinterbühne (Friedhof) · Gestrichen (Exil).

### Kartentypen
- **MVP:** Rolle (Kreatur) · Regieanweisung (Spontan, aus Licht-/Ton-/Technik-Cues) · Requisite (Ausrüstung, aus Requisiten-Cues) · Ensemble-Spielstein 1/1.
- **Später:** Szene (Hexerei aus Szenentiteln, Bonus „Besetzt (ROLLE)“) · Crew/Technik · Bühnenbild (7 Bilder vorhanden) · doppelseitige Karten mit **Zeitsprung** (JUNGE ↔ ALTE MARIE/EMMA/JOHANNA; Szene 5 von 2025 heißt „ZEITSPRUNG“).
- **Offene Vereinsfrage Technik:** Der Bühnenlauf hat 13 aktive Technik-Figuren. Gibt es nur funktionale Crew-Karten („Lichtpult“), wären ausgerechnet die Technikleute ohne eigene Karte. Vorschlag: eine Crew-Karte je Abteilung mit freiwilligem Credit.

### Sets
- MVP: **Anno 1146** (Grün, breit, Requisiten, Duette) gegen **Creepshow** (Schwarz, Monologe, Licht und Ton). Für diese beiden Stücke liefert die App die Daten, nötig sind also nur Wald- und Sumpf-Kulissen.
- Danach kommen die Archiv-Sets aus den Drehbüchern im Google Drive (siehe Abschnitt 3, „Archiv-Drehbücher“). Ein erstes Fünf-Farben-Set könnte so aussehen: Goldfieber, Traum von Freiheit, Nexus, Malleus Maleficarum, Anno 1146.
- Romeo und Julia (Premiere 27.12.2026) und Schicksalsfäden (12 fertige Porträt-Varianten) kommen nach Weiß.

### Schlüsselwörter (MVP, alle aus Kennzahlen)

| Schlüsselwort | Bedingung | Effekt |
|---|---|---|
| Rampensau | in ≥ 40 % der Szenen des Stücks (Teilszenen zusammengefasst) | Wachsamkeit |
| Monolog | ≥ 2 Zeilen unter den längsten 5 % des Stücks | 1×/Zug: 1 Applaus → 1 Schaden |
| Stichwortgeber | ≥ 30 % Fragen | Auftritt: verbündete Rolle +1/+1 bis Zugende |
| Duett (PARTNER) | **gegenseitig** bester Partner mit ≥ 6 gemeinsamen Szenen | beide +1/+1, solange beide auf der Bühne stehen |
| Zäh | Verteidigung ≥ Angriff + 2 | blockt eine zusätzliche Rolle |
| Abgang | per Override | ziehe 1 Karte |

Designregeln:
1. Höchstens 2 Schlüsselwörter je Karte, Commons höchstens 1. **Aus Werten abgeleitete Schlüsselwörter (Zäh) zählen mit.**
2. **„Kleine Rolle, großer Auftritt“:** Rollen unter 1 % Textanteil bekommen ohne Budgetabzug einen nützlichen Auftritt-Effekt.
3. Duett nur bei gegenseitigem Bestpartner, weil die Daten asymmetrisch sind (YSABEL→MATTES, aber MATTES→ALTE EMMA). Partner, die nur als Rückseite existieren, erfüllt auch die Vorderseite (Regel über die Karten-ID).
4. Jedes Schlüsselwort hat einen **Erinnerungstext auf der Karte**, weil Amateurdarsteller keine TCG-Spieler sind.

**Schlüsselwort-Dichte (neu 25.10.):** Mit den heutigen Schwellen bekämen im Archiv 39 % aller Rollen Rampensau und 38 % Monolog. Das ist zu häufig, damit sich Schlüsselwörter besonders anfühlen; Ziel sind etwa 10–20 % je Schlüsselwort. Vorschlag: Schwellen je Stück über den Rang setzen, z. B. Rampensau nur für die 2–3 Rollen mit den meisten Szenen, Monolog nur für die längsten 2 % der Zeilen.

**Seltenheit vs. Stärke, entscheiden:** Seltenheit nach Textrang und Kosten nach Textanteil kommen aus derselben Kennzahl. Dann sind die Mythics automatisch die stärksten Karten (LUCY, GRAF kosten 6). Entweder Seltenheit an der Komplexität festmachen (Zahl der Schlüsselwörter/Effekte), oder offen „Seltenheit = Rollengröße“ sagen und die Booster-Verteilung auf Pay-to-Win-Gefühl prüfen.

### Beispielkarten (nachgezählt ohne Klammer-Regie, Werte vorläufig)

| Karte | Kennzahlen | Kosten | Werte | Text | Seltenheit |
|---|---|---|---|---|---|
| **LUCY** · Creepshow 2026 | 152 Zeilen, 2.089 Wörter, 17,8 %, 10 Szenen | 6 | 7/4 | Rampensau, Monolog | Mythic (Rang 1/24) |
| **DRUSILLA** · Creepshow | 17 Zeilen, 725 Wörter, 6,2 %, 3 Monologe, Ø 42,6 W/Zeile | 4 | 6/2 | Monolog | Rare (Rang 6/24) |
| **CLARA** · Creepshow | 132 Zeilen, 10,5 %, 11 Szenen, 32 % Fragen | 5 | 4/5 | Rampensau, Stichwortgeber | Rare (Rang 3) |
| **JUNGE // ALTE JOHANNA** · Anno 1146 | 1,9 % bzw. 5,6 %, 11 Szenen, 8 gemeinsame mit ALTE EMMA | 2, Zeitsprung {3} | 2/3 // 2/3 | Rückseite: Rampensau, Duett (ALTE EMMA) | Uncommon (Rang 9/22) |
| **JACQUES** · Creepshow | 19 Zeilen, 27 Wörter, 0,2 % | 1 | 1/2 | Auftritt: Ziehe 1 Karte | Common (Rang 22) |
| **Blitz und Donner** · Regieanweisung | Ton-Cue Creepshow | 2 | – | 2 Schaden an einer Rolle | Common |
| **Schwert, Dolch** · Requisite | Requisiten-Cue 2025 (LOTHAR) | 2 | – | angelegt +2/+0 | Common |

## 3. Kartengenerierung aus App-Daten

### Pipeline
- Neues Skript `server/scripts/build-tcg-cards.mjs` im Stil von `server/scripts/import-website-team.mjs`. Es liest offline und read-only (`?immutable=1`) aus der Sicherung.
- Rohdaten → `server/src/tcg/cards.json` → handgepflegte `server/src/tcg/overrides.json` (überschreibt nur Felder, Neuläufe bleiben stabil) → Loader mit Validierung nach dem Muster von `loadCatalog` in `server/src/runner-wardrobe.mjs`.
- Zusätzlich eine CSV und eine Balancing-Tabelle zur Durchsicht.
- **Schwellen als Konstanten mit Snapshot-Tests.** Der vorhandene Prototyp (`tcg-metrics/cards.mjs` im Scratchpad) nutzt andere Schwellen (Duett ≥ 5, Monolog ≥ 1, kein Budgetabzug) und liefert z. B. LUCY 9/4. Die Beispielkarten müssen aus genau dem Pipeline-Lauf kommen.
- **Stabile Karten-IDs:** Set-Kürzel + Sammlernummer. Decks und Overrides verweisen auf die ID. Die Drehbuch-Revision (z. B. `script-v1-5418abf42bcb8f20`) wird in `cards.json` festgehalten, damit Textänderungen der Regie nicht still Kosten verschieben.

### Datenquelle → Kartenfeld

| Quelle | Kartenfeld |
|---|---|
| Katalog-`role` aus `catalog.json` (z. B. „Graf Thaddäus von Falkenstein“, „Barde Mattes“), sonst `production.roles[].name`, sonst Override | Kartenname. Die Sprecherkennung (`VIKTOR`, `DIENER 3`) ist kein Anzeigename |
| Produktion bzw. `websitePlays{title, year, location}`. R&J hat kein `websitePlays` und kein `year` → Override | Set, Fraktion, Typzeile |
| Textanteil am Stück (Dialog-Cues ohne Klammer-Regie, Sprecher über `shared-speakers.mjs`) | **Kosten:** < 1 % = 1, < 3 % = 2, < 6 % = 3, < 9 % = 4, < 13 % = 5, sonst 6; danach Zielkurve je Fraktion erzwingen |
| Budget = 2×Kosten + 1 − 1 je Schlüsselwort; Wörter/Zeile über dem Stück-Median → mehr Angriff, sonst mehr Verteidigung; min. 1/1 | Angriff/Verteidigung |
| Szenen je Figur (Logik wie `lib/features/scripts/domain/script_document.dart`), Monologe, Fragen, gemeinsame Szenen | Schlüsselwörter |
| Textrang im Stück: 1–2 Mythic, 3–6 Rare, 7–12 Uncommon, Rest Common. **Nicht** die personenbezogenen, als PROVISIONAL markierten `minScore` des Katalogs | Seltenheit, plus Buchstabe C/U/R/M |
| Ensemble-Plätze ohne Text (9 in 2025, 12 in 2026), `ALLE`/`CHOR` | Ensemble-Spielstein |
| Cue-Kategorien lighting/audio/technical/props: nur Namen; Effekte von Hand aus der Effekt-DSL | Regieanweisungen, Requisiten. R&J hat nur 11 Ton-Cues und 0 Licht-/Requisiten-Cues, dort braucht es Handarbeit |
| `scripts.scenes[].title` (52 beschreibende Titel 2025/2026; R&J nur „Szene 1–14“) | Szenenkarten, **erst nach Freigabe der Autoren** |
| **Handgepflegte Zuordnungstabelle** Sprecherkennung ↔ Katalog-`role` ↔ Bilddatei (in `overrides.json`); der Validator meldet jede Rolle ohne Bild | Kartenbild. Es gibt keinen gemeinsamen Schlüssel, die Bilder sind nach Person benannt (`character-<vorname>-…`) |
| `casting` → `members`, Vorname, nur ohne `tcgHidden` (neues Feld analog `websiteHidden`) | Credit „gespielt von …“, im MVP aus |
| Fakten („Sommerstück 2026 · Open-Air-Bühne · 28 Szenen“), `next-theater/src/data/timeline.json`; Zitate erst nach Freigabe | Flavor-Text |

### Mengen
- **MVP: 42 eigenständige Rollenkarten.** 18 Anno (davon 3 doppelseitig, also 21 Sprecher), 24 Creepshow. 4–5 generische Sprecher (PORTRAIT 1/2, DIENER 3/4, BOTE) brauchen einen echten Namen per Override.
- Dazu 4 Ensemble-, ca. 12 Regieanweisungs- und 6–10 Requisitenkarten.
- Kostenkurven gemessen: Anno 3/8/3/6/2 (Kosten 1–5), Creepshow 8/5/5/2/2/2 (Kosten 1–6). Ungleich, in der Probe prüfen.
- Archiv: siehe „Archiv-Drehbücher“ gleich darunter. Insgesamt sind es **rund 185 Rollenkarten aus 12 Stücken** (10 Drehbücher mit 147 Rollen, dazu Creepshow und Romeo und Julia).

### Archiv-Drehbücher (aus Google Drive, Stand 25.10.)

Am 25.10. habe ich 11 Drehbücher als Text aus dem Drive geladen; 10 davon kommen ins Spiel (ohne Theater-AG 2025). Sie liegen in `~/Downloads/theater-drehbuecher/`. Der Parser `drehbuch-metrics/parse.py` liegt im Session-Scratchpad und gehört später als Eingang zu `build-tcg-cards.mjs`. Die Dateien enthalten die Vornamen der Darsteller; ins Repo kommen nur Rollen-Kennzahlen.

| Jahr | Stück | Farbe | Rollen | Wörter | Szenen | Mythic-Kandidaten (Textanteil) |
|---|---|---|---|---|---|---|
| 2018 | Bluttribut | B/G | 11 | 5.800 | 14 | Hans 17,9 %, Emma 13,6 % |
| 2020 | Der Kristall der Träume | U | 14 | 8.030 | 19 | Archibald 18,4 %, Arno 13,4 % |
| 2021 | Malleus Maleficarum (Fassung 3.1) | W/G | 14 | 8.011 | 31 | Heinrich 20,9 %, Georg 13,6 % |
| 2022 | Goldfieber (Fassung 3) | R | 16 | 6.683 | 52 Teilszenen | Kate 15,9 %, Morgan 13,8 % |
| 2023 | Sagenhaft | G/R | 9 | 2.286 | 12 | Chronistin 22,4 %, Johanna 16,3 % |
| 2023 | Traum von Freiheit | U | 19 | 7.995 | 27 | Anne 10,9 %, Sofia 10,5 % |
| 2024 | Eine höllische Herausforderung | R/B | 13 | 3.835 | 11 | Teufel 23,2 %, Lucy 19,6 % |
| 2024 | Nexus | B | 20 | 9.246 | 25 | Hunter 15,1 %, Blade 15,0 % |
| 2025 | Anno 1146 | G/W | 19 | 10.468 | 24 | Mattes 12,3 %, Konrad 9,4 % |
| 2025 | Schicksalsfäden | W/B | 12 | 3.391 | 9 | Hades 17,5 %, Atropos 11,5 % |

Gezählt wurden Rollen mit mindestens 20 Wörtern, ohne Gruppen wie ALLE oder CHOR. Dazu kommen Creepshow (24) und Romeo und Julia (ca. 13) aus der App.

- **Gegenprobe:** Für Anno 1146 zählt der Parser 10.468 Wörter, die App 10.473. Jung und Alt werden aus dem Textexport nicht getrennt; für Anno bleiben die App-Daten maßgeblich.
- **Nicht im Drive:** Die Geschichte der Black Swan (2016), Verrat im Kloster (2017) und Dystopia (2019).
- **Theater-AG 2025:** Auf Wunsch nicht im Spiel (25.10.). Das Drehbuch liegt weiter im Download-Ordner, wird aber nicht ausgewertet.
- Das Drive enthält außerdem „Theater RPG Draft“ (Nov. 2025), „Theatle“ und „Drehbuch App – Umfrage“. Diese Dateien habe ich nicht gelesen; vielleicht stehen dort frühere Spielideen.

### Was die Archivdaten an der Formel ändern
- **Kosten über den Rang im Stück statt über feste Prozent-Schwellen.** Bei kleinen Ensembles kippt die Kurve: In Sagenhaft würden 5 von 9 Rollen 6 kosten, in Bluttribut 6 von 11 mindestens 5. Die Kosten werden deshalb nach Rang auf eine feste Zielkurve je Set verteilt.
- **Monolog relativ messen.** Die feste Regel „2 Zeilen mit mindestens 60 Wörtern“ greift im Archiv nur bei Heinrich, Mattes, Hunter und Dante. Besser: die längsten 5 % der Zeilen eines Stücks.
- **Rampensau über den Szenenanteil** (mindestens 40 % der Szenen), Teilszenen zusammengefasst. Goldfieber hat 52 Teilszenen und käme mit „ab 10 Szenen“ auf 0 Treffer.

## 4. Recycling-Map

Funktionsnamen statt Zeilennummern, weil `runner-wardrobe.mjs` gerade uncommittet geändert wird.

| Baustein | Pfad | Nutzung im TCG | Reife |
|---|---|---|---|
| Katalog-Loader, Validierung | `server/src/runner-wardrobe.mjs` `loadCatalog`, `server/src/wardrobe/catalog.json` | Vorlage für den Karten-Loader; Balancing per Server-Deploy ohne App-Release | fertig |
| Bildauslieferung mit Inhaltshash, immutable | `server/src/http.mjs` (Skins `?v=`) | Kartenbilder, besser als Sprite-Atlas je Set | fertig |
| Seltenheiten, Gewichte, Gage | `catalog.json` `rarities` (7 Stufen: hellblau, blau, technik, pink, legacy, rot, gold) | 4 TCG-Seltenheiten auf 4 Farben abbilden; über Technik, Legacy und Gold entscheiden | fertig, PROVISIONAL |
| Sichere Ziehung | `runner-wardrobe.mjs` `secureRandom`, `weightedPick`, `drawItem`, `openCrate` | Booster mit Slot-Regeln. `drawWithDupes` nicht übernehmen (Mehrfachexemplare sind gewollt) | fertig, Slots fehlen |
| Walze / Beinahe-Treffer | `runner-wardrobe.mjs` `reel()` mit `nearMissChance: 0.45` (server-seitig) | **Nicht übernehmen**; TCG-Reveal ohne `reel()` | – |
| Booster-Animation | `lib/features/games/ui/crate_opening.dart` (874 Zeilen), `domain/crate_reel.dart` | Fächer-Reveal, Walze höchstens für den Rare-Slot | fertig |
| Glanz/Foil | `wardrobe_cards.dart` `ShineOverlay`, `shinyChance` 0,03–0,05 | Foil-Karten | fertig |
| Gage, Tausch, Kauf | `runner-wardrobe.mjs` `tradeCost`, `buyCost`, `tradeGage`, `buyItem` | Crafting ab dem 3. Exemplar; Besitz als `{id: anzahl}` | fertig, Umbau nötig |
| Idempotenz, Audit, Transaktionen | `theater.mjs` `action()`, `runner-wardrobe.mjs` `once()`, `store.mjs` `transaction` (BEGIN IMMEDIATE) | Jeder Zug als POST mit Idempotency-Key. `expectedVersion` gibt es nur bei Konten, für Partien neu bauen | fertig |
| Entity-Speicher | `server/src/store.mjs` | MVP `tcgMatches` per ID. Ab PvP eigene Tabellen (`all()` lädt immer die ganze Art) | fertig |
| Seed und Uhr | `runner-missions.mjs` `seeded()`, Konstruktor in `theater.mjs` mit `clock`/`random`, `SlayTheSpire2Web/web/src/core/rng.ts` (35 Zeilen) | Deterministisches Mischen, Replays, Tests | fertig |
| Spielersicht, Bots, Simulation (Muster) | `tumult/server/games/base.js` (`playerView`, `bot()`), `tumult/scripts/simulate.js` | Verdeckte Hand, KI, Bot-gegen-Bot-Balancing. Nur das Muster übernehmen | fertig (Nachbar) |
| Effekt-Warteschlange (Muster) | `SlayTheSpire2Web/web/src/core/effect-queue.ts` (185 Zeilen), `combat.ts` `requestPlay`/`processQueue` | Architekturvorlage; keine StS-Inhalte | Vorlage |
| Kartentext-Projektion, Katalogprüfung | `SlayTheSpire2Web/web/src/core/card-preview.ts` (148), `catalog-check.ts` (106) | Regeltext aus der DSL erzeugen, veränderte Werte hervorheben; Kartenvalidator | Vorlage |
| Feature-Flags | `theater.mjs` `apiFeatures`, `lib/core/app_controller.dart` `supports()` | `tcg`, `tcgDecks`, `tcgPvp` | fertig |
| Rechte | `theater.mjs` `accountPermissions` (nur `['events']`), `lib/core/account_permissions.dart` | Neues Recht `games` für Tester: Server, Admin-UI, Test | erweitern |
| Versteckter Einstieg | `secret_tap.dart`, `header_logo.dart` (5 Taps), Demo-Sperre über `controller.isDemo` | Einstieg „Kartenspiel“ in der Garderobe | fertig |
| Kartenansicht | `wardrobe_cards.dart` `WardrobeCard`, `paintItemArt` | Basis für `TcgCard` (Kosten, Werte, Typzeile, Textfeld); `paintItemArt` als Platzhalterbild | fertig, Textfeld fehlt |
| Porträts | `server/src/wardrobe/images`: 81 Porträts 512² (= 47 Basis, davon 29 Creepshow, + 34 Varianten: 22 Anno, 12 Schicksalsfäden), 81 Sprites, 7 Bühnenbilder | Kunst für Anno und Creepshow ab Tag 1 | fertig, **Datenschutz ungeklärt** |
| Drehbuch-Domäne | `mobile-scripts.mjs`, `script-engine/canonical.mjs`, `shared-speakers.mjs` (`groupWords`) | Eingang der Pipeline | fertig |
| Spielbarkeit einer Szene | `lib/features/rehearsal/domain/scene_planning.dart` `evaluateScene` | Spezifikation für „Besetzt“, in JS nachbauen | fertig (Dart) |
| Cue-Kategorien | `lib/features/scripts/domain/cue_category.dart` | Symbole für Licht, Ton, Requisite | fertig |
| Tagesmissionen | `server/src/runner-missions.mjs`, `missions_api.dart`, `missions_card.dart` | TCG-Quests | getestet, **untracked** |
| Ensemble-Strecke | `server/src/runner-ensemble.mjs` | Gemeinsame Saison, Set-Freischaltung | fertig |
| Termin-Kiste | `server/src/runner-event-crates.mjs` | Booster für **Anwesenheit** (Check-in oder Auto-Übernahme 24 h nach Termin, nicht für die Zusage) | Prototyp, **untracked** |
| Push, Deep Links | `push.mjs`, `push-kinds.mjs` (`memberPushKinds`), `deep_links.dart` | `gameTurns` „Du bist am Zug“ | fertig, erweitern |
| Android-Aktionsknöpfe | `lib/core/device_services.dart` | Herausforderung annehmen/ablehnen. Heute fest auf Termin-Zusagen verdrahtet → generalisieren | erweitern |
| Hintergrund-Worker | `server/src/index.mjs` `tick()` alle 15 s | Zugfristen. Die Schleife ist da, der Hook fehlt | erweitern |
| Client-Outbox | `lib/core/controller/pending_action.dart` (`hopelessErrorCodes`), `score_outbox.dart` | Züge puffern und idempotent nachsenden | teilweise |
| Löschpfad, Fristen | `theater.mjs` (löscht `runner*`), `server/src/retention.mjs` | Um TCG-Daten erweitern | erweitern |
| Gegnerauswahl | `lib/shared/audience/audience_pickers.dart`, `member_avatar.dart` | Herausforderung an ein Mitglied | fertig |
| Sound, Partikel, Bild-Cache | `stage_runner_sound.dart`, `stage_runner_fx.dart`, `stage_runner_look.dart` (`WardrobePictures`) | Effekte beim Ausspielen, Musik je Fraktion | fertig |
| Kontrast-Tests, Theme | `test/contrast_test.dart`, `lib/app/theme/stage_theme.dart` | Lesbarer Regeltext auf farbigen Rahmen | fertig |
| Kunst-Pipeline | `InselRPG/scripts/art/codex_image.sh`, `crownward/tools/codex-imagegen.py` | R&J und Archivrollen, **ohne Fotos von Mitgliedern als Referenz** | fertig (Nachbar) |
| Website-Rollen | `next-theater/src/data/team.json` (lokal 15 Stücke inkl. R&J, uncommittet), `timeline.json` | Archiv-Sets, Flavor | Daten, keine Kennzahlen |

Nicht recycelbar: `reference/rampenlicht` ist die Vorgänger-App (Probenplan), ohne Spielcode.

## 5. Was fehlt

Aufwand: S < 1 Tag, M 2–5 Tage, L 1–3 Wochen, XL > 3 Wochen (geschätzt).

| Lücke | Aufwand | Prio |
|---|---|---|
| Uncommittete Bühnenlauf-Arbeit committen (Stand 24.10.: ca. 70 Einträge in `git status`, HEAD 91eafd9), bevor gemeinsame Dateien angefasst werden | S | P0 |
| **Datenschutz:** Abschnitt „Spielfiguren/Kartenbilder“ in `web/privacy.html`. Die Porträts des Bühnenlaufs stehen dort heute gar nicht, die Lücke besteht also schon jetzt. Herkunft der Porträts dokumentieren | S + Klärung | P0 |
| Kurzkonzept für Vorstand und Ensemble: Figur statt Person, Abwahl `tcgHidden`, Vorschau der eigenen Karten mit Einspruch | S + Vereinsarbeit | P0 |
| Kartenpipeline mit `cards.json`, `overrides.json`, Bild-Zuordnungstabelle, Validator, Snapshot-Tests | M | P0 |
| Ein Karten-Renderer (HTML/SVG → PDF) für die Papier-Probe und später den Druck: 63×88 mm + 3 mm Beschnitt, 9 je A4 | S–M | P0 |
| Papier-Probe: 2 Decks **ohne Porträts** (Text, Werte, Symbol), Regelblatt, 3–5 Partien; Bögen danach einsammeln | S | P0 |
| **Effekt-DSL** als JSON-Schema: Auslöser (Auftritt, Abgang, statisch, aktiviert 1×/Zug), Ziele, Dauer, Bedingungen. Dauerhafte Effekte werden aus Grundwerten neu berechnet, nicht in den Zustand geschrieben. Regeltext wird aus der DSL erzeugt (eine Quelle für App, Druck und KI) | M | P0 |
| **Regel-Engine** `server/src/tcg/engine.mjs`: `initialState`, `legalActions`, `apply` → (Zustand, **Ereignisliste** für Animationen), `playerView` | L | P0 |
| Engine-Tests: Beispieltests plus **Fuzz-Tests** (ca. 10.000 Zufallspartien; Invarianten: Zonensumme = Deckgröße, keine negativen Werte, `legalActions` nie leer bei laufender Partie, Replay ergibt denselben Zustands-Hash) | M | P0 |
| Verdeckte Info: Seed nie in `playerView`, erst nach Partieende offenlegen; Test, dass die KI nur `playerView` sieht | S | P0 |
| Gierige KI mit Zeitbudget (< 50 ms/Zug, ein Node-Thread für alles); Vorausschau nur in `worker_threads` oder offline. KI-Zug kommt in derselben HTTP-Antwort | M | P0 |
| Simulator `tcg-simulate.mjs`: Gewinnquote je Deck **und je Sitzplatz**, ungenutzter Applaus | S–M | P0 |
| Routen `/games/tcg/matches*`, Flag `tcg`, Recht `games`; **eigene dauerhafte Zugliste** je Partie (Idempotenz-Ergebnisse in `requests` werden nach 14 Tagen gelöscht) | M | P0 |
| `rulesVersion` + `catalogRevision` je Partie; Regel- und Aktionstexte vom Server rendern (Android-Alpha-Clients hinken hinterher); Verhalten offener Partien beim Deploy festlegen | S | P0 |
| Flutter-Spielfeld `lib/features/games/ui/tcg/`: Karte, Hand-Fächer, Bühne, Angriff/Block, Log, Animationen aus der Ereignisliste | L | P0 |
| **Tutorial:** geskriptete erste Partie (fester Seed, erzwungene Züge), Glossar in der App | M | P0 |
| Barrierefreiheit: Seltenheit als Buchstabe/Form (Pink vs. Rot hat 1,07:1 Kontrast), `Semantics` (heute 0 in crate_opening/stage_runner), Tippen statt Ziehen, `textScaler`, „Bewegung reduzieren“ | M | P1 |
| Online-Pflicht bewusst anzeigen (die Engine läuft nur auf dem Server; Open-Air-Bühne mit schlechtem Netz) | S | P1 |
| Firebase-Sperrprüfung cachen: `verifyIdToken(token, true)` macht **bei jeder** authentifizierten Anfrage einen `getUser`-Aufruf, auch bei jedem Kartenbild. Cache ca. 60 s je uid | S | P1 |
| Kartenbilder als Sprite-Atlas je Set, Bildbudget für Flutter Web (Container 512 MB, 159 Bilder belegen heute ca. 16 MB) | S–M | P1 |
| Austritt: **nur das Bild** durch einen Platzhalter ersetzen, die Karte bleibt (sonst brechen Decks und Replays). Snapshots ohne Bild- und Personenbezug. Neuer Laufzeitabgleich Katalog ↔ `members` (heute filtert nur `disabled`) | S–M | P1 |
| Sammlung `{id: anzahl}`, Booster mit Slots, Fächer-Reveal, Crafting | M–L | P1 |
| **Ökonomie-Zahlen:** Zeit bis zur vollständigen Sammlung, Booster-Einkommen je Woche, Wechselkurs Gage ↔ TCG, Wechselwirkung mit dem Bühnenlauf | S | P1 |
| Deckbau mit Prüfung und UI (Fraktionssymbole, Kurve) | M | P1 |
| Belohnungen: Quests, Termin-Booster, Sieg-Booster mit Tagesdeckel und Deckel je Gegner | M | P1 |
| Google Play: Datensicherheitsangaben und Altersfreigabe aktualisieren; ob die Prüfung Zugang hinter Flag und Recht erwartet, ist unsicher | S | P1 |
| Eigene Tabellen `tcg_matches`, `tcg_moves`, `tcg_challenges` | M | P2 |
| Asynchrones PvP: Push-Art `gameTurns` in `memberPushKinds` und App-Einstellungen, ein Push pro Partie (Collapse-Key), Nachtruhe, eigener Android-Kanal; Deep Link; 48-h-Frist über einen neuen Hook in `tick()`; Polling mit ETag nur bei offenem Spielbildschirm | L | P2 |
| Moderation: kein Freitext, nur feste Reaktionen; Herausforderungen ablehnen, dauerhaft sperren, drosseln | S | P2 |
| Löschen bei PvP: offene Partien als Aufgabe werten, beendete beim Gegner als „ehemaliges Mitglied“ anonymisieren | S | P2 |
| Display-Schrift (OFL; heute nur Roboto), Golden-Tests (heute 0) | S | P2 |
| Statistik je Karte und Deck; bewusst **ohne** Personen-Rangliste. Das ist eine Abweichung vom Bühnenlauf, der eine Bestenliste hat | M | P2 |
| Sealed-Liga: Pool aus **10–12 Boostern** (50–60 Karten), Grund-Kulissen gibt es kostenlos dazu wie bei MTG; daraus wird ein Deck mit 40 Karten | L | P3 |
| Romeo und Julia: 13 Illustrationen, Szenentitel, Jahr/Ort per Override, Regieanweisungen von Hand | M | P3 |
| Schicksalsfäden 2025 als Set (12 Varianten vorhanden, Werte über den Kartenrat) | M | P3 |
| Szenenkarten und Zitate, erst nach Freigabe | M + Freigabe | P3 |
| Archiv-Sets aus 10 Drehbüchern (ca. 130 weitere Rollen): Parser ins Repo, Kosten über den Rang, Farbe über den Schauplatz, Kartenrat nur für die Feinabstimmung | L, schrittweise | P3 |
| Kulissen: 5 Grundländer plus ggf. Doppel-Kulissen, Engine-Regel „1 Kulisse pro Zug“, Glättung der Starthand | M | P0 |
| Echter Stack mit Priorität, Echtzeit per SSE (durch Cloudflare/Traefik ungetestet) | L | P4 |
| Physischer Druck | M + Einwilligungen | P4 |

## 6. Phasenplan

**Phase 0 – Fundament und Papier (ca. 1 Woche, 2–3 Tage Code)**
- Arbeitsstand committen. Datenschutztext und Kurzkonzept auf den Weg bringen.
- Pipeline → `cards.json` (42 Rollen + Ensemble, Regieanweisungen, Requisiten), Bildzuordnung, Renderer.
- Papier-Probe ohne Porträts. Danach Formel, Schwellen und Applaus-Deckel anpassen.

**Phase 1 – MVP „Probe gegen die KI“ (ca. 3–5 Wochen)**
- Server: DSL, Engine mit Ereignisliste, Fuzz-Tests, KI, Simulator, Routen, Flag `tcg`, Recht `games`.
- Client: Spielfeld, `TcgCard` auf Basis von `WardrobeCard`, Tutorial, Sounds aus dem Bühnenlauf, Einstieg über die Garderobe.
- Nicht enthalten: Sammlung, PvP, Zitate, Credits.
- Rollout: erst Recht `games` für Tester, dann alle freigegebenen Konten.
- **Messlatte vor Phase 2:** z. B. ≥ 8 Personen spielen in 2 Wochen je ≥ 3 Partien. Sonst hier stoppen.

**Phase 2 – Sammeln und Deckbau (ca. 2–3 Wochen)**
- Sammlung, Foil, Crafting, Starterdecks.
- Booster „Programmheft“ (5 Karten: 3 C, 1 U, 1 R+). Fraktionssymbole, Deckbau.
- Quests, Termin-Booster, Ökonomie-Zielwerte, Barrierefreiheit, Austritts-Platzhalter.

**Phase 3 – Asynchrones Duell (ca. 3 Wochen)**
- Eigene Tabellen, Herausforderungen, Push-Hygiene, Fristen, Stichwort-Fallen, Moderation.
- Sealed-Liga mit großem Pool, Ensemble-Strecke „gespielte Partien“ schaltet Sets frei.

**Phase 4 – Inhalte (fortlaufend)**
- Fünf-Farben-Set aus dem Archiv, zum Beispiel Goldfieber, Traum von Freiheit, Nexus, Malleus Maleficarum und Anno 1146.
- Romeo und Julia zur Premiere am 27.12.2026, Schicksalsfäden, Crew und Bühnenbild, Szenen und Zitate nach Freigabe, die übrigen Archivstücke.

**Phase 5 – Optional**
- Stack, Echtzeit, Kulissen-Länder, Druck mit Einwilligung.

## 7. Risiken und rechtliche Punkte

- **Personen fühlen sich bewertet** (JACQUES 1/2 vs. LUCY 7/4). Gegenmittel: Karte = Figur, „kleine Rolle, großer Auftritt“, Credits aus, Vorschau mit Einspruch, keine Personen-Rangliste.
- **DSGVO / KUG:** Die Porträts sind Illustrationen erkennbarer Mitglieder, nach Vornamen benannt. Eine dokumentierte Rechtsgrundlage gibt es bisher nicht. Für Öffentliches, Gedrucktes oder Teilbares braucht es Einwilligungen (bei Minderjährigen die der Eltern; ob es Minderjährige gibt, ist aus den Daten nicht ableitbar). Nicht auf das öffentliche tumult.logge.top.
- **Kunst-Pipeline:** Keine Mitgliederfotos als Referenz an Codex/OpenAI (Drittland). Wie die vorhandenen Porträts entstanden sind, ist undokumentiert.
- **Urheberrecht:** Die MIT-Lizenz in `server/src/script-engine/LICENSE.Skript` gilt nur für Code. Zitate und Szenentitel brauchen die Freigabe der Autoren bzw. des Verlags. Shakespeare ist gemeinfrei, die gespielte Fassung vielleicht nicht. „Creepshow“ als Set-Name wegen Titelschutz meiden (unsicher).
- **Glücksspiel-Muster:** Ohne Echtgeld unkritisch (ungeprüft). Trotzdem kein Beinahe-Treffer, Belohnungen deckeln.
- **Technik:** Ein Node-Thread, 512 MB, 1 CPU → KI mit Zeitbudget, Simulation offline. Ein voller Stack macht Async zäh. Firebase-Aufruf je Anfrage.
- **Kleiner Spielerkreis:** 27 Konten, 6 aktive Bühnenlauf-Spieler → erst KI, dann Async, Messlatte.
- **Repo-Kollision:** `runner-*` ist in Arbeit. Das TCG bekommt eigene Ordner; `http.mjs`/`theater.mjs` erst nach dem Commit anfassen.

## 8. Entscheidungen

### Game Design
1. **Kampf im asynchronen Spiel:** Kulissen als Länder sind entschieden (25.10.). Wird wie bei MTG geblockt, oder gilt ein Kampf wie bei Hearthstone?
2. **Seltenheit:** Komplexität (empfohlen) oder Rollengröße?
3. **Schlüsselwort-Dichte:** Schwellen je Stück über den Rang (empfohlen) oder feste Schwellen?
4. **Farbsignaturen:** Passen Beifall, Traumsequenz, Wiedergänger, Goldrausch und Dorffest?
5. **Farbzuordnung:** Wird Malleus Maleficarum Weiß? Wird Creepshow Schwarz? Wohin kommt Romeo und Julia?
6. **Kulissennamen:** Wüste, Piratenbucht, Kanalisation, Klosterhof und Wald, oder echte Ortsnamen aus den Stücken?
7. **Technikleute:** eigene Crew-Karten je Abteilung?
8. **Freigabe der Werte:** Regie, Vorstand oder alle? Kartenrat fürs Archiv?
9. **PvP-Format:** Sealed (empfohlen), Constructed oder beides? Elo ja/nein?
10. **Ökonomie:** gemeinsame Gage mit dem Bühnenlauf oder eigene Währung?
11. **Romeo und Julia** schon zur Premiere am 27.12.2026?

### Organisatorisch
1. **Reichweite:** nur intern in der App, oder später öffentlich/gedruckt? Davon hängen Einwilligungen, Bildstil und Set-Namen ab.
2. **Credit:** standardmäßig aus mit Zuwahl (empfohlen) oder an mit Abwahl?
3. **Textrechte:** Wer hat Anno 1146 und Creepshow geschrieben, holen wir eine Freigabe?
4. **Minderjährige** im Ensemble?
5. **Einstieg:** versteckt über die Garderobe oder regulärer Menüpunkt?
6. **Alte Drehbücher:** Gibt es Black Swan (2016), Verrat im Kloster (2017) und Dystopia (2019) noch irgendwo?

Entschieden am 25.10.: Kulissen als Länder; die Theater-AG 2025 kommt nicht ins Spiel.
