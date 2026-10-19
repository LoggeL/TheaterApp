import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/feedback.dart';
import '../domain/event_places.dart';

/// Opens one address outside the app; false when nothing could take it.
typedef UriOpener = Future<bool> Function(Uri uri);

Future<bool> _openExternally(Uri uri) => launchUrl(
  uri,
  mode: LaunchMode.externalApplication,
  // The web app keeps its tab and shows the map in a new one.
  webOnlyWindowName: '_blank',
);

/// How [openPlaceOnMap] leaves the app; tests replace it.
@visibleForTesting
UriOpener placeOpener = _openExternally;

/// Searches [place] in a map: the maps app on Android, otherwise Google Maps
/// on the web. Tells the member when no map could be opened.
Future<void> openPlaceOnMap(BuildContext context, String place) async {
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  for (final uri in mapSearchUris(place, android: android)) {
    try {
      if (await placeOpener(uri)) return;
    } catch (_) {
      // No app for this address: try the next one.
    }
  }
  if (context.mounted) {
    showProblem(context, 'Die Karte konnte nicht geöffnet werden.');
  }
}

/// Copies [place] to the clipboard and confirms it.
Future<void> copyPlace(BuildContext context, String place) async {
  await Clipboard.setData(ClipboardData(text: place));
  if (context.mounted) showDone(context, 'Adresse kopiert');
}

/// The place line of an event: a tap searches it on a map, a long press or
/// the copy button copies it.
class EventPlaceRow extends StatelessWidget {
  const EventPlaceRow(this.place, {super.key});
  final String place;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    const bold = TextStyle(fontWeight: FontWeight.w600);
    if (place.trim().isEmpty) {
      return Row(
        children: [
          Icon(Icons.location_on_outlined, size: 21, color: primary),
          const SizedBox(width: 14),
          const Expanded(
            child: Text('Ort wird noch bekannt gegeben', style: bold),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Tooltip(
            message: 'Auf der Karte zeigen',
            child: InkWell(
              key: const ValueKey('event-place'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => openPlaceOnMap(context, place),
              onLongPress: () => copyPlace(context, place),
              child: Row(
                children: [
                  Icon(Icons.location_on_outlined, size: 21, color: primary),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      place,
                      style: bold.copyWith(
                        decoration: TextDecoration.underline,
                        decorationColor: primary.withValues(alpha: .5),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.map_outlined, size: 18, color: primary),
                ],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Adresse kopieren',
          visualDensity: VisualDensity.compact,
          onPressed: () => copyPlace(context, place),
          icon: const Icon(Icons.copy_outlined, size: 18),
        ),
      ],
    );
  }
}
