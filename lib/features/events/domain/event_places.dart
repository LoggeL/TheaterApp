import 'theater_event.dart';

/// Places of [events], each once, most used first; ties go to the place used
/// most recently. Spelling variants that differ only in case or surrounding
/// spaces count as one place and keep the most recent spelling.
List<String> knownPlaces(Iterable<TheaterEvent> events) {
  final stats = <String, _PlaceStats>{};
  for (final event in events) {
    final place = event.place.trim();
    if (place.isEmpty) continue;
    final stat = stats.putIfAbsent(place.toLowerCase(), () => _PlaceStats());
    stat.count++;
    final at = event.startsAt;
    if (stat.latest == null || (at != null && at.isAfter(stat.latest!))) {
      stat
        ..latest = at ?? stat.latest
        ..spelling = place;
    }
    stat.spelling ??= place;
  }
  final ranked = stats.values.toList()
    ..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      final byDate = (b.latest ?? DateTime(0)).compareTo(
        a.latest ?? DateTime(0),
      );
      if (byDate != 0) return byDate;
      return a.spelling!.compareTo(b.spelling!);
    });
  return [for (final stat in ranked) stat.spelling!];
}

/// The entries of [known] that fit what was typed into the place field:
/// those starting with [query] first, then those containing it, each in the
/// order of [known]. An exact match is left out, it is already there.
List<String> placeSuggestions(
  List<String> known,
  String query, {
  int limit = 8,
}) {
  final typed = query.trim().toLowerCase();
  final starts = <String>[], contains = <String>[];
  for (final place in known) {
    final lower = place.toLowerCase();
    if (lower == typed) continue;
    if (lower.startsWith(typed)) {
      starts.add(place);
    } else if (lower.contains(typed)) {
      contains.add(place);
    }
  }
  return [...starts, ...contains].take(limit).toList();
}

/// Addresses that open a map search for [place], best first. Android asks
/// the installed maps app via a `geo:` link; the web search works anywhere
/// and is the fallback.
List<Uri> mapSearchUris(String place, {required bool android}) {
  final query = place.trim();
  return [
    if (android) Uri.parse('geo:0,0?q=${Uri.encodeComponent(query)}'),
    Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': query}),
  ];
}

class _PlaceStats {
  int count = 0;
  DateTime? latest;
  String? spelling;
}
