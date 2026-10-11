import 'package:flutter/material.dart';

import '../../../core/app_controller.dart';
import '../../../core/models.dart';
import '../../../shared/widgets/member_avatar.dart';
import '../../../shared/widgets/page_header.dart';

class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final members = widget.controller.members
        .where(
          (m) => '${m.name} ${widget.controller.roleNames(m.roleIds)}'
              .toLowerCase()
              .contains(_query.toLowerCase()),
        )
        .toList();
    final active = members.where((m) => m.active).toList(),
        inactive = members.where((m) => !m.active).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Unser Ensemble')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Name oder Rolle suchen',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final (i, member) in active.indexed) ...[
                  if (i > 0) const Divider(indent: 82),
                  _member(member),
                ],
                if (inactive.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: SectionTitle('Nicht aktiv (${inactive.length})'),
                  ),
                  for (final (i, member) in inactive.indexed) ...[
                    if (i > 0) const Divider(indent: 82),
                    Opacity(opacity: .7, child: _member(member)),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _member(TheaterMember member) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 7),
    leading: MemberAvatar(
      controller: widget.controller,
      avatarId: member.avatarId,
      initials: member.initials,
    ),
    title: Text(member.name),
    subtitle: Text(widget.controller.roleNames(member.roleIds)),
  );
}
