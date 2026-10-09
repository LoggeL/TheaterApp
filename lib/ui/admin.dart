import '../core/event_types.dart';
import 'roles_admin.dart';
import 'calendar.dart';
import 'participation.dart';
import 'polls.dart';
import 'slots.dart';
import 'galleries.dart';
import 'profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:intl/intl.dart';
import '../core/app_controller.dart';
import '../core/identity.dart';
import '../core/models.dart';
import 'event_style.dart';
import 'events.dart';
import 'accounts_admin.dart';
import 'rehearsal_admin.dart';
import 'messages.dart';
import 'theme.dart';
import 'audience.dart';

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
    this.scrollController,
    this.cacheExtent,
  });
  final AppController controller;
  final String title;
  final List<Widget> Function(BuildContext) children;
  final List<Widget>? actions;
  final ScrollController? scrollController;

  /// Builds children beyond the viewport, e.g. to scroll to one on open.
  final ScrollCacheExtent? cacheExtent;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: controller.user?.isAdmin != true
          ? const Center(child: Text('Admin-Zugang erforderlich.'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: RefreshIndicator(
                  onRefresh: controller.refresh,
                  child: ListView(
                    controller: scrollController,
                    scrollCacheExtent: cacheExtent,
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
  const ManagementScreen({
    super.key,
    required this.controller,
    this.embedded = false,
  });
  final AppController controller;

  /// Shown as a main section below the app bar instead of its own page.
  final bool embedded;

  List<Widget> _content(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final next = controller.events
        .where((e) => e.endsAt?.isAfter(controller.now) ?? false)
        .firstOrNull;
    final registrations = controller.openRegistrationCount;
    GroupTile tile(
      IconData icon,
      String title,
      Widget target, [
      String? subtitle,
      Color? subtitleColor,
    ]) => GroupTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      onTap: () => openPage(ctx, target),
    );
    return [
      if (next != null) ...[
        _NextEventCard(controller: controller, event: next),
        const SizedBox(height: 28),
      ],
      ResponsiveGroups(
        children: [
          TileGroup(
            title: 'Personen',
            tiles: [
              tile(
                Icons.person_add_alt,
                'Konten & Verknüpfungen',
                AccountsAdminScreen(
                  controller: controller,
                  initialView: registrations > 0 ? 'accounts' : 'people',
                  initialFilter: registrations > 0 ? 'pending' : 'all',
                ),
                registrations == 0
                    ? 'Personen, Rollen und E-Mail-Adressen'
                    : registrations == 1
                    ? '1 neue Registrierung wartet auf Zuordnung'
                    : '$registrations neue Registrierungen warten auf Zuordnung',
                registrations == 0 ? null : theme.colorScheme.primary,
              ),
              tile(
                Icons.groups_outlined,
                'Ensemble verwalten',
                MembersAdminScreen(controller: controller),
                'Personen anlegen, Rollen zuordnen',
              ),
              tile(
                Icons.badge_outlined,
                'Rollen verwalten',
                RolesAdminScreen(controller: controller),
                'Eigene Rollen und Mehrfachzuordnung',
              ),
              tile(
                Icons.event_available_outlined,
                'Teilnahme im Ensemble',
                ParticipationScreen(controller: controller, ensemble: true),
                'Rückmeldungen und Anwesenheit der letzten sechs Monate',
              ),
            ],
          ),
          TileGroup(
            title: 'Planung',
            tiles: [
              tile(
                Icons.calendar_month_outlined,
                'Termine verwalten',
                EventsAdminScreen(controller: controller),
                'Anlegen, ändern, Kalender',
              ),
              tile(
                Icons.edit_calendar_outlined,
                'Terminfinder',
                SlotPoolsScreen(controller: controller),
                'Zeitfenster zum Buchen, z. B. für Fototermine',
              ),
              tile(
                Icons.auto_stories_outlined,
                'Produktionen & Besetzung',
                ProductionsAdminScreen(controller: controller),
                'Stücke, Rollen im Drehbuch, Regie',
              ),
              if (next != null)
                tile(
                  Icons.playlist_add_check,
                  'Szenen planen',
                  ScenePlannerScreen(controller: controller, event: next),
                  'Für ${next.title}',
                ),
            ],
          ),
          TileGroup(
            title: 'Kommunikation',
            tiles: [
              tile(
                Icons.chat_bubble_outline,
                'Mitteilung schreiben',
                MessageComposerScreen(controller: controller),
                'An alle, Rollen oder einzelne Personen',
              ),
              tile(
                Icons.poll_outlined,
                'Abstimmungen',
                PollsScreen(controller: controller),
                'Fragen stellen und auswerten',
              ),
              tile(
                Icons.notifications_outlined,
                'Push-Versand',
                PushAdminScreen(controller: controller),
                'Benachrichtigungen prüfen',
              ),
            ],
          ),
          TileGroup(
            title: 'Medien',
            tiles: [
              tile(
                Icons.photo_library_outlined,
                'Galerien verwalten',
                GalleryListScreen(controller: controller),
                'Alben und Freigaben',
              ),
            ],
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!embedded) {
      return AdminPage(
        controller: controller,
        title: 'Administration',
        children: _content,
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: RefreshIndicator(
          onRefresh: controller.refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 30),
            children: [
              const PageHeader(
                'Administration.',
                subtitle: 'Alles für die Theaterleitung an einem Ort.',
              ),
              ..._content(context),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dark stage card for the next event with the two most common actions.
class _NextEventCard extends StatelessWidget {
  const _NextEventCard({required this.controller, required this.event});
  final AppController controller;
  final TheaterEvent event;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final responded = controller.events
        .where((e) => e.id == event.id)
        .firstOrNull;
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [StageTheme.ink, Color(0xFF2C3530)],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Nächster Termin', color: Color(0xFFFFA584)),
          const SizedBox(height: 12),
          Text(
            event.title,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              _Fact(Icons.event_outlined, eventDate(event)),
              _Fact(Icons.schedule, eventTime(event)),
              if (event.place.isNotEmpty)
                _Fact(Icons.place_outlined, event.place),
              if (responded != null && responded.attendeeCount > 0)
                _Fact(
                  Icons.how_to_reg_outlined,
                  '${responded.attendeeCount} dabei',
                ),
            ],
          ),
          const SizedBox(height: 22),
          LayoutBuilder(
            builder: (context, constraints) {
              final buttons = <Widget>[
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: StageTheme.orange,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => openPage(
                    context,
                    AttendanceEditorScreen(
                      controller: controller,
                      event: event,
                    ),
                  ),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Anwesenheit erfassen'),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white38),
                    minimumSize: const Size(48, 52),
                  ),
                  onPressed: () => openPage(
                    context,
                    ResponsesAdminScreen(controller: controller, event: event),
                  ),
                  icon: const Icon(Icons.how_to_reg_outlined),
                  label: const Text('Rückmeldungen'),
                ),
              ];
              // Equal halves side by side, full-width stack on phones.
              if (constraints.maxWidth < 440) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    buttons[0],
                    const SizedBox(height: 10),
                    buttons[1],
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: buttons[0]),
                  const SizedBox(width: 10),
                  Expanded(child: buttons[1]),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: const Color(0xFFFFA584)),
      const SizedBox(width: 6),
      Flexible(
        child: Text(text, style: const TextStyle(color: Colors.white)),
      ),
    ],
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

class MemberEditorScreen extends StatefulWidget {
  const MemberEditorScreen({super.key, required this.controller, this.member});
  final AppController controller;
  final JsonMap? member;
  @override
  State<MemberEditorScreen> createState() => _MemberEditorScreenState();
}

class _MemberEditorScreenState extends State<MemberEditorScreen> {
  late final TextEditingController _name;
  late bool _active;
  late Set<String> _roles;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: textValue(widget.member?['name']));
    _active = widget.member?['active'] != false;
    _roles = jsonList(
      widget.member?['roleIds'],
    ).map((r) => r.toString()).toSet();
  }

  @override
  void dispose() {
    _name.dispose();
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
        'active': _active,
        'roleIds': _roles.toList(),
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
      const SectionTitle('Rollen'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in widget.controller.personRoles)
            FilterChip(
              label: Text(textValue(r['name'])),
              selected: _roles.contains(r['id']),
              onSelected: _busy
                  ? null
                  : (selected) => setState(() {
                      if (selected) {
                        _roles.add(textValue(r['id']));
                      } else {
                        _roles.remove(r['id']);
                      }
                    }),
            ),
        ],
      ),
      TextButton.icon(
        onPressed: () =>
            openPage(context, RolesAdminScreen(controller: widget.controller)),
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Rollen anpassen'),
      ),
      const SizedBox(height: 16),
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

class EventsAdminScreen extends StatefulWidget {
  const EventsAdminScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<EventsAdminScreen> createState() => _EventsAdminScreenState();
}

class _EventsAdminScreenState extends State<EventsAdminScreen> {
  bool _calendar = false, _showPast = true;
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  final _upcoming = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToUpcoming());
  }

  /// Opens at the next events; the past stays reachable above them.
  void _jumpToUpcoming() {
    final target = _upcoming.currentContext;
    if (!mounted || target == null) return;
    Scrollable.ensureVisible(target);
  }

  /// Chronological cards with a heading whenever the month changes.
  List<Widget> _months(
    BuildContext context,
    List<TheaterEvent> events, {
    bool past = false,
  }) {
    String? month;
    return [
      for (final e in events) ...[
        if (_monthLabel(e) != month) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
            child: Eyebrow(
              month = _monthLabel(e),
              color: past
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : null,
            ),
          ),
        ],
        past
            ? Opacity(opacity: .6, child: _event(context, e))
            : _event(context, e),
      ],
    ];
  }

  String _monthLabel(TheaterEvent e) => e.startsAt == null
      ? 'Ohne Datum'
      : DateFormat('MMMM yyyy', 'de').format(e.startsAt!.toLocal());

  Widget _event(BuildContext context, TheaterEvent e) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      child: ListTile(
        title: Text(e.title),
        subtitle: Text(
          '${eventDate(e)} · ${eventTime(e)}'
          '${e.fromSlotPool ? ' · Terminfinder' : ''}',
        ),
        // Slot pool events follow their bookings and are edited in the pool.
        trailing: e.fromSlotPool
            ? IconButton(
                tooltip: 'Im Terminfinder öffnen',
                onPressed: () =>
                    openSlotPool(context, widget.controller, e.slotPoolId!),
                icon: const Icon(Icons.edit_calendar_outlined),
              )
            : IconButton(
                tooltip: 'Termin bearbeiten',
                onPressed: () => openPage(
                  context,
                  EventEditorScreen(controller: widget.controller, event: e),
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
        onTap: () => openEvent(context, widget.controller, e.id),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AdminPage(
    controller: widget.controller,
    title: 'Termine verwalten',
    // All cards exist up front so the list can open at the upcoming ones.
    cacheExtent: _calendar ? null : const ScrollCacheExtent.pixels(100000),
    actions: [
      IconButton(
        tooltip: 'Termin anlegen',
        onPressed: () =>
            openPage(context, EventEditorScreen(controller: widget.controller)),
        icon: const Icon(Icons.add),
      ),
    ],
    children: (context) {
      final day = widget.controller.events
          .where((e) => eventOnDay(e, _day))
          .toList();
      final now = widget.controller.now;
      final past = [
        for (final e in widget.controller.events)
          if (eventIsPast(e, now)) e,
      ];
      final upcoming = [
        for (final e in widget.controller.events)
          if (!eventIsPast(e, now)) e,
      ];
      return [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('Liste'),
              icon: Icon(Icons.view_agenda_outlined),
            ),
            ButtonSegment(
              value: true,
              label: Text('Kalender'),
              icon: Icon(Icons.calendar_month_outlined),
            ),
          ],
          selected: {_calendar},
          onSelectionChanged: (value) =>
              setState(() => _calendar = value.first),
        ),
        const SizedBox(height: 16),
        if (_calendar) ...[
          RehearsalCalendar(
            selected: _day,
            onSelected: (value) => setState(() => _day = value),
            events: widget.controller.events,
          ),
          const SizedBox(height: 12),
          Text(
            DateFormat.yMMMMEEEEd('de').format(_day),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (day.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'An diesem Tag ist nichts geplant.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final e in day) _event(context, e),
          OutlinedButton.icon(
            onPressed: () => openPage(
              context,
              EventEditorScreen(
                controller: widget.controller,
                initialDay: _day,
              ),
            ),
            icon: const Icon(Icons.add),
            label: Text(
              'Termin am ${DateFormat('d. MMMM', 'de').format(_day)} anlegen',
            ),
          ),
        ] else ...[
          FilledButton.icon(
            onPressed: () => openPage(
              context,
              EventEditorScreen(controller: widget.controller),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Termin anlegen'),
          ),
          if (past.isNotEmpty) ...[
            SectionTitle(
              'Vergangen (${past.length})',
              trailing: TextButton(
                onPressed: () => setState(() => _showPast = !_showPast),
                child: Text(_showPast ? 'Ausblenden' : 'Einblenden'),
              ),
            ),
            if (_showPast) ..._months(context, past, past: true),
          ],
          SectionTitle('Kommend (${upcoming.length})', key: _upcoming),
          if (upcoming.isEmpty)
            Text(
              'Keine kommenden Termine.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ..._months(context, upcoming),
        ],
      ];
    },
  );
}

class EventEditorScreen extends StatefulWidget {
  const EventEditorScreen({
    super.key,
    required this.controller,
    this.event,
    this.initialDay,
  });
  final AppController controller;
  final TheaterEvent? event;

  /// Day preselected for a new event, e.g. from the calendar.
  final DateTime? initialDay;
  @override
  State<EventEditorScreen> createState() => _EventEditorScreenState();
}

class _EventEditorScreenState extends State<EventEditorScreen> {
  late final TextEditingController _title, _place, _description;
  late DateTime _start, _end;
  late bool _locked;
  late String _kind;
  String? _production;
  late Set<String> _roleIds;
  late Set<int> _personIds;
  late Set<String> _productionIds;
  bool _busy = false;

  /// New events notify their invitees by default; edits only on request.
  late bool _push = widget.event == null;
  @override
  void initState() {
    super.initState();
    final e = widget.event;
    _roleIds = {...?e?.roleIds};
    _personIds = {...?e?.personIds};
    _productionIds = {...?e?.productionIds};
    _title = TextEditingController(text: e?.title);
    _description = TextEditingController(text: e?.description);
    _place = TextEditingController(text: e?.place ?? 'Kolpingheim');
    final next =
        widget.initialDay ?? DateTime.now().add(const Duration(days: 1));
    _start = e?.startsAt ?? DateTime(next.year, next.month, next.day, 19);
    _end = e?.endsAt ?? _start.add(const Duration(hours: 2));
    _locked = e?.locked ?? false;
    _kind = e?.kind ?? 'rehearsal';
    _production = e?.productionId;
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _place.dispose();
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
    final push = _push && widget.controller.pushConfigured;
    try {
      await widget.controller.performAction({
        'action': 'event.save',
        'id': widget.event?.id,
        'version': widget.event?.version,
        'title': _title.text,
        'description': _description.text,
        'startsAt': _start.toUtc().toIso8601String(),
        'endsAt': _end.toUtc().toIso8601String(),
        'place': _place.text,
        'locked': _locked,
        'type': _kind,
        'productionId': _production,
        'roleIds': _roleIds.toList(),
        'personIds': _personIds.toList(),
        'productionIds': _productionIds.toList(),
        'sceneIds': _production == widget.event?.productionId
            ? widget.event?.sceneIds ?? []
            : [],
        'push': push,
      });
      if (mounted) {
        if (push) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                widget.controller.pendingCount > 0
                    ? 'Termin vorgemerkt, Benachrichtigung folgt nach der Übertragung.'
                    : 'Termin gespeichert, Benachrichtigung wird verschickt.',
              ),
            ),
          );
        }
        Navigator.pop(context);
      }
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
      TextField(
        controller: _description,
        minLines: 3,
        maxLines: 8,
        maxLength: 5000,
        decoration: const InputDecoration(labelText: 'Beschreibung'),
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
      AudiencePicker(
        controller: widget.controller,
        label: 'Eingeladene Rollen',
        allowEveryone: _personIds.isEmpty && _productionIds.isEmpty,
        selected: _roleIds,
        onChanged: (value) => setState(() => _roleIds = value),
      ),
      const SizedBox(height: 16),
      ProductionAudiencePicker(
        controller: widget.controller,
        selected: _productionIds,
        onChanged: (value) => setState(() => _productionIds = value),
      ),
      const SizedBox(height: 16),
      PersonPicker(
        controller: widget.controller,
        selected: _personIds,
        onChanged: (value) => setState(() => _personIds = value),
      ),
      const SizedBox(height: 8),
      Text(
        'Eingeladen: ${widget.controller.audienceLabel(_roleIds, _personIds, _productionIds)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 20),
      DropdownButtonFormField<String>(
        key: const ValueKey('event-kind'),
        initialValue: _kind,
        decoration: const InputDecoration(labelText: 'Art des Termins'),
        items: eventTypes.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
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
      SwitchListTile(
        key: const ValueKey('event-push'),
        value: _push && widget.controller.pushConfigured,
        onChanged: widget.controller.pushConfigured
            ? (v) => setState(() => _push = v)
            : null,
        title: const Text('Eingeladene per Push benachrichtigen'),
        subtitle: Text(
          widget.controller.pushConfigured
              ? 'Geht an: ${widget.controller.audienceLabel(_roleIds, _personIds, _productionIds)}'
              : 'Push ist noch nicht eingerichtet.',
        ),
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
            color:
                p['id'] == widget.controller.activeProductions.firstOrNull?.id
                ? Theme.of(context).colorScheme.primaryContainer
                : null,
            child: ListTile(
              leading: Icon(
                p['archived'] == true
                    ? Icons.inventory_2_outlined
                    : Icons.auto_stories_outlined,
              ),
              title: Text(textValue(p['title'])),
              subtitle: Text(
                '${p['archived'] == true
                    ? 'Archiv · '
                    : p['id'] == widget.controller.activeProductions.firstOrNull?.id
                    ? 'Neuestes Stück · '
                    : ''}${intValue(p['sceneCount'])} Szenen · ${jsonList(p['roles']).length} Rollen',
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
  late Set<int> _directors, _crew;
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
    _crew = jsonList(
      widget.production?['memberIds'],
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
        'memberIds': _crew.toList(),
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

  Future<void> _archive() async {
    final production = widget.production;
    if (production == null) return;
    setState(() => _busy = true);
    try {
      await widget.controller.setProductionArchived(
        textValue(production['id']),
        production['archived'] != true,
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
      const SectionTitle('Weitere Mitwirkende'),
      Text(
        'Technik, Maske, Souffleuse … Zusammen mit Besetzung und Regie bilden '
        'sie das Ensemble des Stücks, das man bei Terminen, Push und '
        'Mitteilungen als Empfänger wählen kann.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      PersonPicker(
        controller: widget.controller,
        label: 'Ohne Rolle im Drehbuch',
        selected: _crew,
        onChanged: (value) => setState(() => _crew = value),
      ),
      const SizedBox(height: 8),
      Builder(
        builder: (context) {
          final ensemble = {
            ..._casting.values.where((v) => v != null).map(intValue),
            ..._directors,
            ..._crew,
          };
          return Text(
            'Ensemble des Stücks: ${ensemble.length} '
            '${ensemble.length == 1 ? 'Person' : 'Personen'}',
            style: Theme.of(context).textTheme.titleSmall,
          );
        },
      ),
      const SizedBox(height: 24),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Speichern'),
      ),
      if (widget.production != null) ...[
        const SizedBox(height: 20),
        TextButton.icon(
          onPressed: _busy ? null : _archive,
          icon: Icon(
            widget.production!['archived'] == true
                ? Icons.unarchive_outlined
                : Icons.inventory_2_outlined,
          ),
          label: Text(
            widget.production!['archived'] == true
                ? 'Aus Archiv zurückholen'
                : 'Ins Archiv verschieben',
          ),
        ),
      ],
    ],
  );
}
