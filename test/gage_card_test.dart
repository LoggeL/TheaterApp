import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/games/ui/gage_card.dart';

// The price list of the gage: from the cheapest, the crate before a trade
// of the same price, what the balance does not reach without a button.

GageOffer _offer(
  String id,
  int price, {
  int order = 0,
  bool trade = true,
  VoidCallback? onBuy,
}) => GageOffer(
  id: id,
  action: trade ? 'trade-$id' : 'wardrobe-buy-crate',
  title: id,
  subtitle: 'Untertitel $id',
  price: price,
  verb: '$id holen',
  order: order,
  trade: trade,
  leading: const GageOfferIcon(Icons.inventory_2, color: StageTheme.orange),
  onBuy: onBuy ?? () {},
);

final _offers = [
  _offer('gold', 400, order: 7),
  _offer('pink', 150, order: 5),
  _offer('blau', 75, order: 3),
  _offer('legacy', 50, order: 2),
  _offer('crate', 50, trade: false),
  _offer('rot', 200, order: 6),
];

Future<void> _pump(
  WidgetTester tester,
  GageCard card, {
  double width = 400,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      theme: StageTheme.build(Brightness.light),
      home: Scaffold(body: SingleChildScrollView(child: card)),
    ),
  );
}

double _top(WidgetTester tester, String id) =>
    tester.getTopLeft(find.byKey(ValueKey('wardrobe-offer-$id'))).dy;

void main() {
  test('by price; at the same price the crate first, then by rarity', () {
    expect(GageCard.sorted(_offers).map((o) => o.id), [
      'crate',
      'legacy',
      'blau',
      'pink',
      'rot',
      'gold',
    ]);
  });

  testWidgets('what the balance reaches has a button, the rest a note', (
    tester,
  ) async {
    final bought = <String>[];
    await _pump(
      tester,
      GageCard(
        gage: 75,
        offers: [
          for (final o in _offers)
            _offer(
              o.id,
              o.price,
              order: o.order,
              trade: o.trade,
              onBuy: () => bought.add(o.id),
            ),
        ],
        shop: GageShop(from: 100, onShow: () => bought.add('shop')),
      ),
    );
    expect(find.text('75 Gage'), findsNWidgets(2));
    expect(find.bySemanticsLabel('Dein Guthaben: 75 Gage'), findsOneWidget);
    final order = ['crate', 'legacy', 'blau', 'pink', 'rot', 'gold'];
    for (var i = 1; i < order.length; i++) {
      expect(_top(tester, order[i - 1]), lessThan(_top(tester, order[i])));
    }
    // At the threshold: 75 is reached, 150 not.
    expect(find.byKey(const ValueKey('trade-blau')), findsOneWidget);
    expect(find.byKey(const ValueKey('trade-pink')), findsNothing);
    expect(find.byKey(const ValueKey('trade-pink-missing')), findsOneWidget);
    expect(find.text('noch 75 Gage'), findsOneWidget);
    expect(
      find.bySemanticsLabel('pink, 150 Gage, dir fehlen noch 75 Gage'),
      findsOneWidget,
    );
    // For screen readers the button itself, with its tap: not melted into
    // the card's text.
    for (final (key, label) in [
      ('wardrobe-buy-crate', 'crate holen für 50 Gage'),
      ('trade-blau', 'blau holen für 75 Gage'),
    ]) {
      expect(
        tester.getSemantics(find.byKey(ValueKey(key))),
        isSemantics(
          label: label,
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
    }
    // The trades explained once, not in every row.
    expect(find.byKey(const ValueKey('gage-trade-note')), findsOneWidget);
    // "Noch zu teuer" once, between the last reached and the first not.
    expect(find.text('Noch zu teuer'), findsOneWidget);
    final dear = tester.getTopLeft(find.text('Noch zu teuer')).dy;
    expect(dear, greaterThan(_top(tester, 'blau')));
    expect(dear, lessThan(_top(tester, 'pink')));
    // A chosen item last, from its cheapest price.
    expect(_top(tester, 'buy'), greaterThan(_top(tester, 'gold')));
    expect(find.text('ab 100 Gage'), findsOneWidget);
    expect(find.byKey(const ValueKey('gage-no-trade')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('wardrobe-buy-crate')));
    await tester.tap(find.byKey(const ValueKey('trade-blau')));
    await tester.tap(find.byKey(const ValueKey('wardrobe-show-missing')));
    tester.semantics.tap(find.semantics.byLabel('crate holen für 50 Gage'));
    expect(bought, ['crate', 'blau', 'shop', 'crate']);
  });

  testWidgets('enough for everything: no "Noch zu teuer"', (tester) async {
    await _pump(tester, GageCard(gage: 1000, offers: _offers));
    expect(find.text('Noch zu teuer'), findsNothing);
    expect(find.byKey(const ValueKey('trade-gold')), findsOneWidget);
    expect(find.byKey(const ValueKey('wardrobe-offer-buy')), findsNothing);
  });

  testWidgets('nothing reached: the note leads the list', (tester) async {
    await _pump(tester, GageCard(gage: 10, offers: _offers));
    expect(
      tester.getTopLeft(find.text('Noch zu teuer')).dy,
      lessThan(_top(tester, 'crate')),
    );
    expect(find.byKey(const ValueKey('wardrobe-buy-crate')), findsNothing);
    expect(
      find.byKey(const ValueKey('wardrobe-buy-crate-missing')),
      findsOneWidget,
    );
  });

  testWidgets('while something runs no button reacts', (tester) async {
    await _pump(tester, GageCard(gage: 1000, offers: _offers, busy: true));
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const ValueKey('wardrobe-buy-crate')),
    );
    expect(button.onPressed, isNull);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('wardrobe-buy-crate'))),
      isSemantics(isButton: true, isEnabled: false, hasTapAction: false),
    );
  });

  testWidgets('without trades the card says why', (tester) async {
    final crate = [_offer('crate', 50, trade: false)];
    await _pump(tester, GageCard(gage: 60, offers: crate));
    expect(find.text('Gerade ist kein Tausch möglich.'), findsOneWidget);
    expect(find.byKey(const ValueKey('gage-trade-note')), findsNothing);
    await _pump(tester, GageCard(gage: 60, offers: crate, complete: true));
    expect(
      find.text('Alles gesammelt – Tauschen brauchst du nicht mehr.'),
      findsOneWidget,
    );
    expect(
      find.text('Gage gibt es für Duplikate einer kompletten Stufe.'),
      findsOneWidget,
    );
    await _pump(tester, GageCard(gage: 60, offers: crate, gala: true));
    expect(
      find.text(
        'Gage gibt es für Duplikate einer kompletten Stufe und als Applaus der Monatsgala.',
      ),
      findsOneWidget,
    );
  });

  for (final (width, scale) in [(320.0, 1.0), (360.0, 2.0), (300.0, 1.6)]) {
    testWidgets('narrow ($width px, text ×$scale): no overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        GageCard(
          gage: 60,
          offers: _offers,
          shop: GageShop(from: 100, onShow: () {}),
        ),
        width: width,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);
      // The price goes below the text, at the right.
      final row = find.byKey(const ValueKey('wardrobe-offer-pink'));
      final price = find.byKey(const ValueKey('trade-pink-missing'));
      expect(
        tester.getTopLeft(price).dy,
        greaterThan(
          tester
              .getBottomLeft(
                find.descendant(of: row, matching: find.text('pink')),
              )
              .dy,
        ),
      );
    });
  }
}
