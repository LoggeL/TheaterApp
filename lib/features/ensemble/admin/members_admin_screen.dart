import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/navigation.dart';
import '../../../shared/widgets/admin_page.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';
import 'member_editor_screen.dart';

class MembersAdminScreen extends StatefulWidget {
  const MembersAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MembersAdminScreen> createState() => _MembersAdminScreenState();
}

class _MembersAdminScreenState extends State<MembersAdminScreen> {
  String _search = '';
  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Ensemble verwalten',
    actions: [
      IconButton(
        tooltip: 'Person anlegen',
        onPressed: () => openPage(
          context,
          MemberEditorScreen(controller: widget.controller),
        ),
        icon: const Icon(Icons.person_add_outlined),
      ),
    ],
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
          subtitle: Text(
            widget.controller.roleNames(
              jsonList(m['roleIds']).map((r) => r.toString()),
            ),
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => openPage(
            context,
            MemberEditorScreen(controller: widget.controller, member: m),
          ),
        ),
      ),
    ),
  );
}
