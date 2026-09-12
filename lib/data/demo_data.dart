import '../core/models.dart';

/// Entirely fictional content. Never inferred from the theatre's member records.
/// One captured date anchors all fixtures, making tests reproducible.
class DemoData {
  factory DemoData({DateTime? now}) {
    final captured = now ?? DateTime.now();
    return DemoData._(DateTime(captured.year, captured.month, captured.day));
  }
  DemoData._(this.today);
  final DateTime today;
  static const mainProductionId = 'demo-midnight';
  static const secondProductionId = 'demo-foyer';

  DateTime _at(int day, int hour, [int minute = 0]) =>
      today.add(Duration(days: day, hours: hour, minutes: minute));

  JsonMap snapshot() {
    final events = [
      TheaterEvent(
        id: 'demo-rehearsal',
        title: 'Szenenprobe · Der erste Auftritt',
        startsAt: _at(1, 19),
        endsAt: _at(1, 21),
        time: '19:00–21:00',
        place: 'Kolpingheim · Großer Saal',
        group: 'Ensemble',
        kind: 'rehearsal',
        attendeeCount: 12,
        productionId: mainProductionId,
        sceneIds: const ['1', '2'],
      ),
      TheaterEvent(
        id: 'demo-tech',
        title: 'Licht an! · Technikdurchlauf',
        startsAt: _at(3, 18, 30),
        endsAt: _at(3, 20, 30),
        time: '18:30–20:30',
        place: 'Kolpingheim · Bühne',
        group: 'Technik & Ensemble',
        kind: 'technical',
        tone: 'green',
        attendeeCount: 8,
        response: 'yes',
        productionId: mainProductionId,
        sceneIds: const ['3', '4'],
      ),
      TheaterEvent(
        id: 'demo-costume',
        title: 'Kostümprobe & Requisiten',
        startsAt: _at(5, 14),
        endsAt: _at(5, 16),
        time: '14:00–16:00',
        place: 'Kolpingheim · Fundus',
        group: 'Alle',
        kind: 'costume',
        tone: 'violet',
        attendeeCount: 10,
        productionId: mainProductionId,
      ),
      TheaterEvent(
        id: 'demo-full',
        title: 'Einmal alles · Durchlaufprobe',
        startsAt: _at(8, 19),
        endsAt: _at(8, 22),
        time: '19:00–22:00',
        place: 'Kolpingheim · Großer Saal',
        group: 'Alle',
        kind: 'rehearsal',
        attendeeCount: 16,
        productionId: mainProductionId,
        sceneIds: const ['1', '2', '3', '4'],
      ),
      TheaterEvent(
        id: 'demo-premiere',
        title: 'Premiere · Wenn das Licht angeht',
        startsAt: _at(16, 19, 30),
        endsAt: _at(16, 22),
        time: '19:30–22:00',
        place: 'Kolpingheim · Bühne',
        group: 'Alle',
        kind: 'performance',
        tone: 'pink',
        attendeeCount: 18,
        locked: true,
        response: 'yes',
        productionId: mainProductionId,
      ),
    ];
    return {
      'apiVersion': 1,
      'user': const AppUser(
        id: 'demo-alex',
        name: 'Alex Bühnenfreund',
        email: 'demo@example.invalid',
        role: 'admin',
        group: 'Ensemble',
      ).toJson(),
      'events': events.map((e) => e.toJson()).toList(),
      'attendanceByEvent': {'demo-tech': 'yes', 'demo-premiere': 'yes'},
      'declineReasons': <String, String>{},
      'absences': <dynamic>[],
      'polls': <dynamic>[],
      'members': const [
        TheaterMember(
          id: 1,
          name: 'Alex Bühnenfreund',
          group: 'Ensemble',
          initials: 'AB',
        ),
        TheaterMember(
          id: 2,
          name: 'Robin Spielmann',
          group: 'Ensemble',
          initials: 'RS',
        ),
        TheaterMember(
          id: 3,
          name: 'Toni Lichtblick',
          group: 'Technik',
          initials: 'TL',
        ),
        TheaterMember(
          id: 4,
          name: 'Kim Kulisse',
          group: 'Regie',
          initials: 'KK',
        ),
        TheaterMember(
          id: 5,
          name: 'Sam Vorhang',
          group: 'Ensemble',
          initials: 'SV',
        ),
      ].map((e) => e.toJson()).toList(),
      'checkinsByEvent': <String, dynamic>{},
      'memberAttendanceByEvent': <String, dynamic>{},
      'reminders': {'dayBefore': true, 'twoHours': true, 'changes': true},
      'productions': [
        Production(
          id: mainProductionId,
          title: 'Wenn das Licht angeht',
          subtitle: 'Fiktives Probestück · vier Szenen',
          revision: 'demo-1',
          roles: script(mainProductionId).roles,
          sceneCount: 4,
        ).toJson(),
        Production(
          id: secondProductionId,
          title: 'Fünf Minuten im Foyer',
          subtitle: 'Fiktives Probestück · eine Szene',
          revision: 'demo-1',
          roles: script(secondProductionId).roles,
          sceneCount: 1,
        ).toJson(),
      ],
      'capabilities': {'pushConfigured': false, 'liveFocus': true},
    };
  }

  ScriptDocument script(String productionId) {
    if (productionId == secondProductionId) {
      return ScriptDocument(
        productionId: productionId,
        revision: 'demo-1',
        scenes: const [
          ScriptScene(
            id: '1',
            title: 'Eine Garderobenmarke zu viel',
            ordinal: 0,
            roles: ['LENA', 'OSKAR'],
          ),
        ],
        roles: const [
          ScriptRole(id: 'LENA', name: 'Lena', actor: 'Alex Bühnenfreund'),
          ScriptRole(id: 'OSKAR', name: 'Oskar', actor: 'Robin Spielmann'),
        ],
        cues: _cues([
          [
            '1',
            'direction',
            '',
            'Ein leerer Garderobentresen. Auf ihm liegen zwei völlig gleiche Hüte.',
          ],
          [
            '1',
            'dialogue',
            'LENA',
            'Es gibt ein kleines Problem mit deiner Garderobenmarke.',
          ],
          ['1', 'dialogue', 'OSKAR', 'Ich habe gar keinen Mantel abgegeben.'],
          ['1', 'dialogue', 'LENA', 'Eben. Dafür hast du jetzt drei.'],
          ['1', 'direction', '', 'Oskar betrachtet die Hüte.'],
          [
            '1',
            'dialogue',
            'OSKAR',
            'Dann nehme ich den, der zu meinem Hut passt.',
          ],
          ['1', 'dialogue', 'LENA', 'Welcher davon ist dein Hut?'],
          ['1', 'dialogue', 'OSKAR', 'Das ist das etwas größere Problem.'],
          ['1', 'audio', '', 'Ein Gong aus dem Saal.'],
          ['1', 'lighting', '', 'Langsam auf Schwarz.'],
        ]),
      );
    }
    return ScriptDocument(
      productionId: mainProductionId,
      revision: 'demo-1',
      scenes: const [
        ScriptScene(
          id: '1',
          title: 'Ein Schlüssel fehlt',
          ordinal: 0,
          roles: ['LENA', 'OSKAR'],
        ),
        ScriptScene(
          id: '2',
          title: 'Hinter dem Vorhang',
          ordinal: 1,
          roles: ['LENA', 'OSKAR', 'MIRA'],
        ),
        ScriptScene(
          id: '3',
          title: 'Fünf Minuten bis zum Gong',
          ordinal: 2,
          roles: ['LENA', 'OSKAR', 'MIRA'],
        ),
        ScriptScene(
          id: '4',
          title: 'Das ist unser Zeichen',
          ordinal: 3,
          roles: ['LENA', 'OSKAR', 'MIRA'],
        ),
      ],
      roles: const [
        ScriptRole(id: 'LENA', name: 'Lena', actor: 'Alex Bühnenfreund'),
        ScriptRole(id: 'OSKAR', name: 'Oskar', actor: 'Robin Spielmann'),
        ScriptRole(id: 'MIRA', name: 'Mira', actor: 'Sam Vorhang'),
      ],
      cues: _cues([
        ['1', 'scene', '', 'Szene 1 · Ein Schlüssel fehlt'],
        ['1', 'lighting', '', 'LX 01 · Warmes Arbeitslicht, Bühne 40 %.'],
        [
          '1',
          'direction',
          '',
          'Ein kleiner Theaterraum am späten Nachmittag. LENA steht vor einer verschlossenen Kiste. OSKAR balanciert zwei Kaffeebecher.',
        ],
        [
          '1',
          'props',
          '',
          'Requisite: verschlossene Holzkiste, Schlüsselbund, zwei leere Becher.',
        ],
        ['1', 'dialogue', 'LENA', 'Sag bitte, dass du den Schlüssel hast.'],
        ['1', 'dialogue', 'OSKAR', 'Ich habe Kaffee. Das ist fast dasselbe.'],
        [
          '1',
          'dialogue',
          'LENA',
          'Nur wenn Kaffee neuerdings Schlösser öffnet.',
        ],
        [
          '1',
          'direction',
          '',
          'OSKAR stellt die Becher ab und tastet seine Taschen ab. Ein einzelner Knopf fällt zu Boden.',
        ],
        [
          '1',
          'dialogue',
          'OSKAR',
          'Ein Knopf. Zwei Bonbons. Und die feste Überzeugung, dass der Schlüssel gestern noch hier war.',
        ],
        ['1', 'dialogue', 'LENA', 'In der Kiste liegt unser gesamtes Finale.'],
        [
          '1',
          'dialogue',
          'OSKAR',
          'Dann haben wir wenigstens einen spannenden Schluss.',
        ],
        ['1', 'audio', '', 'SFX 01 · Leises Klopfen von hinter dem Vorhang.'],
        [
          '1',
          'direction',
          '',
          'Beide sehen zum Vorhang. Pause. Noch einmal Klopfen.',
        ],
        ['1', 'dialogue', 'LENA', 'Das stand nicht im Ablauf.'],
        [
          '1',
          'dialogue',
          'OSKAR',
          'Seit wann hält sich hier jemand an den Ablauf?',
        ],
        ['2', 'scene', '', 'Szene 2 · Hinter dem Vorhang'],
        [
          '2',
          'lighting',
          '',
          'LX 02 · Seitenlicht links auf 60 %, Arbeitslicht halten.',
        ],
        [
          '2',
          'direction',
          '',
          'MIRA schiebt den Vorhang beiseite. Sie trägt einen viel zu großen Hut und hält einen Plan verkehrt herum.',
        ],
        ['2', 'dialogue', 'MIRA', 'Ich habe gute Nachrichten.'],
        ['2', 'dialogue', 'LENA', 'Du hast den Schlüssel?'],
        [
          '2',
          'dialogue',
          'MIRA',
          'Noch besser: Ich weiß jetzt, wo er nicht ist.',
        ],
        [
          '2',
          'dialogue',
          'OSKAR',
          'Das grenzt die Sache immerhin auf den Rest der Welt ein.',
        ],
        [
          '2',
          'direction',
          '',
          'MIRA legt den Plan auf die Kiste. Alle drei beugen sich darüber.',
        ],
        [
          '2',
          'dialogue',
          'MIRA',
          'Jemand hat die Umbaupläne mit dem Getränkezettel vertauscht.',
        ],
        [
          '2',
          'dialogue',
          'LENA',
          'Deshalb sollte die Treppe also neben die Apfelschorle.',
        ],
        [
          '2',
          'props',
          '',
          'Requisite: zwei unterschiedliche Papierpläne; einer mit gezeichneter Treppe.',
        ],
        ['2', 'dialogue', 'OSKAR', 'Die Treppe steht übrigens schon.'],
        ['2', 'dialogue', 'MIRA', 'Wo?'],
        ['2', 'dialogue', 'OSKAR', 'Neben der Apfelschorle.'],
        [
          '2',
          'direction',
          '',
          'Ein kurzer Blickwechsel. Dann müssen alle drei lachen.',
        ],
        [
          '2',
          'dialogue',
          'LENA',
          'Gut. Erst die Kiste. Dann die Treppe. Dann die Welt retten.',
        ],
        ['3', 'scene', '', 'Szene 3 · Fünf Minuten bis zum Gong'],
        [
          '3',
          'audio',
          '',
          'SFX 02 · Gedämpfte Stimmen des ankommenden Publikums, leise unterlegen.',
        ],
        [
          '3',
          'lighting',
          '',
          'LX 03 · Warmes Vorderlicht auf 70 %, Seitenlicht aus.',
        ],
        ['3', 'dialogue', 'MIRA', 'Draußen sitzen schon die ersten.'],
        ['3', 'dialogue', 'OSKAR', 'Vielleicht wollen sie nur Kaffee.'],
        [
          '3',
          'dialogue',
          'LENA',
          'Wir haben keinen Schlüssel, kein Finale und genau fünf Minuten.',
        ],
        [
          '3',
          'direction',
          '',
          'MIRA setzt sich auf die Kiste. Der Deckel hebt sich an einer Ecke leicht an.',
        ],
        [
          '3',
          'dialogue',
          'MIRA',
          'Hat eigentlich schon jemand versucht, sie einfach aufzumachen?',
        ],
        [
          '3',
          'direction',
          '',
          'Stille. LENA hebt den Deckel. Die Kiste ist offen.',
        ],
        [
          '3',
          'dialogue',
          'OSKAR',
          'Ich wollte euch die Überraschung nicht verderben.',
        ],
        ['3', 'dialogue', 'LENA', 'Sie war die ganze Zeit offen.'],
        [
          '3',
          'dialogue',
          'MIRA',
          'Manchmal ist das Problem nur die Geschichte, die wir darüber erzählen.',
        ],
        [
          '3',
          'dialogue',
          'OSKAR',
          'Schreib das auf. Das klingt wie unser neues Finale.',
        ],
        [
          '3',
          'props',
          '',
          'Aus der Kiste: ein kleines rotes Tuch und drei Texthefte.',
        ],
        [
          '3',
          'technical',
          '',
          'Bereitschaft: Vorhang, Lichtwechsel LX 04 und Gong SFX 03.',
        ],
        ['4', 'scene', '', 'Szene 4 · Das ist unser Zeichen'],
        [
          '4',
          'direction',
          '',
          'Alle drei stehen nebeneinander. LENA verteilt die Texthefte, behält aber selbst keines.',
        ],
        ['4', 'dialogue', 'OSKAR', 'Brauchst du deinen Text nicht?'],
        [
          '4',
          'dialogue',
          'LENA',
          'Den Anfang weiß ich. Für den Rest habe ich euch.',
        ],
        ['4', 'dialogue', 'MIRA', 'Und falls wir hängen bleiben?'],
        ['4', 'dialogue', 'OSKAR', 'Dann trinken wir sehr überzeugend Kaffee.'],
        [
          '4',
          'audio',
          '',
          'SFX 03 · Ein klarer Theatergong. Publikumsatmosphäre ausblenden.',
        ],
        [
          '4',
          'lighting',
          '',
          'LX 04 · Bühnenlicht weich auf 100 %, Saallicht aus.',
        ],
        [
          '4',
          'direction',
          '',
          'LENA atmet durch. MIRA legt ihr kurz die Hand auf die Schulter. OSKAR richtet seinen Kragen.',
        ],
        ['4', 'dialogue', 'LENA', 'Das ist unser Zeichen.'],
        ['4', 'dialogue', 'MIRA', 'Dann gehen wir.'],
        ['4', 'dialogue', 'OSKAR', 'Zusammen.'],
        [
          '4',
          'direction',
          '',
          'Sie treten nach vorne. Der Vorhang öffnet sich.',
        ],
        [
          '4',
          'lighting',
          '',
          'LX 05 · Schlussbild halten, nach drei Sekunden langsam auf Schwarz.',
        ],
      ]),
    );
  }

  List<ScriptCue> _cues(List<List<String>> rows) => rows.indexed
      .map(
        (entry) => ScriptCue(
          id: 'demo-cue-${entry.$1}',
          sceneId: entry.$2[0],
          ordinal: entry.$1,
          kind: entry.$2[1],
          role: entry.$2[2],
          text: entry.$2[3],
          microphone: switch (entry.$2[2]) {
            'LENA' => '1',
            'OSKAR' => '2',
            'MIRA' => '3',
            _ => '',
          },
        ),
      )
      .toList();
}
