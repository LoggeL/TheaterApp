// Push kinds a person can switch off for themselves. Each key is also the preference in `reminders`;
// a missing preference means on. `changes` predates this list and is switched under "Erinnere mich";
// it covers changed dates, times and places and cancelled (deleted) events.
// `eventPlanned` is the "Du bist eingeplant" reminder of events where everyone counts as attending.
export const memberPushKinds = Object.freeze(['eventAnnouncements', 'eventRequests', 'eventPlanned', 'slots', 'messages', 'polls', 'direct', 'feedbackReplies']);
// Only for the leadership: admins (and, for `lateDeclines`, holders of the events right and the production's directors).
export const leadPushKinds = Object.freeze(['lateDeclines', 'adminRegistrations', 'adminFeedback']);
export const switchablePushKinds = Object.freeze(['changes', ...memberPushKinds, ...leadPushKinds]);

/**
 * The kind of a push job. New jobs may name it as `pushKind`; everything else, including jobs
 * queued by older server versions, is recognized by its target and flags.
 * Kinds outside `switchablePushKinds` are always delivered: `reminders` (scheduled reminders, which
 * honour dayBefore/twoHours/customMinutes when they are scheduled) and `null` for the account
 * approval and the self-requested test push.
 */
export function pushKind(job) {
  if (job.pushKind) return job.pushKind;
  const d = job.data ?? {};
  if (job.adminsOnly) return d.accountUid ? 'adminRegistrations' : d.adminFeedbackId ? 'adminFeedback' : null;
  if (job.manual) return 'direct';
  if (d.feedbackId) return 'feedbackReplies';
  if (d.slotPoolId || job.title?.startsWith('Terminfinder entfällt')) return 'slots';
  if (d.pollId) return 'polls';
  if (d.messageId) return 'messages';
  if (!d.eventId) return null;
  if (job.fixedText) return job.title?.startsWith('Kurzfristige Absage') ? 'lateDeclines' : 'eventAnnouncements';
  if (job.planned) return 'eventPlanned';
  if (job.remindOpen) return 'eventRequests';
  if (job.newEvent || job.announce === 'new') return 'eventAnnouncements';
  // Changes of date, time or place, also announced ones (`announce: 'changed'`) queued before they counted as changes.
  if (job.change || job.announce) return 'changes';
  return 'reminders';
}

/** Whether the person wants pushes of the job's kind; a missing preference means on. */
export function pushWanted(preferences, job) {
  const kind = pushKind(job);
  return !switchablePushKinds.includes(kind) || preferences?.[kind] !== false;
}
