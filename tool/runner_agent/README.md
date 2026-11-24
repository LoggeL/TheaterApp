# Bühnenlauf offline spielen lassen

Der Agent steuert die Figur über dieselbe Halten/Loslassen-Eingabe wie die App. Die Spielklasse `StageRunner` erzeugt die Hindernisse und zählt Meter, Sammelobjekte und Kollisionen. Das Werkzeug läuft lokal ohne Konto oder Ranglisteneintrag.

Aus dem Projektverzeichnis spielt dieser Befehl den Beispiellauf mit 4.445 Punkten bis zur Kollision nach.

```sh
dart run tool/runner_agent.dart eval 500054 1 123001014
```

Der erste Seed bestimmt die Strecke, der zweite das Reaktions- und Eingabetiming. Der Standardwert für die sichtbare Breite ist 2,1 Bühnenhöhen, wie auf einer 840 × 400 großen Spielfläche. Die schmalste Ansicht zeigt 1,6 Bühnenhöhen. Die CSV enthält unter anderem die Zahl der einzelnen Tastendrücke (`taps`) und die Zeit mit tatsächlichem Bodenkontakt (`groundSeconds`). Die Zusammenfassung berechnet Bodenanteil und Tastendrücke pro Minute über die gesamte Spielzeit aller Läufe. Beide Befehle verwenden dieselben ersten 100 Strecken und dieselben Motor-Seeds.

```sh
dart run tool/runner_agent.dart eval 2010000 100 123010000 2.1
dart run tool/runner_agent.dart eval 2010000 100 123010000 1.6
```

## Wahrnehmung und Eingabe

Bei 60 Spielschritten pro Sekunde beobachtet der Agent die sichtbare Bühne 15-mal pro Sekunde. Die erfassten Positionen sind auf ungefähr zwei bis vier Pixel einer 400 Pixel hohen Bühne gerundet. Eine Beobachtung steht erst zehn bis vierzehn Spielschritte nach der Aufnahme zur Verfügung. Bis dahin kann der Agent die eigene Bewegung anhand seiner bisherigen Eingaben abschätzen.

Ein Wechsel zwischen Halten und Loslassen bindet die Eingabe für zufällig acht bis elf Spielschritte (133 bis 183 ms). Danach kann der Agent die Geste verlängern. Sein Bewegungsmodell betrachtet die nächsten 0,75 Sekunden auf Basis der zuletzt wahrgenommenen Hindernisse. Auf freier Strecke bleibt die Taste losgelassen, auch wenn ein Sammelobjekt über der Figur hängt. Der Agent plant den Absprung für die Füße der Figur. Sind bei hohem Tempo weniger als 0,9 Sekunden Strecke einsehbar oder folgt ein Bodenhindernis zu bald, bleibt er in der Luft, bis wieder Platz zum Landen ist. Diese Zeitgrenzen sind gewählte Modellparameter. Ein Abgleich mit aufgezeichneten menschlichen Läufen steht aus.

## Training

```sh
dart run tool/runner_agent.dart train /tmp/buehnenlauf-policy.json
```

Die Cross-Entropy-Methode passt sechs Gewichte an, darunter die bevorzugte Flughöhe, den Abstand zu Hindernissen und wie stark sich die Figur für ein Sammelobjekt von ihrer üblichen Höhe entfernt. Pro Generation spielen 14 Kandidaten auf denselben vier Trainingsstrecken. Die besten vier bestimmen die Verteilung für die nächste Generation. Nach zwölf Generationen wird der beste Kandidat aus der separaten Validierung gespeichert.

Bis 4.000 Punkte zählt jeder Punkt voll zur Trainingsbelohnung, darüber mit Faktor 0,2. Die Belohnung steigt mit der Zeit am Boden und sinkt bei mehr als einem Tastendruck pro Sekunde. Das Training endet pro Episode bei der Kollision oder bei 6.500 Punkten. Bei der Auswertung läuft das Spiel bis zur tatsächlichen Kollision. Trainingsstrecken verwenden Seeds unter 500000, die Validierung verwendet 500000 bis 500015 als separate Strecken. Für den Vorher-Nachher-Vergleich starten die Strecken bei 2010000 und die Motor-Seeds bei 123010000.

## Video rendern

Der Export benötigt Flutter und `ffmpeg`. Er zeichnet den Lauf mit dem Bühnen-Renderer der App auf. Über der Bühne stehen Punktzahl, Meter, Spielzeit und der aktuelle Tastenzustand.

```sh
flutter test --no-pub tool/runner_agent/render_replay_test.dart \
  --dart-define=COURSE=500054 --dart-define=MOTOR=123001014 \
  --dart-define=EXPECTED_SCORE=4445 --dart-define=REPLAY_OUT=/tmp/buehnenlauf-4445.mp4
```
