import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/stage_theme.dart';
import 'wardrobe_overview.dart' show wardrobeInset, wardrobeScale;

final _number = NumberFormat.decimalPattern('de');

String _gage(int gage) => '${_number.format(gage)} Gage';

/// One thing gage buys: a crate or a Tauschvertrag, with the server's price.
class GageOffer {
  const GageOffer({
    required this.id,
    required this.action,
    required this.title,
    required this.subtitle,
    required this.price,
    required this.leading,
    required this.verb,
    this.order = 0,
    this.trade = false,
    this.onBuy,
  });

  /// The row's key is `wardrobe-offer-<id>`.
  final String id;

  /// The key of the button; its hint while too dear is `<action>-missing`.
  final String action;
  final String title, subtitle;
  final int price;
  final Widget leading;

  /// What the button does, for screen readers: "Kostümkiste kaufen".
  final String verb;

  /// Among equal prices: lower first (the crate 0, trades by rarity).
  final int order;

  /// A Tauschvertrag; without any the card says why.
  final bool trade;
  final VoidCallback? onBuy;
}

/// The way to a chosen item: over its card in the collection, from [from].
class GageShop {
  const GageShop({required this.from, required this.onShow});
  final int from;
  final VoidCallback onShow;
}

/// A tinted square with [icon], the start of a [GageOffer]'s row.
class GageOfferIcon extends StatelessWidget {
  const GageOfferIcon(this.icon, {super.key, required this.color});
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final tint = StageTheme.tintedLabel(
      color,
      Theme.of(context).brightness,
      minimum: 3,
    );
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: tint.fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 22, color: tint.foreground),
    );
  }
}

/// The gage (`runnerDupes`): the balance, where it comes from, and the
/// price list from the cheapest; what the balance does not reach yet says
/// how much is missing instead of showing a disabled button.
class GageCard extends StatelessWidget {
  const GageCard({
    super.key,
    required this.gage,
    required this.offers,
    this.shop,
    this.gala = false,
    this.complete = false,
    this.busy = false,
  });
  final int gage;
  final List<GageOffer> offers;
  final GageShop? shop;

  /// Whether the Monatsgala's applause brings gage too (`runnerMonthlyGala`).
  final bool gala;

  /// The whole collection is there: no trade is needed any more.
  final bool complete;

  /// While something else runs no button reacts.
  final bool busy;

  /// [offers] by price, the crate before a trade of the same price.
  static List<GageOffer> sorted(List<GageOffer> offers) =>
      [...offers]..sort((a, b) {
        final price = a.price.compareTo(b.price);
        return price != 0 ? price : a.order.compareTo(b.order);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final list = sorted(offers);
    final dear = list.indexWhere((o) => o.price > gage);
    final inset = wardrobeInset(context);
    final rows = <Widget>[
      for (final (i, offer) in list.indexed) ...[
        if (i > 0) const Divider(height: 1),
        if (i == dear)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 2),
            child: Text(
              'Noch zu teuer',
              key: const ValueKey('gage-too-dear'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        _row(context, offer),
      ],
      if (!list.any((o) => o.trade)) ...[
        if (list.isNotEmpty) const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            complete
                ? 'Alles gesammelt – Tauschen brauchst du nicht mehr.'
                : 'Gerade ist kein Tausch möglich.',
            key: const ValueKey('gage-no-trade'),
            style: quiet,
          ),
        ),
      ],
      if (shop case final shop?) ...[
        const Divider(height: 1),
        _shopRow(context, shop),
      ],
    ];
    final amount = Text(
      _gage(gage),
      key: const ValueKey('wardrobe-gage'),
      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
    );
    return Card(
      key: const ValueKey('wardrobe-gage-card'),
      child: Padding(
        padding: EdgeInsets.fromLTRB(inset, inset, inset, inset - 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              container: true,
              label: 'Dein Guthaben: ${_gage(gage)}',
              excludeSemantics: true,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final title = Text(
                    'Gage',
                    style: theme.textTheme.titleMedium,
                  );
                  final icon = Icon(
                    Icons.payments_outlined,
                    size: 24,
                    color: StageTheme.accentText(
                      StageTheme.orange,
                      theme.brightness,
                    ),
                  );
                  if (largeText || constraints.maxWidth < 300) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            icon,
                            const SizedBox(width: 10),
                            Expanded(child: title),
                          ],
                        ),
                        amount,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      icon,
                      const SizedBox(width: 10),
                      Expanded(child: title),
                      amount,
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              gala
                  ? 'Gage gibt es für Duplikate einer kompletten Stufe und als Applaus der Monatsgala.'
                  : 'Gage gibt es für Duplikate einer kompletten Stufe.',
              style: quiet,
            ),
            // Once for all trades; their rows only name the rarity.
            if (list.any((o) => o.trade)) ...[
              const SizedBox(height: 4),
              Text(
                'Ein Tauschvertrag bringt garantiert ein neues Teil, zufällig aus dem, was dir in der Stufe noch fehlt.',
                key: const ValueKey('gage-trade-note'),
                style: quiet,
              ),
            ],
            const SizedBox(height: 8),
            ...rows,
          ],
        ),
      ),
    );
  }

  /// Picture, text and on the right the price: a button when the balance
  /// reaches it, else what is still missing. Narrow, the right part goes
  /// below the text.
  Widget _line(
    BuildContext context, {
    required Key key,
    required Widget leading,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    final theme = Theme.of(context);
    final scale = wardrobeScale(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 300 * scale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leading,
                    const SizedBox(width: 12),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: trailing),
              ],
            );
          }
          return Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(child: text),
              const SizedBox(width: 12),
              trailing,
            ],
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, GageOffer offer) {
    final theme = Theme.of(context);
    final quiet = theme.colorScheme.onSurfaceVariant;
    final missing = offer.price - gage;
    final Widget trailing = missing <= 0
        // The button's own node keeps its tap; only the text says more.
        ? FilledButton.tonal(
            key: ValueKey(offer.action),
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: busy ? null : offer.onBuy,
            child: Text(
              _gage(offer.price),
              semanticsLabel: '${offer.verb} für ${_gage(offer.price)}',
            ),
          )
        : Semantics(
            key: ValueKey('${offer.action}-missing'),
            container: true,
            label:
                '${offer.title}, ${_gage(offer.price)}, dir fehlen noch ${_gage(missing)}',
            excludeSemantics: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _gage(offer.price),
                  style: theme.textTheme.labelLarge?.copyWith(color: quiet),
                ),
                Text(
                  'noch ${_gage(missing)}',
                  style: theme.textTheme.bodySmall?.copyWith(color: quiet),
                ),
              ],
            ),
          );
    return _line(
      context,
      key: ValueKey('wardrobe-offer-${offer.id}'),
      leading: offer.leading,
      title: offer.title,
      subtitle: offer.subtitle,
      trailing: trailing,
    );
  }

  Widget _shopRow(BuildContext context, GageShop shop) {
    final theme = Theme.of(context);
    return _line(
      context,
      key: const ValueKey('wardrobe-offer-buy'),
      leading: GageOfferIcon(
        Icons.shopping_bag_outlined,
        color: theme.colorScheme.onSurfaceVariant,
      ),
      title: 'Bestimmtes Teil',
      subtitle:
          'Genau das Teil, das du willst – über seine Karte in der Sammlung',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'ab ${_gage(shop.from)}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            key: const ValueKey('wardrobe-show-missing'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: shop.onShow,
            child: const Text('Fehlende zeigen'),
          ),
        ],
      ),
    );
  }
}
