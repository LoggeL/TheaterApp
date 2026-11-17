import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';

void main() {
  test('a unique for a set of items names the items instead of play roles', () {
    final progress = UniqueFigureProgress.fromJson({
      'play': 'Adventskalender',
      'year': 2026,
      'have': 22,
      'total': 23,
      'allAdventCalendar': true,
      'itemNoun': {
        'one': 'Adventskalender-Skin',
        'many': 'Adventskalender-Skins',
      },
      'unlocked': false,
      'name': 'must stay hidden',
    })!;
    expect(progress.itemSet, isTrue);
    expect(progress.itemNoun?.one, 'Adventskalender-Skin');
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
  });

  test('without item names a unique still counts roles', () {
    final progress = UniqueFigureProgress.fromJson({
      'play': 'Creepshow',
      'year': 2026,
      'have': 3,
      'total': 9,
      // Only the label from the server makes it a set; a bare flag does not.
      'allAdventCalendar': true,
      'itemNoun': {'one': 'Skin'},
    })!;
    expect(progress.itemSet, isFalse);
    expect(progress.line, '3/9 Rollen aus Creepshow');
  });
}
