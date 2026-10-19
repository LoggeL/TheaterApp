import 'package:flutter/material.dart';

import '../../../core/models.dart';
import 'widgets/reader_style.dart';

class ProductionCard extends StatelessWidget {
  const ProductionCard({
    super.key,
    required this.production,
    required this.number,
    required this.cached,
    required this.roles,
    required this.onTap,
    this.onLearn,
    this.highlightLatest = true,
  });
  final Production production;
  final int number;
  final bool cached;

  /// Names of the member's roles in this production; may be empty.
  final List<String> roles;
  final VoidCallback onTap;

  /// Opens the line learning; the button shows only with [roles].
  final VoidCallback? onLearn;
  final bool highlightLatest;
  bool get latest => highlightLatest && number == 1;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    color: latest
        ? const Color(0xFF3D2B23)
        : number.isOdd
        ? readerInk
        : const Color(0xFF394642),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(24),
      side: latest
          ? const BorderSide(color: readerAccent, width: 2)
          : BorderSide.none,
    ),
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.theater_comedy_outlined,
                  color: Color(0xFFFFA37A),
                  size: 32,
                ),
                if (latest) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: readerAccentFill,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'Neuestes Stück',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (!latest) const Spacer(),
                ExcludeSemantics(
                  child: Text(
                    number.toString().padLeft(2, '0'),
                    style: const TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w300,
                      color: Colors.white30,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            Text(
              production.title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
            ),
            if (production.subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                production.subtitle,
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
            ],
            const SizedBox(height: 24),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                if (production.sceneCount > 0)
                  Text(
                    production.sceneCount == 1
                        ? '1 Szene'
                        : '${production.sceneCount} Szenen',
                    style: const TextStyle(color: Colors.white70),
                  ),
                Text(switch (roles.length) {
                  0 => 'Rolle im Drehbuch auswählen',
                  1 => 'Deine Rolle: ${roles.single}',
                  _ => 'Deine Rollen: ${roles.join(', ')}',
                }, style: const TextStyle(color: Colors.white70)),
              ],
            ),
            if (onLearn != null && roles.isNotEmpty) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: ValueKey('production-learn.${production.id}'),
                onPressed: onLearn,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  minimumSize: const Size(0, 48),
                ),
                icon: const Icon(Icons.record_voice_over_outlined, size: 20),
                label: const Text('Text lernen'),
              ),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Icon(
                  cached
                      ? Icons.offline_pin_outlined
                      : Icons.cloud_download_outlined,
                  color: Colors.white60,
                  size: 17,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cached
                        ? 'Auf diesem Gerät gespeichert'
                        : 'Beim Öffnen offline speichern',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
                const CircleAvatar(
                  backgroundColor: readerAccent,
                  foregroundColor: Colors.white,
                  child: Icon(Icons.arrow_forward_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
