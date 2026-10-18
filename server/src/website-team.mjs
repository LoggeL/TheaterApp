import { createHash, randomUUID } from 'node:crypto';
import { mkdir, writeFile, unlink } from 'node:fs/promises';
import { resolve } from 'node:path';
import { AppError } from './theater.mjs';

// Public ensemble data of kolpingtheater-ramsen.de/team. The website renders its team pages from
// `src/data/team.json` of the public repository Kolpingtheater-Ramsen/next-theater; the live team
// page decides which profiles are actually published.
export const websiteTeam = Object.freeze({
  siteUrl: 'https://kolpingtheater-ramsen.de',
  dataUrl: 'https://raw.githubusercontent.com/Kolpingtheater-Ramsen/next-theater/main/src/data/team.json',
  maxPhotoBytes: 8 * 1024 * 1024,
});

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];
const clean = (value, max = 200) => typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max) : '';
const umlauts = { ä: 'ae', ö: 'oe', ü: 'ue', ß: 'ss' };

/** Lower-case name without accents or punctuation; mirrors `normalizeName` in the Flutter app. */
export const normalize = value => String(value ?? '').toLowerCase().replace(/[äöüß]/g, c => umlauts[c])
  .normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim();
const tokens = value => normalize(value).split(' ').filter(Boolean);

// Same wording as the website's profile page (src/app/team/[person]/page.tsx).
const jobDescriptions = {
  Regie: 'Künstlerische Leitung und Inszenierung der Produktion',
  Tontechnik: 'Beschallung und Tonmischung bei Aufführungen',
  Lichttechnik: 'Lichtdesign und Beleuchtung der Bühne',
  Bühnenbau: 'Konstruktion und Aufbau der Bühnenkulisse',
  Bühnentechnik: 'Aufbau, Technik und Ablauf auf der Bühne',
  Videotechnik: 'Kameras, Projektion und Videotechnik',
  Kostüme: 'Entwurf und Anfertigung der Kostüme',
  Maske: 'Make-up und Charaktergestaltung der Darsteller',
  Requisite: 'Besorgung und Pflege der Requisiten',
  Organisation: 'Planung und Koordination hinter den Kulissen',
  Fotografie: 'Dokumentation der Aufführungen in Bildern',
  Video: 'Aufnahme und Schnitt der Aufführungen',
  Website: 'Gestaltung und Pflege des digitalen Auftritts',
};

/** Profile slugs linked from the live team page (`/team/<slug>`), lower-cased. */
export function publishedSlugs(html) {
  return new Set([...String(html).matchAll(/\/team\/([A-Za-z0-9_%-]+)/g)].map(m => decodeURIComponent(m[1]).toLowerCase()));
}

/**
 * Turns the website's team data into plays and one profile per person, like the website's
 * profile page: cast, former and crew entries with the same slug are one person. Only public
 * fields are read. With `published`, profiles missing on the live team page are skipped.
 */
export function parseTeam(data, { published = null } = {}) {
  if (!data || !Array.isArray(data.plays) || !Array.isArray(data.current)) throw Error('Unbekanntes Format der Website-Teamdaten.');
  const plays = data.plays.map((p, index) => ({ index, slug: clean(p.slug, 80) || `play-${index}`, title: clean(p.play, 120), year: Number.isInteger(p.year) ? p.year : null, location: clean(p.location, 80) || null, gallery: p.gallery === true }));
  if (plays.some(p => !p.title) || new Set(plays.map(p => p.slug)).size !== plays.length) throw Error('Ungültige Stückliste in den Website-Teamdaten.');
  const people = new Map();
  for (const [kind, entries] of [['cast', data.current], ['former', data.former], ['crew', data.tech]]) {
    for (const e of list(entries)) {
      const id = clean(e?.id, 80); if (!id) continue;
      const slug = clean(e.slug, 80) || id, key = slug.toLowerCase();
      const person = people.get(key) ?? { slug, id, name: '', kinds: [], roles: null, jobs: [], crewSince: null, placeholder: false };
      person.name ||= clean(e.name, 80);
      if (!person.kinds.includes(kind)) person.kinds.push(kind);
      if (kind !== 'crew' && Array.isArray(e.roles) && !person.roles) person.roles = e.roles;
      if (kind === 'crew') {
        person.jobs = list(e.jobs).map(j => clean(j?.job, 60)).filter(Boolean);
        if (Number.isInteger(e.since)) person.crewSince = e.since;
      }
      person.placeholder ||= e.placeholderAvatar === true;
      people.set(key, person);
    }
  }
  const skipped = [], profiles = [];
  for (const [key, p] of people) {
    if (published && !published.has(key)) { skipped.push(p.slug); continue; }
    const credits = list(p.roles).map((role, i) => ({ play: plays[i]?.slug, role: clean(role, 120) })).filter(c => c.play && c.role);
    const castSince = credits.length ? plays.find(x => x.slug === credits[0].play).year : null;
    const current = p.roles ? clean(p.roles[plays.length - 1], 120) : '';
    profiles.push({
      slug: p.slug, name: p.name || p.id, kinds: p.kinds, credits,
      current: current ? { play: plays.at(-1).slug, role: current } : null,
      jobs: [...new Set(p.jobs)].map(job => ({ job, description: jobDescriptions[job] ?? `Beitrag als ${job} im Team` })),
      since: p.kinds.includes('cast') ? castSince : (p.crewSince ?? castSince),
      photo: p.placeholder ? null : `/img/team/avatar/${encodeURIComponent(p.id)}.jpg`,
    });
  }
  return { plays, profiles, skipped };
}

const firstToken = name => tokens(name)[0] ?? '';
/** Whether two role labels mean the same part, e.g. "GRAF" and "Graf Thaddäus", or "Maribel / Mathilde" and "Mathilde". */
export function sameRole(a, b) {
  const parts = value => String(value ?? '').split('/').map(tokens).filter(t => t.length);
  // Word forms count as one word ("jung" / "junge"), short words must be equal.
  const word = (t, u) => t === u || (Math.min(t.length, u.length) >= 4 && (t.startsWith(u) || u.startsWith(t)));
  const within = (x, y) => x.every(t => y.some(u => word(t, u)));
  return parts(a).some(x => parts(b).some(y => within(x, y) || within(y, x)));
}
const generic = role => ['ensemble', 'statisterie', 'portrait'].includes(normalize(role));

/** Links website plays to app productions: same title, a title in brackets ("Sommerstück 2026 (Creepshow)") or a manual link. */
function titleLinks(plays, productions, previous) {
  const links = new Map();
  for (const play of plays) {
    const manual = previous.get(play.slug);
    if (manual?.productionLink === 'manual') { links.set(play.slug, { productionId: manual.productionId ?? null, link: 'manual' }); continue; }
    const want = normalize(play.title);
    const matches = productions.filter(p => {
      const title = normalize(p.title), bracket = normalize(String(p.title ?? '').match(/\(([^)]+)\)/)?.[1]);
      const years = [...String(p.title ?? '').matchAll(/(?:^|\D)((?:19|20)\d{2})(?=\D|$)/g)].map(m => Number(m[1]));
      if (play.year && years.length && !years.includes(play.year)) return false;
      return title === want || bracket === want || ` ${title} `.includes(` ${want} `) && want.split(' ').length >= 2;
    });
    if (matches.length === 1) links.set(play.slug, { productionId: matches[0].id, link: 'title' });
  }
  return links;
}

/** Roles a person plays in an app production, by name and id. */
const rolesIn = (production, personId) => list(production?.roles).filter(r => production.casting?.[r.id] === personId);

/** Facts for and against "website profile p is app member m", from current roles, jobs and linked productions. */
function evidence(p, m, plays, playLinks, productions) {
  const pro = [], contra = [];
  const roleNames = String(m.roleName ?? '').split('·').map(x => x.trim()).filter(Boolean);
  if (p.current && !generic(p.current.role) && roleNames.some(r => sameRole(r, p.current.role))) pro.push(`aktuelle Rolle „${p.current.role}“`);
  for (const { job } of p.jobs) if (roleNames.some(r => normalize(r) === normalize(job))) pro.push(`Aufgabe „${job}“`);
  for (const credit of p.credits) {
    const productionId = playLinks.get(credit.play)?.productionId; if (!productionId) continue;
    const production = productions.find(x => x.id === productionId), title = plays.find(x => x.slug === credit.play)?.title;
    const own = rolesIn(production, m.id);
    if (generic(credit.role)) continue;
    if (own.some(r => sameRole(r.name, credit.role) || sameRole(r.id, credit.role))) pro.push(`„${credit.role}“ in ${title}`);
    else if (own.length) contra.push(`spielt in ${title} „${own.map(r => r.name).join(', ')}“ statt „${credit.role}“`);
  }
  return { pro, contra };
}

function matchPeople(profiles, members, plays, playLinks, productions, previous) {
  const results = new Map(), claimed = new Map();
  const memberById = new Map(members.map(m => [m.id, m]));
  for (const p of profiles) {
    const old = previous.get(p.slug);
    if (old?.personLink === 'manual') {
      results.set(p.slug, { status: old.personId != null && memberById.has(old.personId) ? 'manual' : 'manualNone', personId: memberById.has(old.personId) ? old.personId : null, reason: 'von Hand festgelegt' });
      if (old.personId != null) claimed.set(old.personId, p.slug);
    }
  }
  const suffix = p => { const s = normalize(p.slug), n = normalize(p.name); return s.startsWith(n) && s !== n ? s.slice(n.length).trim() : ''; };
  // Profiles with a distinguishing slug ("LinaK", "julian-technik") claim their person first.
  const order = profiles.filter(p => !results.has(p.slug)).sort((a, b) => Number(!suffix(a)) - Number(!suffix(b)));
  for (const p of order) {
    const name = normalize(p.name), single = !name.includes(' ');
    const candidates = members.filter(m => !claimed.has(m.id) && (normalize(m.name) === name || (single && firstToken(m.name) === name)));
    const facts = new Map(candidates.map(m => [m.id, evidence(p, m, plays, playLinks, productions)]));
    const clear = m => !facts.get(m.id).contra.length;
    const twins = profiles.filter(o => o !== p && normalize(o.name) === name && !(results.get(o.slug)?.personId != null));
    let pick = null, reason = '';
    const extra = suffix(p);
    if (extra) {
      const refined = candidates.filter(m => tokens(m.name).slice(1).some(t => t.startsWith(extra) || (extra.startsWith(t) && t.length >= 1)) && clear(m));
      if (refined.length === 1) { pick = refined[0]; reason = `Namenszusatz „${p.slug}“`; }
    }
    if (!pick) {
      const backed = candidates.filter(m => facts.get(m.id).pro.length && clear(m));
      const exact = candidates.filter(m => normalize(m.name) === name);
      if (backed.length === 1) { pick = backed[0]; reason = facts.get(pick.id).pro.join(', '); }
      else if (!backed.length && candidates.length === 1 && exact.length === 1 && clear(exact[0]) && !twins.length) { pick = exact[0]; reason = 'gleicher Name'; }
    }
    if (pick) { claimed.set(pick.id, p.slug); results.set(p.slug, { status: 'auto', personId: pick.id, reason }); continue; }
    results.set(p.slug, candidates.length
      ? { status: 'uncertain', personId: null, candidates: candidates.map(m => ({ id: m.id, name: m.name, pro: facts.get(m.id).pro, contra: facts.get(m.id).contra })), reason: twins.length ? 'mehrere Website-Profile mit diesem Namen' : candidates.length > 1 ? 'mehrere Personen mit diesem Namen' : 'nur der Vorname stimmt, ohne Bestätigung' }
      : { status: 'none', personId: null, reason: 'keine Person mit diesem Namen' });
  }
  return results;
}

/**
 * Links plays without a title match by their cast: a "Sommerstück/Winterstück <year>" production
 * whose casting agrees with the website roles of already linked people.
 */
function castLinks(plays, productions, playLinks, profiles, people) {
  const report = [];
  const taken = new Set([...playLinks.values()].map(x => x.productionId).filter(Boolean));
  for (const play of plays) {
    if (playLinks.has(play.slug)) continue;
    let best = null;
    for (const production of productions.filter(p => !taken.has(p.id))) {
      const years = [...String(production.title ?? '').matchAll(/(?:^|\D)((?:19|20)\d{2})(?=\D|$)/g)].map(m => Number(m[1]));
      if (!play.year || !years.includes(play.year)) continue;
      let agree = 0, disagree = 0;
      for (const p of profiles) {
        const personId = people.get(p.slug)?.personId, credit = p.credits.find(c => c.play === play.slug);
        if (personId == null || !credit || generic(credit.role)) continue;
        const own = rolesIn(production, personId); if (!own.length) continue;
        if (own.some(r => sameRole(r.name, credit.role) || sameRole(r.id, credit.role))) agree++; else disagree++;
      }
      if (agree && (!best || agree > best.agree)) best = { production, agree, disagree };
    }
    if (!best) continue;
    const sure = best.agree >= 3 && best.agree >= 3 * best.disagree;
    report.push({ play: play.title, production: best.production.title, agree: best.agree, disagree: best.disagree, linked: sure });
    if (sure) { playLinks.set(play.slug, { productionId: best.production.id, link: 'cast' }); taken.add(best.production.id); }
  }
  return report;
}

/** Plans an import: plays with production links and profiles with person links. Writes nothing. */
export function planImport(store, team) {
  const members = store.all('members'), productions = store.all('productions');
  const oldPlays = new Map(store.all('websitePlays').map(x => [x.slug, x])), oldProfiles = new Map(store.all('websiteProfiles').map(x => [x.slug, x]));
  const playLinks = titleLinks(team.plays, productions, oldPlays);
  let people = matchPeople(team.profiles, members, team.plays, playLinks, productions, oldProfiles);
  const productionGuesses = castLinks(team.plays, productions, playLinks, team.profiles, people);
  // Productions linked by their cast can confirm further people.
  if (productionGuesses.some(x => x.linked)) people = matchPeople(team.profiles, members, team.plays, playLinks, productions, oldProfiles);
  const removed = [...oldProfiles.keys()].filter(slug => !team.profiles.some(p => p.slug === slug));
  return { playLinks, people, productionGuesses, removed };
}

const memberName = (store, id) => store.get('members', id)?.name ?? `#${id}`;

/** Human-readable summary of a plan, without any private member data beyond names. */
export function describePlan(store, team, plan) {
  const entries = team.profiles.map(p => ({ slug: p.slug, name: p.name, ...plan.people.get(p.slug) }));
  const by = status => entries.filter(e => e.status === status);
  return {
    profiles: team.profiles.length, skippedUnpublished: team.skipped,
    linked: [...by('auto'), ...by('manual')].map(e => ({ website: e.slug, person: memberName(store, e.personId), reason: e.reason })),
    uncertain: by('uncertain').map(e => ({ website: e.slug, reason: e.reason, candidates: e.candidates.map(c => ({ person: c.name, pro: c.pro, contra: c.contra })) })),
    unmatched: [...by('none'), ...by('manualNone')].map(e => ({ website: e.slug, reason: e.reason })),
    productions: team.plays.map(p => ({ play: `${p.title} (${p.year ?? '?'})`, production: plan.playLinks.get(p.slug)?.productionId ? store.get('productions', plan.playLinks.get(p.slug).productionId)?.title : null, link: plan.playLinks.get(p.slug)?.link ?? null })).filter(x => x.production),
    productionGuesses: plan.productionGuesses, removed: plan.removed,
    photos: team.profiles.filter(p => p.photo).length,
  };
}

/** Downloads and normalises a website portrait (3:4) to WebP; returns null on failures. */
async function loadPhoto(url, fetchImpl) {
  const response = await fetchImpl(url, { redirect: 'error', signal: AbortSignal.timeout(20000) });
  if (!response.ok || !/^image\//.test(response.headers.get('content-type') ?? '')) return null;
  const input = Buffer.from(await response.arrayBuffer());
  if (!input.length || input.length > websiteTeam.maxPhotoBytes) return null;
  const { default: sharp } = await import('sharp');
  const result = await sharp(input, { limitInputPixels: 40_000_000, animated: false }).rotate()
    .resize({ width: 600, height: 800, fit: 'cover', position: 'top', withoutEnlargement: true }).webp({ quality: 82 }).toBuffer({ resolveWithObject: true });
  return { hash: createHash('sha256').update(input).digest('hex'), data: result.data, width: result.info.width, height: result.info.height };
}

/**
 * Stores the planned import. Keeps manual links, never links uncertain people, keeps
 * unchanged photos and removes profiles (and their photos) that left the website.
 */
export async function applyImport(store, team, plan, { mediaDirectory, fetchImpl = fetch, siteUrl = websiteTeam.siteUrl, now = new Date() } = {}) {
  if (!mediaDirectory) throw Error('MEDIA_DIR fehlt: Website-Fotos werden im Medienordner gespeichert.');
  const at = now.toISOString(), photos = new Map(), photoErrors = [], obsolete = [];
  for (const p of team.profiles) {
    if (!p.photo) continue;
    try { const photo = await loadPhoto(new URL(p.photo, siteUrl).href, fetchImpl); if (photo) photos.set(p.slug, photo); else photoErrors.push(p.slug); }
    catch { photoErrors.push(p.slug); }
  }
  await mkdir(resolve(mediaDirectory), { recursive: true });
  const written = [];
  for (const p of team.profiles) {
    const photo = photos.get(p.slug), old = store.get('websiteProfiles', p.slug);
    if (!photo || (old?.photoHash === photo.hash && old.photoId && store.get('media', old.photoId))) continue;
    const id = randomUUID();
    await writeFile(resolve(mediaDirectory, `${id}.webp`), photo.data, { flag: 'wx', mode: 0o600 });
    written.push(id); photo.id = id;
  }
  try {
    store.transaction(() => {
      for (const play of team.plays) {
        const link = plan.playLinks.get(play.slug), old = store.get('websitePlays', play.slug);
        const { index: _index, ...fields } = play;
        store.put('websitePlays', play.slug, { ...fields, productionId: link?.productionId ?? null, productionLink: link?.link ?? null, version: (old?.version ?? 0) + 1, importedAt: at });
      }
      for (const old of store.all('websitePlays')) if (!team.plays.some(p => p.slug === old.slug)) store.delete('websitePlays', old.slug);
      for (const p of team.profiles) {
        const old = store.get('websiteProfiles', p.slug), match = plan.people.get(p.slug), photo = photos.get(p.slug);
        let photoId = old?.photoId ?? null, photoHash = old?.photoHash ?? null;
        if (!p.photo) { if (photoId) obsolete.push(photoId); photoId = null; photoHash = null; }
        else if (photo?.id) {
          if (photoId) obsolete.push(photoId);
          photoId = photo.id; photoHash = photo.hash;
          store.put('media', photo.id, { id: photo.id, kind: 'website', ownerPersonId: null, galleryId: null, caption: '', width: photo.width, height: photo.height, source: new URL(p.photo, siteUrl).href, createdAt: at });
        }
        const manual = match?.status === 'manual' || match?.status === 'manualNone';
        store.put('websiteProfiles', p.slug, { ...p, photoId, photoHash, personId: match?.personId ?? null, personLink: manual ? 'manual' : match?.personId != null ? 'auto' : null, matchReason: match?.reason ?? '', version: (old?.version ?? 0) + 1, importedAt: at });
      }
      for (const slug of plan.removed) { const old = store.get('websiteProfiles', slug); if (old?.photoId) obsolete.push(old.photoId); store.delete('websiteProfiles', slug); }
      for (const id of obsolete) store.delete('media', id);
      store.put('settings', 'websiteTeamImport', { at, profiles: team.profiles.length, plays: team.plays.length });
      store.audit('website-import', 'website.import', `${team.profiles.length} profiles`);
    });
  } catch (e) {
    for (const id of written) await unlink(resolve(mediaDirectory, `${id}.webp`)).catch(() => {});
    throw e;
  }
  for (const id of obsolete) await unlink(resolve(mediaDirectory, `${id}.webp`)).catch(e => { if (e.code !== 'ENOENT') throw e; });
  return { photos: photos.size, newPhotos: written.length, photoErrors, removedPhotos: obsolete.length };
}

/** Fetches the website's team data and the live team page (which profiles are published). */
export async function fetchTeam({ dataUrl = websiteTeam.dataUrl, siteUrl = websiteTeam.siteUrl, fetchImpl = fetch } = {}) {
  const get = async url => { const r = await fetchImpl(url, { signal: AbortSignal.timeout(20000) }); if (!r.ok) throw Error(`${url}: HTTP ${r.status}`); return r; };
  const data = await (await get(dataUrl)).json();
  const published = publishedSlugs(await (await get(new URL('/team', siteUrl).href)).text());
  if (!published.size) throw Error('Auf der Teamseite der Website wurden keine Profile gefunden.');
  return parseTeam(data, { published });
}

/** Whether a member chose to hide the website data in the app. */
const hiddenFor = (store, personId) => personId != null && store.get('members', personId)?.websiteHidden === true;

/** Whether a website photo may be shown: it belongs to a profile whose person did not hide it. */
export function websitePhotoVisible(store, mediaId) {
  const profile = store.all('websiteProfiles').find(p => p.photoId === mediaId);
  return !!profile && !hiddenFor(store, profile.personId);
}

/**
 * Website profiles for the app. Members get the profiles linked to active people who did not
 * hide them; admins also get unlinked and hidden ones (hidden without content) for linking.
 */
export function websiteProfilesView(theater, uid) {
  const a = theater.account(uid), admin = a.role === 'admin', s = theater.store;
  const plays = new Map(s.all('websitePlays').map(p => [p.slug, p]));
  const members = new Map(s.all('members').map(m => [m.id, m]));
  const credit = c => { const play = plays.get(c.play); return play ? { title: play.title, year: play.year, location: play.location, role: c.role, productionId: play.productionId ?? null, galleryUrl: play.gallery ? `${websiteTeam.siteUrl}/gallery/${encodeURIComponent(play.slug)}` : null } : null; };
  const profiles = [];
  for (const p of s.all('websiteProfiles')) {
    const personId = members.has(p.personId) ? p.personId : null, hidden = hiddenFor(s, personId);
    if (!admin && (personId == null || hidden || members.get(personId).active === false)) continue;
    const base = { slug: p.slug, name: p.name, personId, ...(admin ? { personLink: p.personLink ?? null } : {}) };
    if (hidden) { profiles.push({ ...base, hidden: true }); continue; }
    profiles.push({ ...base, kinds: p.kinds, since: p.since ?? null, photoId: p.photoId ?? null, url: `${websiteTeam.siteUrl}/team/${encodeURIComponent(p.slug)}`,
      current: p.current ? credit(p.current) : null, credits: list(p.credits).map(credit).filter(Boolean).reverse(), jobs: list(p.jobs) });
  }
  return { importedAt: s.get('settings', 'websiteTeamImport')?.at ?? null, source: `${websiteTeam.siteUrl}/team`, profiles: profiles.sort((x, y) => x.name.localeCompare(y.name, 'de') || x.slug.localeCompare(y.slug)) };
}

/** Admin: links a website profile to a person or explicitly to nobody; later imports keep it. */
export function linkWebsiteProfile(theater, uid, slug, body) {
  return theater.store.transaction(() => {
    theater.account(uid, true); const s = theater.store, profile = s.get('websiteProfiles', slug);
    if (!profile) fail(404, 'Website-Profil nicht gefunden.');
    const personId = body.personId == null ? null : Number(body.personId);
    if (personId != null && (!Number.isInteger(personId) || !s.get('members', personId))) fail(400, 'Person nicht gefunden.');
    const other = personId == null ? null : s.all('websiteProfiles').find(p => p.slug !== slug && p.personId === personId);
    if (other) fail(409, `Diese Person ist bereits mit dem Website-Profil „${other.name}“ verknüpft.`, 'conflict');
    s.put('websiteProfiles', slug, { ...profile, personId, personLink: 'manual', matchReason: 'von Hand festgelegt', version: (profile.version ?? 0) + 1 });
    s.audit(uid, 'website.link', slug);
    return websiteProfilesView(theater, uid);
  });
}
