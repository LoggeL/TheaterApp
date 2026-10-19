import 'package:flutter/material.dart';

import '../domain/event_places.dart';

/// The place input of the event editor. While typing it suggests places of
/// earlier events, most used first.
class EventPlaceField extends StatefulWidget {
  const EventPlaceField({
    super.key,
    required this.controller,
    required this.places,
  });
  final TextEditingController controller;

  /// Known places, best first, e.g. from [knownPlaces].
  final List<String> places;

  @override
  State<EventPlaceField> createState() => _EventPlaceFieldState();
}

class _EventPlaceFieldState extends State<EventPlaceField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawAutocomplete<String>(
    textEditingController: widget.controller,
    focusNode: _focus,
    optionsBuilder: (value) => placeSuggestions(widget.places, value.text),
    fieldViewBuilder: (context, controller, focus, onSubmitted) => TextField(
      key: const ValueKey('event-place-field'),
      controller: controller,
      focusNode: focus,
      textInputAction: TextInputAction.next,
      onSubmitted: (_) => onSubmitted(),
      decoration: const InputDecoration(labelText: 'Ort'),
    ),
    optionsViewBuilder: (context, onSelected, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            children: [
              for (final (index, place) in options.indexed)
                Builder(
                  builder: (context) {
                    final active =
                        AutocompleteHighlightedOption.of(context) == index;
                    return ListTile(
                      dense: true,
                      selected: active,
                      leading: const Icon(Icons.history, size: 20),
                      title: Text(place),
                      onTap: () => onSelected(place),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
