import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';

void main() {
  test(
    'the Christmas unique explains calendar skins instead of play roles',
    () {
      final progress = UniqueFigureProgress.fromJson({
        'play': 'Adventskalender',
        'year': 2026,
        'have': 22,
        'total': 23,
        'allAdventCalendar': true,
        'unlocked': false,
        'name': 'must stay hidden',
      })!;
      expect(progress.allAdventCalendar, isTrue);
      expect(progress.line, '22/23 Adventskalender-Skins gesammelt');
      expect(progress.name, '???');
      expect(progress.production, 'Adventskalender 2026');
      expect(
        uniqueRoleLine(
          const WardrobeRole('Captain Kuschel', play: 'Creepshow', year: 2026),
          progress,
        ),
        'Unique · Adventskalender 2026',
      );
    },
  );
}
