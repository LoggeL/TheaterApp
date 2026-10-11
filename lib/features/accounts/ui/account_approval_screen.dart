import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/feedback.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/page_header.dart';
import '../../../shared/widgets/state_pill.dart';
import '../../ensemble/admin/member_editor_screen.dart';

class AccountApprovalScreen extends StatefulWidget {
  const AccountApprovalScreen({
    super.key,
    required this.controller,
    required this.account,
    required this.accounts,
    this.initialPersonId,
  });
  final AppController controller;
  final JsonMap account;
  final List<JsonMap> accounts;
  final int? initialPersonId;
  @override
  State<AccountApprovalScreen> createState() => _AccountApprovalScreenState();
}

class _AccountApprovalScreenState extends State<AccountApprovalScreen> {
  int? _person;
  String _search = '', _role = 'member';
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _person = widget.initialPersonId;
  }

  Future<void> _save(bool approve) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!approve) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: const Text('Anfrage ablehnen?'),
            content: Text(
              'Die Anfrage von ${textValue(widget.account['name'])} '
              '(${textValue(widget.account['email'])}) wird abgelehnt. '
              'Das Konto erhält keinen Zugang. Du kannst es später in der '
              'Kontenverwaltung erneut prüfen.',
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Ablehnen'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await widget.controller.performAction(
        approve
            ? {
                'action': 'account.approve',
                'uid': widget.account['uid'],
                'version': widget.account['version'],
                'personId': _person,
                'role': _role,
              }
            : {
                'action': 'account.status',
                'uid': widget.account['uid'],
                'version': widget.account['version'],
                'status': 'rejected',
              },
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Konto freigeben',
    children: (context) {
      final a = widget.account;
      final linked = widget.accounts
          .where((x) => x['personId'] != null)
          .map((x) => intValue(x['personId']))
          .toSet();
      final people = widget.controller.members.where(
        (m) => m.active && m.name.toLowerCase().contains(_search.toLowerCase()),
      );
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  textValue(a['name']),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text('Name zur Zuordnung des Kontos'),
                const SizedBox(height: 8),
                Text(textValue(a['email'])),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatePill(
                      a['emailVerified'] == true
                          ? 'E-Mail bestätigt'
                          : 'Identität prüfen',
                      icon: a['emailVerified'] == true
                          ? Icons.check
                          : Icons.info_outline,
                    ),
                    const StatePill(
                      'Ausstehend',
                      color: Color(0xFFA25B06),
                      icon: Icons.schedule,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('Person zuordnen'),
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Person suchen',
          ),
          onChanged: (s) => setState(() => _search = s),
        ),
        const SizedBox(height: 14),
        for (final m in people)
          Card(
            child: ListTile(
              enabled: !linked.contains(m.id),
              leading: Icon(
                _person == m.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              onTap: linked.contains(m.id)
                  ? null
                  : () => setState(() => _person = m.id),
              title: Text(m.name),
              subtitle: Text(
                linked.contains(m.id)
                    ? 'Bereits mit einem Konto verknüpft'
                    : [
                        widget.controller.roleNames(m.roleIds),
                        'Mitglied Nr. ${m.id.toString().padLeft(3, '0')}',
                      ].where((s) => s.isNotEmpty).join(' · '),
              ),
            ),
          ),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  await openPage(
                    context,
                    MemberEditorScreen(controller: widget.controller),
                  );
                  if (mounted) setState(() {});
                },
          icon: const Icon(Icons.person_add_outlined),
          label: const Text('Person anlegen'),
        ),
        const SectionTitle('Zugriff'),
        DropdownButtonFormField<String>(
          initialValue: _role,
          decoration: const InputDecoration(labelText: 'Berechtigung'),
          items: const [
            DropdownMenuItem(value: 'member', child: Text('Mitglied')),
            DropdownMenuItem(value: 'admin', child: Text('Admin')),
          ],
          onChanged: (s) => setState(() => _role = s!),
        ),
        const SizedBox(height: 28),
        if (a['identityReady'] != true)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text('Die E-Mail-Adresse muss zuerst bestätigt werden.'),
          ),
        if (a['nameProvided'] == false)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Diese Person muss noch einen Namen zur Zuordnung angeben.',
            ),
          ),
        FilledButton(
          onPressed:
              _busy ||
                  _person == null ||
                  a['identityReady'] != true ||
                  a['nameProvided'] == false
              ? null
              : () => _save(true),
          child: const Text('Verknüpfen & freigeben'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _busy ? null : () => _save(false),
          child: const Text('Anfrage ablehnen'),
        ),
      ];
    },
  );
}
