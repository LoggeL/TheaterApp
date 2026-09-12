import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../core/app_controller.dart';
import '../core/identity.dart';
import '../core/models.dart';
import 'events.dart';
import 'accounts_admin.dart';
import 'rehearsal_admin.dart';
import 'messages.dart';
import 'theme.dart';

void openPage(BuildContext context, Widget screen) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
void showProblem(BuildContext context, Object error) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(identityError(error))));

class AdminPage extends StatelessWidget {
  const AdminPage({
    super.key,
    required this.controller,
    required this.title,
    required this.children,
    this.actions,
  });
  final AppController controller;
  final String title;
  final List<Widget> Function(BuildContext) children;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions:
            actions ??
            const [
              Padding(
                padding: EdgeInsets.only(right: 20),
                child: StatePill('Admin', color: StageTheme.orange),
              ),
            ],
      ),
      body: controller.user?.isAdmin != true
          ? const Center(child: Text('Admin-Zugang erforderlich.'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: RefreshIndicator(
                  onRefresh: controller.refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(22, 14, 22, 32),
                    children: children(context),
                  ),
                ),
              ),
            ),
    ),
  );
}

class ManagementScreen extends StatelessWidget {
  const ManagementScreen({super.key, required this.controller});
  final AppController controller;
  Widget tile(
    BuildContext context,
    IconData icon,
    String title,
    Widget target, [
    String? subtitle,
  ]) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openPage(context, target),
    ),
  );
  @override
  Widget build(BuildContext context) => AdminPage(
    controller: controller,
    title: 'Probenleitung',
    children: (ctx) {
      final next = controller.events
          .where((e) => e.endsAt?.isAfter(DateTime.now()) ?? false)
          .firstOrNull;
      return [
        if (next != null) ...[
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: StageTheme.ink,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NÄCHSTE PROBE',
                  style: TextStyle(
                    color: Color(0xFFFFA584),
                    letterSpacing: 1.5,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  next.title,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${eventDate(next)} · ${eventTime(next)}',
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(next.place, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => openPage(
                      ctx,
                      AttendanceEditorScreen(
                        controller: controller,
                        event: next,
                      ),
                    ),
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Anwesenheit erfassen'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
        ],
        tile(
          ctx,
          Icons.person_add_alt,
          'Konten & Verknüpfungen',
          AccountsAdminScreen(controller: controller),
          'Personen, Rollen und E-Mail-Adressen',
        ),
        const SizedBox(height: 10),
        tile(
          ctx,
          Icons.calendar_month_outlined,
          'Termine verwalten',
          EventsAdminScreen(controller: controller),
        ),
        const SizedBox(height: 10),
        tile(
          ctx,
          Icons.groups_outlined,
          'Ensemble verwalten',
          MembersAdminScreen(controller: controller),
        ),
        const SizedBox(height: 10),
        tile(
          ctx,
          Icons.auto_stories_outlined,
          'Produktionen & Besetzung',
          ProductionsAdminScreen(controller: controller),
        ),
        const SizedBox(height: 10),
        tile(
          ctx,
          Icons.chat_bubble_outline,
          'Mitteilung schreiben',
          MessageComposerScreen(controller: controller),
        ),
        const SizedBox(height: 10),
        tile(
          ctx,
          Icons.notifications_outlined,
          'Push-Versand',
          PushAdminScreen(controller: controller),
        ),
        if (next != null) ...[
          const SectionTitle('Für die nächste Probe'),
          tile(
            ctx,
            Icons.how_to_reg_outlined,
            'Rückmeldungen',
            ResponsesAdminScreen(controller: controller, event: next),
          ),
          const SizedBox(height: 10),
          tile(
            ctx,
            Icons.playlist_add_check,
            'Szenen planen',
            ScenePlannerScreen(controller: controller, event: next),
          ),
        ],
      ];
    },
  );
}

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
    setState(() => _busy = true);
    try {
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
                    : '${m.group} · Mitglied Nr. ${m.id.toString().padLeft(3, '0')}',
              ),
            ),
          ),
        TextButton.icon(
          onPressed: _busy
              ? null
              : () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          MemberEditorScreen(controller: widget.controller),
                    ),
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
        FilledButton(
          onPressed: _busy || _person == null || a['identityReady'] != true
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
    children: (context) => [
      TextField(
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search),
          hintText: 'Mitglied suchen',
        ),
        onChanged: (s) => setState(() => _search = s),
      ),
      const SizedBox(height: 20),
      for (final m in widget.controller.memberRecords.where(
        (m) =>
            textValue(m['name']).toLowerCase().contains(_search.toLowerCase()),
      ))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(textValue(m['initials']))),
              title: Text(textValue(m['name'])),
              subtitle: Text(
                '${textValue(m['group'])}${m['active'] == false ? ' · Inaktiv' : ''}',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => openPage(
                context,
                MemberEditorScreen(controller: widget.controller, member: m),
              ),
            ),
          ),
        ),
    ],
  );
}

class MemberEditorScreen extends StatefulWidget {
  const MemberEditorScreen({super.key, required this.controller, this.member});
  final AppController controller;
  final JsonMap? member;
  @override
  State<MemberEditorScreen> createState() => _MemberEditorScreenState();
}

class _MemberEditorScreenState extends State<MemberEditorScreen> {
  late final TextEditingController _name, _group;
  late bool _active;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: textValue(widget.member?['name']));
    _group = TextEditingController(
      text: textValue(widget.member?['group'], 'Ensemble'),
    );
    _active = widget.member?['active'] != false;
  }

  @override
  void dispose() {
    _name.dispose();
    _group.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'member.save',
        'id': widget.member?['id'],
        'version': widget.member?['version'] ?? 1,
        'name': _name.text,
        'group': _group.text,
        'active': _active,
      });
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
    title: widget.member == null ? 'Person anlegen' : 'Person bearbeiten',
    children: (context) => [
      TextField(
        controller: _name,
        decoration: const InputDecoration(labelText: 'Name'),
        textCapitalization: TextCapitalization.words,
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _group,
        decoration: const InputDecoration(labelText: 'Gruppe'),
      ),
      const SizedBox(height: 20),
      SwitchListTile(
        value: _active,
        onChanged: (v) => setState(() => _active = v),
        title: const Text('Aktives Mitglied'),
      ),
      const SizedBox(height: 28),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Speichern'),
      ),
    ],
  );
}

class EventsAdminScreen extends StatelessWidget {
  const EventsAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) => AdminPage(
    controller: controller,
    title: 'Termine verwalten',
    actions: [
      IconButton(
        tooltip: 'Termin anlegen',
        onPressed: () =>
            openPage(context, EventEditorScreen(controller: controller)),
        icon: const Icon(Icons.add),
      ),
    ],
    children: (context) => [
      FilledButton.icon(
        onPressed: () =>
            openPage(context, EventEditorScreen(controller: controller)),
        icon: const Icon(Icons.add),
        label: const Text('Termin anlegen'),
      ),
      const SizedBox(height: 20),
      for (final e in controller.events)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Card(
            child: ListTile(
              title: Text(e.title),
              subtitle: Text('${eventDate(e)} · ${eventTime(e)}'),
              trailing: IconButton(
                tooltip: 'Termin bearbeiten',
                onPressed: () => openPage(
                  context,
                  EventEditorScreen(controller: controller, event: e),
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
              onTap: () => openEvent(context, controller, e.id),
            ),
          ),
        ),
    ],
  );
}

class EventEditorScreen extends StatefulWidget {
  const EventEditorScreen({super.key, required this.controller, this.event});
  final AppController controller;
  final TheaterEvent? event;
  @override
  State<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends State<EventEditorScreen> {
  late final TextEditingController _title, _place, _group;
  late DateTime _start, _end;
  late bool _locked;
  late String _kind;
  String? _production;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _title = TextEditingController(text: e?.title);
    _place = TextEditingController(text: e?.place ?? 'Kolpingheim');
    _group = TextEditingController(text: e?.group ?? 'Ensemble');
    final next = DateTime.now().add(const Duration(days: 1));
    _start = e?.startsAt ?? DateTime(next.year, next.month, next.day, 19);
    _end = e?.endsAt ?? _start.add(const Duration(hours: 2));
    _locked = e?.locked ?? false;
    _kind = e?.kind ?? 'rehearsal';
    _production = e?.productionId;
  }

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _group.dispose();
    super.dispose();
  }

  Future<void> _pick(bool start) async {
    final current = start ? _start : _end;
    final d = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (time == null || !mounted) return;
    setState(() {
      final value = DateTime(d.year, d.month, d.day, time.hour, time.minute);
      if (start) {
        final duration = _end.difference(_start);
        _start = value;
        _end = value.add(duration);
      } else {
        _end = value;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'event.save',
        'id': widget.event?.id,
        'version': widget.event?.version,
        'title': _title.text,
        'startsAt': _start.toUtc().toIso8601String(),
        'endsAt': _end.toUtc().toIso8601String(),
        'place': _place.text,
        'group': _group.text,
        'locked': _locked,
        'type': _kind,
        'productionId': _production,
        'sceneIds': _production == widget.event?.productionId
            ? widget.event?.sceneIds ?? []
            : [],
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Termin löschen?'),
        content: const Text(
          'Der Termin und seine Rückmeldungen werden entfernt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'event.delete',
        'id': widget.event!.id,
        'version': widget.event!.version,
      });
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
    title: widget.event == null ? 'Termin anlegen' : 'Termin bearbeiten',
    children: (context) => [
      TextField(
        controller: _title,
        decoration: const InputDecoration(labelText: 'Titel'),
      ),
      const SizedBox(height: 20),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.calendar_month),
              title: const Text('Beginn'),
              subtitle: Text(
                DateFormat('EEEE, d. MMMM yyyy · HH:mm', 'de').format(_start),
              ),
              onTap: () => _pick(true),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Ende'),
              subtitle: Text(
                DateFormat('d. MMMM yyyy · HH:mm', 'de').format(_end),
              ),
              onTap: () => _pick(false),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _place,
        decoration: const InputDecoration(labelText: 'Ort'),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _group,
        decoration: const InputDecoration(labelText: 'Gruppe'),
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<String>(
        initialValue: _kind,
        decoration: const InputDecoration(labelText: 'Art des Termins'),
        items: const [
          DropdownMenuItem(value: 'rehearsal', child: Text('Probe')),
          DropdownMenuItem(value: 'technical', child: Text('Technikprobe')),
          DropdownMenuItem(value: 'performance', child: Text('Aufführung')),
          DropdownMenuItem(value: 'costume', child: Text('Kostümprobe')),
          DropdownMenuItem(value: 'other', child: Text('Sonstiges')),
        ],
        onChanged: (s) => setState(() => _kind = s!),
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<String>(
        initialValue: _production ?? '',
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Produktion'),
        items: [
          const DropdownMenuItem(value: '', child: Text('Keine Zuordnung')),
          for (final p in widget.controller.productions)
            DropdownMenuItem(
              value: p.id,
              child: Text(p.title, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (s) => setState(() => _production = s == '' ? null : s),
      ),
      const SizedBox(height: 14),
      SwitchListTile(
        value: _locked,
        onChanged: (v) => setState(() => _locked = v),
        title: const Text('Rückmeldungen geschlossen'),
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Termin speichern'),
      ),
      if (widget.event != null)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: TextButton(
            onPressed: _busy ? null : _delete,
            child: const Text('Termin löschen'),
          ),
        ),
    ],
  );
}

class ProductionsAdminScreen extends StatefulWidget {
  const ProductionsAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ProductionsAdminScreen> createState() => _ProductionsAdminScreenState();
}

class _ProductionsAdminScreenState extends State<ProductionsAdminScreen> {
  bool _busy = false;
  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final source = await widget.controller.remote('/admin/script-source');
      if (!mounted) return;
      final selected = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Drehbuch übernehmen'),
          children: [
            for (final p in jsonList(source['productions']).map(jsonMap))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, textValue(p['id'])),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(textValue(p['title'])),
                ),
              ),
          ],
        ),
      );
      if (selected == null) return;
      await widget.controller.remote(
        '/admin/import-script',
        method: 'POST',
        body: {'productionId': selected},
      );
      await widget.controller.refresh();
      await widget.controller.loadScript(selected);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Drehbuch übernommen.')));
      }
    } catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Produktionen & Besetzung',
    children: (context) => [
      FilledButton.icon(
        onPressed: _busy ? null : _import,
        icon: const Icon(Icons.cloud_download_outlined),
        label: const Text('Aus Skript übernehmen'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => openPage(
          context,
          ProductionEditorScreen(controller: widget.controller),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Produktion anlegen'),
      ),
      const SizedBox(height: 22),
      if (_busy) const LinearProgressIndicator(),
      for (final p in widget.controller.productionRecords)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.auto_stories_outlined),
              title: Text(textValue(p['title'])),
              subtitle: Text(
                '${intValue(p['sceneCount'])} Szenen · ${jsonList(p['roles']).length} Rollen',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPage(
                context,
                ProductionEditorScreen(
                  controller: widget.controller,
                  production: p,
                ),
              ),
            ),
          ),
        ),
    ],
  );
}

class ProductionEditorScreen extends StatefulWidget {
  const ProductionEditorScreen({
    super.key,
    required this.controller,
    this.production,
  });
  final AppController controller;
  final JsonMap? production;
  @override
  State<ProductionEditorScreen> createState() => _ProductionEditorScreenState();
}

class _ProductionEditorScreenState extends State<ProductionEditorScreen> {
  late final TextEditingController _title, _subtitle;
  late JsonMap _casting;
  late Set<int> _directors;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _title = TextEditingController(
      text: textValue(widget.production?['title']),
    );
    _subtitle = TextEditingController(
      text: textValue(widget.production?['subtitle']),
    );
    _casting = jsonMap(widget.production?['casting']);
    _directors = jsonList(
      widget.production?['directorMemberIds'],
    ).map((v) => intValue(v)).toSet();
  }

  @override
  void dispose() {
    _title.dispose();
    _subtitle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.controller.performAction({
        'action': 'production.save',
        'id': widget.production?['id'],
        'version': widget.production?['version'] ?? 1,
        'title': _title.text,
        'subtitle': _subtitle.text,
        'casting': _casting,
        'directorMemberIds': _directors.toList(),
      });
      if (widget.production?['id'] != null) {
        await widget.controller.loadScript(textValue(widget.production!['id']));
      }
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
    title: 'Produktion bearbeiten',
    children: (context) => [
      TextField(
        controller: _title,
        decoration: const InputDecoration(labelText: 'Titel'),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _subtitle,
        decoration: const InputDecoration(labelText: 'Untertitel'),
      ),
      const SectionTitle('Besetzung'),
      for (final r in jsonList(widget.production?['roles']).map(jsonMap))
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: DropdownButtonFormField<int>(
            initialValue: _casting[textValue(r['id'])] == null
                ? 0
                : intValue(_casting[textValue(r['id'])]),
            isExpanded: true,
            decoration: InputDecoration(labelText: textValue(r['name'])),
            items: [
              const DropdownMenuItem(
                value: 0,
                child: Text('Noch nicht besetzt'),
              ),
              for (final m in widget.controller.members.where(
                (m) => m.active || m.id == _casting[textValue(r['id'])],
              ))
                DropdownMenuItem(value: m.id, child: Text(m.name)),
            ],
            onChanged: (id) => setState(() {
              if (id == 0) {
                _casting.remove(textValue(r['id']));
              } else {
                _casting[textValue(r['id'])] = id;
              }
            }),
          ),
        ),
      if (jsonList(widget.production?['roles']).isEmpty)
        const Text('Rollen erscheinen nach dem Drehbuchimport.'),
      const SectionTitle('Regie'),
      for (final m in widget.controller.members.where((m) => m.active))
        CheckboxListTile(
          value: _directors.contains(m.id),
          title: Text(m.name),
          onChanged: (v) => setState(() {
            if (v == true) {
              _directors.add(m.id);
            } else {
              _directors.remove(m.id);
            }
          }),
        ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Speichern'),
      ),
    ],
  );
}
