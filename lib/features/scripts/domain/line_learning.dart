import '../../../core/json.dart';
import 'script_document.dart';

/// Collective speakers that stand for no fixed set of roles; mirrors
/// `isGroupSpeaker` in server/src/shared-speakers.mjs.
const _groupSpeakers = {
  'ALLE',
  'BEIDE',
  'CHOR',
  'ENSEMBLE',
  'GRUPPE',
  'STIMMEN',
  'ALLE ANDEREN',
};

/// Whether [role] is a group speaker like "ALLE" or "CHOR". Numbered roles
/// such as "ENSEMBLE 3" are single roles.
bool isGroupSpeaker(String role) =>
    _groupSpeakers.contains(role.trim().toUpperCase().replaceAll(_space, ' '));
final _space = RegExp(r'\s+');

/// One question of the cue drill: the [prompt] (the line before) and the
/// member's own [line], with the stage [directions] in between as context.
class LearnCard {
  const LearnCard({
    required this.line,
    this.prompt,
    this.promptIsOwn = false,
    this.directions = const [],
    this.group = false,
  });

  /// The own line the member says.
  final ScriptCue line;

  /// The dialogue line right before [line] in the same scene; null at the
  /// start of a scene.
  final ScriptCue? prompt;

  /// Whether [prompt] is another own line (the member continues).
  final bool promptIsOwn;

  /// Stage directions between [prompt] and [line], in script order.
  final List<ScriptCue> directions;

  /// Whether [line] belongs to the member only as a group ("ALLE").
  final bool group;

  String get sceneId => line.sceneId;
}

/// The own lines of [roles] as cue cards, in script order. A line spoken
/// together ("ROMEO & JULIA") counts for each of its roles; group lines
/// ("ALLE", "CHOR") only with [includeGroups]. Only scenes in [sceneIds] are
/// used when given. Directions are context, never a card of their own.
List<LearnCard> learnCards(
  ScriptDocument document,
  Set<String> roles, {
  bool includeGroups = true,
  Set<String>? sceneIds,
}) {
  if (roles.isEmpty) return const [];
  final cues = document.cues;
  bool spoken(ScriptCue cue) =>
      cue.kind == 'dialogue' &&
      cue.text.trim().isNotEmpty &&
      cue.spokenByAny(roles);
  bool grouped(ScriptCue cue) =>
      includeGroups &&
      cue.kind == 'dialogue' &&
      cue.text.trim().isNotEmpty &&
      cue.roles.isNotEmpty &&
      cue.roles.every(isGroupSpeaker);
  final cards = <LearnCard>[];
  for (var index = 0; index < cues.length; index++) {
    final cue = cues[index];
    if (sceneIds != null && !sceneIds.contains(cue.sceneId)) continue;
    final own = spoken(cue), group = !own && grouped(cue);
    if (!own && !group) continue;
    ScriptCue? prompt;
    final directions = <ScriptCue>[];
    for (var back = index - 1; back >= 0; back--) {
      final before = cues[back];
      if (before.sceneId != cue.sceneId) break;
      if (before.kind == 'direction' && before.text.trim().isNotEmpty) {
        directions.insert(0, before);
      } else if (before.kind == 'dialogue' && before.text.trim().isNotEmpty) {
        prompt = before;
        break;
      }
    }
    cards.add(
      LearnCard(
        line: cue,
        prompt: prompt,
        promptIsOwn: prompt != null && (spoken(prompt) || grouped(prompt)),
        directions: directions,
        group: group,
      ),
    );
  }
  return cards;
}

/// Whether the script has group lines ("ALLE") worth a switch.
bool hasGroupLines(ScriptDocument document) => document.cues.any(
  (cue) =>
      cue.kind == 'dialogue' &&
      cue.roles.isNotEmpty &&
      cue.roles.every(isGroupSpeaker),
);

/// The first-letter hint: every word shrinks to its first letter, the
/// punctuation stays ("Das würde mich freuen." → "D w m f.").
String initialsHint(String text) => text
    .replaceAllMapped(
      _word,
      (match) => String.fromCharCode(match[0]!.runes.first),
    )
    .replaceAll(_space, ' ')
    .trim();
final _word = RegExp(r"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*", unicode: true);

/// How the drill is ordered.
enum LearnOrder {
  script('script', 'Stückfolge'),
  weakFirst('weak', 'Schwache zuerst');

  const LearnOrder(this.code, this.label);
  final String code, label;
  static LearnOrder fromCode(Object? code) =>
      values.where((order) => order.code == code).firstOrNull ?? script;
}

/// The learning state of one line on this device: a Leitner [box] from 0
/// (new or missed) to [LearnProgress.masteredBox].
class LineProgress {
  const LineProgress({
    this.box = 0,
    this.seen = 0,
    this.known = 0,
    this.textHash = '',
  });
  final int box, seen, known;

  /// Hash of the line text when it was rated; a changed text starts over.
  final String textHash;

  bool get isNew => seen == 0;
  bool get mastered => box >= LearnProgress.masteredBox;

  factory LineProgress.fromJson(Object? json) {
    final list = jsonList(json);
    return LineProgress(
      box: list.isNotEmpty ? intValue(list[0]) : 0,
      seen: list.length > 1 ? intValue(list[1]) : 0,
      known: list.length > 2 ? intValue(list[2]) : 0,
      textHash: list.length > 3 ? textValue(list[3]) : '',
    );
  }
  List<Object> toJson() => [box, seen, known, textHash];
}

/// Learning progress of one production, kept per line on this device.
class LearnProgress {
  const LearnProgress([this.lines = const {}]);

  /// From the box a line counts as known by heart.
  static const masteredBox = 3;

  final Map<String, LineProgress> lines;

  factory LearnProgress.fromJson(Object? json) => LearnProgress({
    for (final entry in jsonMap(json).entries)
      entry.key: LineProgress.fromJson(entry.value),
  });
  JsonMap toJson() => {
    for (final entry in lines.entries) entry.key: entry.value.toJson(),
  };

  /// The progress of [cue]; a line whose text changed since counts as new.
  LineProgress of(ScriptCue cue) {
    final saved = lines[cue.id];
    return saved == null || saved.textHash != textHash(cue.text)
        ? const LineProgress()
        : saved;
  }

  /// The progress after rating [cue]: a known line moves up one box, a
  /// missed one starts again at the bottom.
  LearnProgress rate(ScriptCue cue, {required bool known}) {
    final before = of(cue);
    return LearnProgress({
      ...lines,
      cue.id: LineProgress(
        box: known ? (before.box + 1).clamp(0, masteredBox) : 0,
        seen: before.seen + 1,
        known: before.known + (known ? 1 : 0),
        textHash: textHash(cue.text),
      ),
    });
  }

  /// Counts of [cards] that are new, to practise and known.
  ({int fresh, int weak, int mastered}) summary(Iterable<LearnCard> cards) {
    var fresh = 0, weak = 0, mastered = 0;
    for (final card in cards) {
      final line = of(card.line);
      if (line.isNew) {
        fresh++;
      } else if (line.mastered) {
        mastered++;
      } else {
        weak++;
      }
    }
    return (fresh: fresh, weak: weak, mastered: mastered);
  }

  /// A stable FNV-1a hash of [text], the same on every run and platform.
  static String textHash(String text) {
    var hash = 0x811c9dc5;
    for (final unit in text.trim().codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16);
  }
}

/// The cards of one drill in the order they are asked: script order or the
/// weakest first, optionally without the lines already known.
List<LearnCard> learnQueue(
  List<LearnCard> cards,
  LearnProgress progress, {
  LearnOrder order = LearnOrder.script,
  bool skipMastered = false,
}) {
  final queue = [
    for (final card in cards)
      if (!skipMastered || !progress.of(card.line).mastered) card,
  ];
  if (order == LearnOrder.weakFirst) {
    // Missed lines first, then new ones, then the rest; stable otherwise.
    int rank(LearnCard card) {
      final line = progress.of(card.line);
      if (line.isNew) return 1;
      return line.box == 0 ? 0 : line.box + 1;
    }

    final position = {for (var i = 0; i < queue.length; i++) queue[i]: i};
    queue.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : position[a]!.compareTo(position[b]!);
    });
  }
  return queue;
}

/// A running drill: the current card, the answers so far and missed cards
/// coming back a few cards later.
class LearnSession {
  LearnSession(List<LearnCard> cards) : _queue = List.of(cards);

  /// How many cards later a missed line comes back.
  static const repeatAfter = 3;

  final List<LearnCard> _queue;
  int _position = 0;
  int known = 0, again = 0;

  /// Lines missed at least once in this drill, in script order of asking.
  final List<LearnCard> missed = [];

  int get length => _queue.length;
  int get position => _position;
  bool get finished => _position >= _queue.length;
  LearnCard? get current => finished ? null : _queue[_position];

  /// Records the answer to the current card and moves on. A missed card is
  /// asked again [repeatAfter] cards later, or at the end.
  void answer({required bool known}) {
    final card = current;
    if (card == null) return;
    if (known) {
      this.known++;
    } else {
      again++;
      if (!missed.contains(card)) missed.add(card);
      final at = (_position + 1 + repeatAfter).clamp(0, _queue.length);
      _queue.insert(at, card);
    }
    _position++;
  }
}
