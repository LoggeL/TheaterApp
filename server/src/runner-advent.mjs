import { berlinDay, fromBerlin } from './event-series.mjs';

// Advent Calendar (`adventCalendar` + `adventSchedule` in server/src/wardrobe/catalog.json):
//
// - Each entry in `adventCalendar` corresponds to one Europe/Berlin calendar day starting at day 1
//   of `adventSchedule.year`-`adventSchedule.month` (default: 1..24 December 2026, 00:00 Berlin).
// - Before Day D (today < entry.date): the item is completely hidden from members (not in catalog,
//   assets return 404, not in crates, trades, purchases, or collection counts).
// - On Day D (today === entry.date): the item appears in the wardrobe for the first time (darkened
//   preview portrait while unowned, normal once earned). It is exclusively earnable on that day by
//   completing all three Tagesmissionen (replacing the Missionskiste). Never in crates, trades or
//   Gage purchases on Day D.
// - Missed on Days D+1..24 (today > entry.date && today < generalDate): stays visible in the
//   wardrobe (darkened if unowned) and locked until after the calendar ends (Dec 25 00:00 Berlin).
// - From generalDate onward (Dec 25 00:00 Berlin): all Advent skins join the general Zufallskiste
//   (`random` + mission/ensemble/event/gala/weekly/gage-random) and the standard Gage economy
//   (direct buy for buyable rarities, Tauschvertrag & random crate for Gold), while staying
//   excluded from play-specific crates (`play:*`), play-unique requirements, and starter gifts.

const list = value => Array.isArray(value) ? value : [];
const two = n => String(n).padStart(2, '0');
const monthNames = Object.freeze(['', 'Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember']);

function berlinMidnightIso(year, month, day) {
  const utc = new Date(Date.UTC(year, month - 1, day));
  const y = utc.getUTCFullYear(), m = utc.getUTCMonth(), d = utc.getUTCDate();
  return {
    date: `${y}-${two(m + 1)}-${two(d)}`,
    startsAt: new Date(fromBerlin({ y, m, d, h: 0, mi: 0, s: 0, ms: 0 })).toISOString(),
  };
}

/**
 * Parses `adventCalendar` (and optional `adventSchedule: { year, month }`) from a catalog JSON.
 * Returns null when the catalog declares no `adventSchedule` (keeping synthetic test catalogs
 * without a dated calendar unaffected).
 */
export function parseAdventCalendar(data, rawIds, bad) {
  const schedule = data?.adventSchedule;
  if (schedule === undefined || schedule === null) return null;
  if (typeof schedule !== 'object' || Array.isArray(schedule)) bad('adventSchedule');
  const year = schedule.year, month = schedule.month ?? 12;
  if (!Number.isInteger(year) || year < 2020 || year > 2099) bad('adventSchedule.year');
  if (!Number.isInteger(month) || month < 1 || month > 12) bad('adventSchedule.month');
  const raw = list(data?.adventCalendar);
  if (!raw.length) bad('adventCalendar missing for adventSchedule');
  const seen = new Set();
  const entries = raw.map((entry, index) => {
    const id = entry?.item;
    if (typeof id !== 'string' || !id || !rawIds.has(id) || seen.has(id)) bad(`adventCalendar[${index}]`);
    seen.add(id);
    const day = index + 1;
    const { date, startsAt } = berlinMidnightIso(year, month, day);
    return { day, date, startsAt, item: id, title: typeof entry.title === 'string' && entry.title.trim() ? entry.title.trim() : null };
  });
  const general = berlinMidnightIso(year, month, entries.length + 1);
  return {
    year, month, heading: `${monthNames[month]} ${year}`,
    entries,
    firstDate: entries[0].date,
    lastDate: entries.at(-1).date,
    generalDate: general.date,
    generalStartsAt: general.startsAt,
    byItem: new Map(entries.map(e => [e.item, e])),
    byDate: new Map(entries.map(e => [e.date, e])),
    itemIds: seen,
  };
}

/**
 * Cache-key phase of [calendar] at instant [at] (Date or ms): changes at exact Europe/Berlin
 * midnight on every calendar day and on the general release day.
 */
export function adventPhase(calendar, at) {
  if (!calendar) return '';
  const today = berlinDay(new Date(at).toISOString());
  if (today < calendar.firstDate) return 'pre';
  if (today >= calendar.generalDate) return 'post';
  return today;
}

/**
 * Visibility and exclusivity sets of [calendar] at instant [at] (Date):
 * - `hiddenIds`: calendar items whose day has not arrived yet (must not appear in catalog or files).
 * - `exclusiveIds`: revealed calendar items before `generalDate` (visible in wardrobe, never in
 *   crates, trades, or Gage purchases).
 * - `todayEntry`: the calendar entry for today (Berlin day), or null outside Dec 1..24.
 */
export function adventState(calendar, at) {
  const hiddenIds = new Set(), exclusiveIds = new Set();
  if (!calendar) return { today: null, hiddenIds, exclusiveIds, todayEntry: null, ended: false };
  const today = berlinDay(new Date(at).toISOString());
  const ended = today >= calendar.generalDate;
  for (const entry of calendar.entries) {
    if (today < entry.date) hiddenIds.add(entry.item);
    else if (!ended) exclusiveIds.add(entry.item);
  }
  return { today, hiddenIds, exclusiveIds, todayEntry: calendar.byDate.get(today) ?? null, ended };
}

/**
 * German UI lock hint (short card label + detail text) for a currently exclusive Advent item,
 * or null once the general release has started (or for non-calendar items).
 */
export function adventLockInfo(calendar, itemId, at) {
  const entry = calendar?.byItem.get(itemId);
  if (!entry) return null;
  const today = berlinDay(new Date(at).toISOString());
  if (today >= calendar.generalDate) return null;
  if (today === entry.date) {
    return {
      hint: 'Heute über Tagesmissionen',
      detail: 'Heute exklusiv über alle drei Tagesmissionen freischaltbar – nicht in Kisten, Tauschverträgen oder für Gage.',
    };
  }
  const generalDay = Number(calendar.generalDate.slice(8, 10));
  const generalMonth = monthNames[Number(calendar.generalDate.slice(5, 7))] ?? 'Dezember';
  return {
    hint: `Ab ${generalDay}.${two(Number(calendar.generalDate.slice(5, 7)))}. in der Zufallskiste`,
    detail: `Diesen Skin gab es an seinem Tag über die Tagesmissionen. Ab dem ${generalDay}. ${generalMonth} ist er über die Zufallskiste oder mit Gage erhältlich.`,
  };
}

/**
 * The active Advent calendar item awarded instead of a Missionskiste on Berlin [day] (`YYYY-MM-DD`),
 * or null if [day] is not a calendar day or the item is not active in the live catalog.
 */
export function adventDailyReward(t, day) {
  const c = t.runnerCatalog, calendar = c?.adventCalendar;
  const entry = calendar?.byDate.get(day);
  if (!entry) return null;
  const item = c.byId.get(entry.item);
  if (!item || item.default || item.reward || item.unique) return null;
  return { ...entry, item };
}

/** Readable German display title of an unlocked daily skin (e.g. "Elena als Johanna · Ritterin"). */
export function adventRewardDisplayName(item) {
  if (!item) return '';
  if (!item.role) return item.name;
  if (item.role.startsWith(item.name)) return item.role;
  return `${item.name} als ${item.role}`;
}

/**
 * Admin Skin-Viewer release metadata for a calendar skin (so admins see its scheduled Berlin
 * midnight date and live status without polluting `releases.json`).
 */
export function adventAdminRelease(calendar, itemId, isLive) {
  const entry = calendar?.byItem.get(itemId);
  if (!entry) return null;
  return {
    id: `advent-day-${two(entry.day)}`,
    name: `Adventskalender · Türchen ${entry.day}`,
    startsAt: entry.startsAt,
    active: isLive,
    ready: true,
    part: 'calendar',
  };
}
