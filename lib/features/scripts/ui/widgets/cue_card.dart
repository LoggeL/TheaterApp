import 'package:flutter/material.dart';

import '../../domain/cue_category.dart';
import '../../domain/script_document.dart';
import 'reader_style.dart';

/// One cue in the reader list.
///
/// Long press and secondary click (right click) open the cue actions. With
/// [showActionsButton] (desktop) a "more" button appears on hover or keyboard
/// focus, so the actions can be found without knowing the gestures.
class CueCard extends StatefulWidget {
  const CueCard({
    super.key,
    required this.cue,
    required this.own,
    required this.active,
    required this.bookmarked,
    required this.fontScale,
    required this.dark,
    required this.query,
    required this.onTap,
    required this.onBookmark,
    required this.onActions,
    required this.onNote,
    required this.onComments,
    this.hidden = false,
    this.hasNote = false,
    this.commentCount = 0,
    this.showActionsButton = false,
  });
  final ScriptCue cue;
  final bool own, active, bookmarked, dark, hidden, hasNote, showActionsButton;
  final int commentCount;
  final double fontScale;
  final String query;
  final VoidCallback onTap, onBookmark, onActions, onNote, onComments;

  @override
  State<CueCard> createState() => _CueCardState();
}

class _CueCardState extends State<CueCard> {
  bool _hovering = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final cue = widget.cue;
    final theme = Theme.of(context),
        direction = cue.kind == 'direction',
        technical = cue.isTechnical,
        category = cueCategoryInfo(cue.kind),
        comments = widget.commentCount;
    final header =
        !direction || widget.bookmarked || widget.hasNote || comments > 0;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header)
          Row(
            children: [
              Expanded(
                child: direction
                    ? const SizedBox.shrink()
                    : Text(
                        technical ? category.label.toUpperCase() : cue.role,
                        style: TextStyle(
                          fontSize: 12 * widget.fontScale,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                          color: widget.own
                              ? readerAccent
                              : technical
                              ? category.color
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
              if (cue.isAutoMic)
                Text('AUTO', style: theme.textTheme.labelSmall),
              if (comments > 0)
                TextButton.icon(
                  onPressed: widget.onComments,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: theme.colorScheme.onSurfaceVariant,
                  ),
                  icon: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: Text(
                    '$comments',
                    semanticsLabel: comments == 1
                        ? '1 Kommentar'
                        : '$comments Kommentare',
                  ),
                ),
              if (widget.bookmarked)
                IconButton(
                  tooltip: 'Lesezeichen entfernen',
                  onPressed: widget.onBookmark,
                  icon: const Icon(Icons.bookmark, size: 17),
                  color: readerAccent,
                ),
              if (widget.hasNote)
                IconButton(
                  tooltip: 'Notiz zur Textstelle',
                  onPressed: widget.onNote,
                  icon: const Icon(Icons.edit_note, size: 19),
                ),
            ],
          ),
        if (!direction) const SizedBox(height: 7),
        if (widget.hidden)
          Semantics(
            label: 'Eigener Text verdeckt. Zum Aufdecken antippen.',
            button: true,
            child: ExcludeSemantics(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Row(
                  children: [
                    Icon(
                      Icons.visibility_outlined,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Text aufdecken',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Text.rich(
            highlightedText(
              cue.text,
              widget.query,
              TextStyle(
                fontSize: (direction ? 16 : 19) * widget.fontScale,
                height: 1.6,
                color: direction
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
                fontStyle: direction ? FontStyle.italic : FontStyle.normal,
              ),
            ),
            semanticsLabel:
                '${cue.role.isNotEmpty ? '${cue.role}: ' : ''}${cue.text}',
          ),
      ],
    );
    final showButton = _hovering || _focused;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onActions,
              onSecondaryTap: widget.onActions,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: widget.own
                          ? readerAccent
                          : widget.active
                          ? theme.colorScheme.secondary
                          : Colors.transparent,
                      width: widget.own ? 3 : 2,
                    ),
                  ),
                  color: widget.active
                      ? theme.colorScheme.secondary.withValues(alpha: .08)
                      : Colors.transparent,
                ),
                padding: EdgeInsets.fromLTRB(
                  16,
                  7,
                  widget.showActionsButton ? 4 : 12,
                  9,
                ),
                child: widget.showActionsButton
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: content),
                          SizedBox(
                            width: 40,
                            child: AnimatedOpacity(
                              opacity: showButton ? 1 : 0,
                              duration: const Duration(milliseconds: 120),
                              child: IconButton(
                                tooltip: 'Aktionen zur Textstelle',
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.onActions,
                                icon: const Icon(Icons.more_vert, size: 20),
                              ),
                            ),
                          ),
                        ],
                      )
                    : content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [text] with every match of [query] highlighted.
TextSpan highlightedText(String text, String query, TextStyle style) {
  if (query.isEmpty) return TextSpan(text: text, style: style);
  final lower = text.toLowerCase();
  final needle = query.toLowerCase();
  final spans = <TextSpan>[];
  var cursor = 0;
  while (cursor < text.length) {
    final index = lower.indexOf(needle, cursor);
    if (index == -1) {
      spans.add(TextSpan(text: text.substring(cursor)));
      break;
    }
    if (index > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, index)));
    }
    spans.add(
      TextSpan(
        text: text.substring(index, index + needle.length),
        style: const TextStyle(
          backgroundColor: Color(0xFFFFD289),
          color: Color(0xFF342111),
        ),
      ),
    );
    cursor = index + needle.length;
  }
  return TextSpan(style: style, children: spans);
}
