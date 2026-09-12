import { readFileSync } from 'node:fs';
import { Store } from '../src/store.mjs';
import { importRoster } from '../src/roster-import.mjs';
const [databasePath, inputPath, option] = process.argv.slice(2);
if (!databasePath || !inputPath || (option && option !== '--apply')) throw Error('Usage: node scripts/import-roster.mjs DATABASE INPUT.json [--apply]');
const store = new Store(databasePath);
try { console.log(JSON.stringify(importRoster(store, JSON.parse(readFileSync(inputPath, 'utf8')), { apply: option === '--apply' }), null, 2)); }
finally { store.close(); }
