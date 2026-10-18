// Imports the public ensemble data of kolpingtheater-ramsen.de/team (names, roles per play, crew
// jobs, year of joining) into the app database and links it to people. Website photos are not taken
// over; --apply removes photos that earlier imports stored. Without --apply it is a dry run that
// reads the database and the website but writes nothing.
//
//   node scripts/import-website-team.mjs DATABASE [--apply] [--media DIR] [--team team.json] [--team-page team.html]
//
// --team / --team-page read local copies instead of the website (e.g. for tests or offline checks).
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { Store } from '../src/store.mjs';
import { applyImport, describePlan, fetchTeam, parseTeam, planImport, publishedSlugs } from '../src/website-team.mjs';

const usage = 'Usage: node scripts/import-website-team.mjs DATABASE [--apply] [--media DIR] [--team team.json --team-page team.html]';
const values = new Set(['--media', '--team', '--team-page']), options = {}, positional = [];
for (const args = process.argv.slice(2); args.length;) {
  const arg = args.shift();
  if (values.has(arg)) { if (!args.length) throw Error(usage); options[arg] = args.shift(); }
  else if (arg === '--apply') options[arg] = true;
  else if (arg.startsWith('--')) throw Error(usage);
  else positional.push(arg);
}
const [databasePath] = positional, option = name => options[name];
if (!databasePath || positional.length > 1) throw Error(usage);
const apply = options['--apply'] === true;
const team = option('--team')
  ? parseTeam(JSON.parse(readFileSync(option('--team'), 'utf8')), { published: option('--team-page') ? publishedSlugs(readFileSync(option('--team-page'), 'utf8')) : null })
  : await fetchTeam();
const store = new Store(databasePath);
try {
  const plan = planImport(store, team);
  const report = describePlan(store, team, plan);
  if (apply) {
    const mediaDirectory = option('--media') ?? process.env.MEDIA_DIR ?? resolve(dirname(databasePath), 'media');
    report.applied = await applyImport(store, team, plan, { mediaDirectory });
  }
  console.log(JSON.stringify({ dryRun: !apply, ...report }, null, 2));
} finally { store.close(); }
