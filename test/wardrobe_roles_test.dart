import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';
import 'package:theater_app/features/games/ui/wardrobe_cards.dart';

/// A wardrobe with Elena as Lucy and two roles: Johanna (structured, won)
/// and Eurydike (only a name, as older servers send it; not won yet).
JsonMap _json({
  Map<String, String> selectedVariants = const {},
  List<String> owned = const ['e1'],
  String? worn = 'e1',
}) => {
  'catalog': {
    'rarities': [
      {'id': 'hell', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 1},
    ],
    'items': [
      {
        'id': 'c0',
        'kind': 'character',
        'name': 'Engel Logge',
        'rarity': 'hell',
        'default': true,
      },
      {
        'id': 'e1',
        'kind': 'character',
        'name': 'Elena',
        'role': 'Lucy',
        'play': 'Creepshow',
        'year': 2026,
        'rarity': 'hell',
        'personId': 6,
        'variants': [
          {
            'id': 'e1.anno',
            'name': 'Johanna (Anno 1146, 2025)',
            'role': 'Johanna',
            'play': 'Anno 1146',
            'year': 2025,
            'image': '/games/runner/skins/e1-anno.webp',
          },
          {
            'id': 'e1.schicksal',
            'name': 'Eurydike (Schicksalsfäden, 2025)',
            'image': '/games/runner/skins/e1-schicksal.webp',
          },
        ],
      },
      {
        'id': 't1',
        'kind': 'character',
        'name': 'Florian',
        'role': 'Lichttechnik',
        'rarity': 'hell',
      },
    ],
  },
  'owned': owned,
  'selected': {'character': ?worn},
  'variants': ['e1.anno'],
  'selectedVariants': selectedVariants,
};

void main() {
  group('roles in the data', () {
    test('a role reads "als Lucy · Creepshow 2026"', () {
      const lucy = WardrobeRole('Lucy', play: 'Creepshow', year: 2026);
      expect(lucy.line, 'als Lucy · Creepshow 2026');
      expect(lucy.production, 'Creepshow 2026');
      // Technicians work across plays: the function alone.
      const light = WardrobeRole('Lichttechnik');
      expect(light.isFunction, isTrue);
      expect(light.line, 'Lichttechnik');
      expect(nameInRole('Florian', light), 'Florian (Lichttechnik)');
      expect(lucy.isFunction, isFalse);
      expect(const WardrobeRole('Lucy', year: 2026).line, 'als Lucy · 2026');
      expect(nameInRole('Elena', lucy), 'Elena als Lucy');
      expect(nameInRole('Engel Logge', null), 'Engel Logge');
      expect(WardrobeRole.fromJson({'role': ' '}), isNull);
      expect(
        WardrobeRole.fromJson({
          'role': 'Lucy',
          'play': 'Creepshow',
          'year': 2026,
        }),
        lucy,
      );
    });

    test('older servers send only the name "Rolle (Stück, Jahr)"', () {
      expect(
        WardrobeRole.parse('Emma (jung) (Anno 1146, 2025)'),
        const WardrobeRole('Emma (jung)', play: 'Anno 1146', year: 2025),
      );
      expect(WardrobeRole.parse('Ensemble'), const WardrobeRole('Ensemble'));
      expect(WardrobeRole.parse(''), isNull);
      final w = Wardrobe.fromJson(_json());
      final elena = w.catalog.item('e1')!;
      expect(elena.name, 'Elena', reason: 'the name stays the person');
      expect(elena.role?.line, 'als Lucy · Creepshow 2026');
      expect(elena.variants.map((v) => v.role?.line), [
        'als Johanna · Anno 1146 2025',
        'als Eurydike · Schicksalsfäden 2025',
      ]);
      expect(elena.variants.map((v) => v.roleName), ['Johanna', 'Eurydike']);
      // An item without role fields has none.
      final plain = WardrobeItem.fromJson({
        'id': 'x',
        'kind': 'character',
        'name': 'X',
      })!;
      expect(plain.role, isNull);
    });

    test('the worn role names the character, e.g. in the intro', () {
      final lucy = Wardrobe.fromJson(_json());
      expect(lucy.wornCharacterName(), 'Elena als Lucy');
      final johanna = Wardrobe.fromJson(
        _json(selectedVariants: {'e1': 'e1.anno'}),
      );
      expect(johanna.roleOf(johanna.catalog.item('e1')!)?.role, 'Johanna');
      expect(johanna.wornCharacterName(), 'Elena als Johanna');
      expect(
        johanna.catalog
            .item('e1')!
            .inRole(johanna.variantOf(johanna.catalog.item('e1')!))
            .role
            ?.role,
        'Johanna',
      );
      expect(
        Wardrobe.fromJson(_json(worn: null)).wornCharacterName(),
        'Engel Logge',
      );
      expect(
        Wardrobe.fromJson(
          _json(owned: ['e1', 't1'], worn: 't1'),
        ).wornCharacterName(),
        'Florian (Lichttechnik)',
      );
    });

    test('a new role from a duplicate is announced with its play', () {
      CrateOutcome o(JsonMap variant) =>
          CrateOutcome.fromJson({'type': 'variant', 'variant': variant});
      expect(
        o({
          'id': 'v',
          'name': 'Johanna (Anno 1146, 2025)',
          'role': 'Johanna',
          'play': 'Anno 1146',
          'year': 2025,
        }).line,
        'Neue Rolle: Johanna · Anno 1146 2025',
      );
      expect(o({'id': 'v', 'name': 'Ensemble'}).line, 'Neue Rolle: Ensemble');
    });
  });

  group('roles on the card', () {
    late AppController controller;
    setUp(() {
      WardrobePictures.clear();
      controller = AppController(
        localStore: MemoryLocalStore(),
        credentialStore: MemoryCredentialStore(),
      );
    });
    tearDown(() => controller.dispose());

    Future<void> card(WidgetTester tester, Wardrobe w, String id) =>
        tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 132,
                height: 170,
                child: WardrobeCard(
                  item: w.catalog.item(id)!,
                  wardrobe: w,
                  controller: controller,
                  worn: w.worn(WardrobeKind.character)?.id == id,
                ),
              ),
            ),
          ),
        );

    testWidgets('the name large, the role below it', (tester) async {
      await card(tester, Wardrobe.fromJson(_json()), 'e1');
      expect(find.text('Elena'), findsOneWidget);
      expect(find.text('als Lucy · Creepshow 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Worn in another role, the card says so.
      final w = Wardrobe.fromJson(_json(selectedVariants: {'e1': 'e1.anno'}));
      await card(tester, w, 'e1');
      expect(find.text('als Johanna · Anno 1146 2025'), findsOneWidget);
    });

    testWidgets('a technician has the department as the role', (tester) async {
      final w = Wardrobe.fromJson(_json(owned: ['e1', 't1']));
      await card(tester, w, 't1');
      expect(find.text('Lichttechnik'), findsOneWidget);
      expect(find.textContaining('Creepshow'), findsNothing);
    });

    testWidgets('a character not found yet keeps its role secret', (
      tester,
    ) async {
      final w = Wardrobe.fromJson(_json(owned: [], worn: null));
      await card(tester, w, 'e1');
      expect(find.text('Elena'), findsNothing);
      expect(find.byKey(const ValueKey('card-role')), findsNothing);
    });
  });
}
