import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import '../../accounts/data/accounts_api.dart';
import '../../accounts/domain/account_roster.dart';
import '../../accounts/ui/access_widgets.dart';
import 'member_editor_screen.dart';

class MembersAdminScreen extends StatefulWidget {
  const MembersAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MembersAdminScreen> createState() => _MembersAdminScreenState();
}

class _MembersAdminScreenState extends State<MembersAdminScreen> {
  String _search = '';

  /// People, accounts and productions of the account list; null until
  /// loaded or when offline, which hides the access pills.
  AccountRoster? _roster;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final roster = await fetchRoster(widget.controller);
      if (mounted) setState(() => _roster = roster);
    } catch (_) {
      // The list works without account details.
    }
  }

  Future<void> _open(JsonMap? member) async {
    await openPage(
      context,
      MemberEditorScreen(controller: widget.controller, member: member),
    );
    if (mounted) await _loadAccounts();
  }

  /// The shared status pill and, compact, the account's role and rights.
  Widget _access(AccountRoster roster, JsonMap m) {
    final entry = AccessEntry(
      member: m,
      account: roster.accountFor(intValue(m['id'])),
    );
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        AccessStatusPill(accessStatus(entry)),
        RightsPills(roster.rights(entry), compact: true),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Ensemble verwalten',
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _open(null),
      icon: const Icon(Icons.person_add_outlined),
      label: const Text('Person anlegen'),
    ),
    children: (context) {
      final found = widget.controller.memberRecords
          .where(
            (m) => textValue(
              m['name'],
            ).toLowerCase().contains(_search.toLowerCase()),
          )
          .toList();
      final inactive = found.where((m) => m['active'] == false).toList();
      return [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Mitglied suchen',
          ),
          onChanged: (s) => setState(() => _search = s),
        ),
        const SizedBox(height: 20),
        for (final m in found.where((m) => m['active'] != false))
          _member(context, m),
        if (inactive.isNotEmpty) ...[
          SectionTitle('Nicht aktiv (${inactive.length})'),
          for (final m in inactive) _member(context, m),
        ],
      ];
    },
  );

  Widget _member(BuildContext context, JsonMap m) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Opacity(
      opacity: m['active'] == false ? .7 : 1,
      child: Card(
        child: ListTile(
          leading: MemberAvatar(
            controller: widget.controller,
            avatarId: m['avatarId'] as String?,
            initials: textValue(m['initials']),
          ),
          title: Text(textValue(m['name'])),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.controller.roleNames(
                  jsonList(m['roleIds']).map((r) => r.toString()),
                ),
              ),
              if (_roster case final roster?) ...[
                const SizedBox(height: 6),
                _access(roster, m),
              ],
            ],
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => _open(m),
        ),
      ),
    ),
  );
}
