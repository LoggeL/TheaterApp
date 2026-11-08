import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export class Store {
  constructor(path = ':memory:') {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS entities(kind TEXT NOT NULL, id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(kind,id));
      CREATE TABLE IF NOT EXISTS accounts(uid TEXT PRIMARY KEY, person_id INTEGER UNIQUE, status TEXT NOT NULL DEFAULT 'pending', role TEXT NOT NULL DEFAULT 'member', data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS passkey_users(uid TEXT PRIMARY KEY REFERENCES accounts(uid) ON DELETE CASCADE, handle TEXT NOT NULL UNIQUE);
      CREATE TABLE IF NOT EXISTS passkeys(id TEXT PRIMARY KEY, uid TEXT NOT NULL REFERENCES accounts(uid) ON DELETE CASCADE, credential_id TEXT NOT NULL UNIQUE, data TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS passkeys_uid ON passkeys(uid);
      CREATE TABLE IF NOT EXISTS passkey_challenges(id TEXT PRIMARY KEY, uid TEXT REFERENCES accounts(uid) ON DELETE CASCADE, kind TEXT NOT NULL, expires_at INTEGER NOT NULL, data TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS passkey_challenges_expiry ON passkey_challenges(expires_at);
      CREATE TABLE IF NOT EXISTS requests(uid TEXT NOT NULL, request_id TEXT NOT NULL, hash TEXT NOT NULL, result TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(uid,request_id));
      CREATE TABLE IF NOT EXISTS audit(id INTEGER PRIMARY KEY, actor TEXT NOT NULL, action TEXT NOT NULL, subject TEXT NOT NULL, created_at TEXT NOT NULL);
      -- Anonymous performance telemetry (perf-telemetry.mjs): grouping columns plus the trimmed report.
      CREATE TABLE IF NOT EXISTS perf_reports(id INTEGER PRIMARY KEY, created_at TEXT NOT NULL, install_id TEXT NOT NULL, session_id TEXT, kind TEXT NOT NULL, platform TEXT NOT NULL, renderer TEXT, browser TEXT, os TEXT, pwa INTEGER, app_version TEXT, app_build TEXT, data TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS perf_reports_created ON perf_reports(created_at);
      -- Finds a report sent twice (perf-telemetry.mjs); not UNIQUE, older rows hold duplicates.
      CREATE INDEX IF NOT EXISTS perf_reports_session ON perf_reports(session_id);
      -- History of the stage runner's Tagesmissionen for balancing (runner-mission-log.mjs): one row
      -- per mission, person and Berlin day (rerolled = 1: the mission a reroll brought).
      CREATE TABLE IF NOT EXISTS runner_mission_log(id INTEGER PRIMARY KEY, day TEXT NOT NULL, person_id INTEGER NOT NULL, slot TEXT NOT NULL, type TEXT NOT NULL, kind TEXT,
        target REAL NOT NULL, reward INTEGER NOT NULL, best REAL, client_stats INTEGER NOT NULL, rerolled INTEGER NOT NULL, rerolled_from TEXT, rerolled_to TEXT,
        done INTEGER NOT NULL, runs INTEGER NOT NULL, runs_to_done INTEGER, progress REAL NOT NULL, minutes_to_done REAL, crate INTEGER NOT NULL,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, data TEXT NOT NULL, UNIQUE(person_id, day, slot, rerolled));
      CREATE INDEX IF NOT EXISTS runner_mission_log_day ON runner_mission_log(day);
    `);
  }
  get(kind, id) {
    const row = this.db.prepare('SELECT data FROM entities WHERE kind=? AND id=?').get(kind, String(id));
    return row ? JSON.parse(row.data) : null;
  }
  all(kind) { return this.db.prepare('SELECT data FROM entities WHERE kind=? ORDER BY id').all(kind).map(r => JSON.parse(r.data)); }
  put(kind, id, value) { this.db.prepare('INSERT INTO entities VALUES (?,?,?) ON CONFLICT(kind,id) DO UPDATE SET data=excluded.data').run(kind, String(id), JSON.stringify(value)); return value; }
  delete(kind, id) { this.db.prepare('DELETE FROM entities WHERE kind=? AND id=?').run(kind, String(id)); }
  account(uid) {
    const r = this.db.prepare('SELECT * FROM accounts WHERE uid=?').get(uid);
    return r ? { ...JSON.parse(r.data), uid: r.uid, personId: r.person_id, status: r.status, role: r.role } : null;
  }
  accounts() { return this.db.prepare('SELECT uid FROM accounts ORDER BY rowid DESC').all().map(r => this.account(r.uid)); }
  saveAccount(a) {
    const { uid, personId, status, role, ...data } = a;
    this.db.prepare(`INSERT INTO accounts VALUES(?,?,?,?,?) ON CONFLICT(uid) DO UPDATE SET person_id=excluded.person_id,status=excluded.status,role=excluded.role,data=excluded.data`).run(uid, personId ?? null, status, role, JSON.stringify(data));
    return a;
  }
  deleteAccount(uid) { this.db.prepare('DELETE FROM accounts WHERE uid=?').run(uid); }
  audit(actor, action, subject) { this.db.prepare('INSERT INTO audit(actor,action,subject,created_at) VALUES(?,?,?,?)').run(actor, action, String(subject), new Date().toISOString()); }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = fn(); this.db.exec('COMMIT'); return result; }
    catch (e) { this.db.exec('ROLLBACK'); throw e; }
  }
  close() { this.db.close(); }
}
