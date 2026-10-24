// Readable screen names for the performance telemetry: release builds on the
// web shorten class names, so the screens opened with `openPage` are listed
// by type. Unlisted screens fall back to their class name (`page` on the web).
import '../features/absences/ui/absences_screen.dart'
    show AbsencesScreen, AddAbsenceScreen;
import '../features/accounts/ui/account_approval_screen.dart'
    show AccountApprovalScreen;
import '../features/accounts/ui/accounts_admin_screen.dart'
    show AccountsAdminScreen;
import '../features/auth/ui/account_providers_screen.dart'
    show AccountProvidersScreen;
import '../features/auth/ui/password_screen.dart' show PasswordScreen;
import '../features/casting/ui/casting_screen.dart' show CastingScreen;
import '../features/casting/ui/production_overview_screen.dart'
    show ProductionOverviewScreen;
import '../features/casting/ui/script_roles_screen.dart' show ScriptRolesScreen;
import '../features/changelog/ui/changelog_screen.dart' show ChangelogScreen;
import '../features/ensemble/admin/member_editor_screen.dart'
    show MemberEditorScreen;
import '../features/ensemble/admin/roles_admin_screen.dart'
    show RolesAdminScreen;
import '../features/ensemble/ui/member_profile_screen.dart'
    show MemberProfileScreen;
import '../features/ensemble/ui/members_screen.dart' show MembersScreen;
import '../features/events/admin/event_editor_screen.dart'
    show EventEditorScreen;
import '../features/events/admin/events_admin_screen.dart'
    show EventsAdminScreen;
import '../features/events/ui/event_detail_screen.dart' show EventDetailScreen;
import '../features/feedback/ui/feedback_form_screen.dart'
    show FeedbackFormScreen;
import '../features/feedback/ui/feedback_ticket_screen.dart'
    show FeedbackTicketScreen;
import '../features/feedback/ui/my_feedback_screen.dart' show MyFeedbackScreen;
import '../features/galleries/ui/gallery_editor_screen.dart' show GalleryEditor;
import '../features/galleries/ui/gallery_list_screen.dart'
    show GalleryListScreen;
import '../features/galleries/ui/gallery_screen.dart' show GalleryScreen;
import '../features/games/ui/stage_runner_screen.dart' show StageRunnerScreen;
import '../features/games/ui/wardrobe_screen.dart' show WardrobeScreen;
import '../features/messages/ui/message_composer_screen.dart'
    show MessageComposerScreen;
import '../features/messages/ui/message_detail_screen.dart'
    show MessageDetailScreen;
import '../features/messages/ui/messages_screen.dart' show MessagesScreen;
import '../features/participation/ui/participation_screen.dart'
    show ParticipationScreen;
import '../features/polls/ui/poll_detail_screen.dart' show PollDetailScreen;
import '../features/polls/ui/poll_editor_screen.dart' show PollEditorScreen;
import '../features/polls/ui/polls_screen.dart' show PollsScreen;
import '../features/productions/admin/ensembles_admin_screen.dart'
    show EnsemblesAdminScreen;
import '../features/productions/admin/production_editor_screen.dart'
    show ProductionEditorScreen;
import '../features/profile/ui/profile_screen.dart' show ProfileScreen;
import '../features/rehearsal/ui/attendance_screen.dart'
    show AttendanceEditorScreen;
import '../features/rehearsal/ui/responses_screen.dart'
    show ResponsesAdminScreen;
import '../features/rehearsal/ui/scene_planner_screen.dart'
    show ScenePlannerScreen;
import '../features/scripts/ui/annotations/cue_comments_screen.dart'
    show CueCommentsScreen;
import '../features/scripts/ui/line_learning_screen.dart'
    show LineLearningScreen;
import '../features/scripts/ui/productions_screen.dart'
    show ProductionArchiveScreen;
import '../features/scripts/ui/script_reader_screen.dart'
    show ScriptReaderScreen;
import '../features/settings/ui/calendar_feed_screen.dart'
    show CalendarFeedScreen;
import '../features/settings/ui/settings_screen.dart' show SettingsScreen;
import '../features/slots/admin/slot_pool_editor_screen.dart'
    show SlotPoolEditorScreen;
import '../features/slots/ui/slot_pool_screen.dart' show SlotPoolScreen;
import '../features/slots/ui/slot_pools_screen.dart' show SlotPoolsScreen;
import '../features/sync/ui/sync_screen.dart' show SyncScreen;
import 'shell/app_shell.dart' show AdminSectionPage;

const Map<Type, String> perfScreenNames = {
  AbsencesScreen: 'AbsencesScreen',
  AccountApprovalScreen: 'AccountApprovalScreen',
  AccountProvidersScreen: 'AccountProvidersScreen',
  AccountsAdminScreen: 'AccountsAdminScreen',
  AddAbsenceScreen: 'AddAbsenceScreen',
  AdminSectionPage: 'AdminSectionPage',
  AttendanceEditorScreen: 'AttendanceEditorScreen',
  CalendarFeedScreen: 'CalendarFeedScreen',
  CastingScreen: 'CastingScreen',
  ChangelogScreen: 'ChangelogScreen',
  CueCommentsScreen: 'CueCommentsScreen',
  EnsemblesAdminScreen: 'EnsemblesAdminScreen',
  EventDetailScreen: 'EventDetailScreen',
  EventEditorScreen: 'EventEditorScreen',
  EventsAdminScreen: 'EventsAdminScreen',
  FeedbackFormScreen: 'FeedbackFormScreen',
  FeedbackTicketScreen: 'FeedbackTicketScreen',
  GalleryEditor: 'GalleryEditor',
  GalleryListScreen: 'GalleryListScreen',
  GalleryScreen: 'GalleryScreen',
  LineLearningScreen: 'LineLearningScreen',
  MemberEditorScreen: 'MemberEditorScreen',
  MemberProfileScreen: 'MemberProfileScreen',
  MembersScreen: 'MembersScreen',
  MessageComposerScreen: 'MessageComposerScreen',
  MessageDetailScreen: 'MessageDetailScreen',
  MessagesScreen: 'MessagesScreen',
  MyFeedbackScreen: 'MyFeedbackScreen',
  ParticipationScreen: 'ParticipationScreen',
  PasswordScreen: 'PasswordScreen',
  PollDetailScreen: 'PollDetailScreen',
  PollEditorScreen: 'PollEditorScreen',
  PollsScreen: 'PollsScreen',
  ProductionArchiveScreen: 'ProductionArchiveScreen',
  ProductionEditorScreen: 'ProductionEditorScreen',
  ProductionOverviewScreen: 'ProductionOverviewScreen',
  ProfileScreen: 'ProfileScreen',
  ResponsesAdminScreen: 'ResponsesAdminScreen',
  RolesAdminScreen: 'RolesAdminScreen',
  ScenePlannerScreen: 'ScenePlannerScreen',
  ScriptReaderScreen: 'ScriptReaderScreen',
  ScriptRolesScreen: 'ScriptRolesScreen',
  SettingsScreen: 'SettingsScreen',
  SlotPoolEditorScreen: 'SlotPoolEditorScreen',
  SlotPoolScreen: 'SlotPoolScreen',
  SlotPoolsScreen: 'SlotPoolsScreen',
  StageRunnerScreen: 'StageRunnerScreen',
  SyncScreen: 'SyncScreen',
  WardrobeScreen: 'WardrobeScreen',
};
