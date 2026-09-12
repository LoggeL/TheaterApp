/** Read-only, canonical adapter for the legacy Skript service. */
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import {
  computeScriptRevision,
  normalizeScriptRows,
} from './script-engine/canonical.mjs';

const CATEGORY = Object.freeze({
  Schauspieler: 'dialogue',
  Anweisung: 'direction',
  Technik: 'technical',
  Licht: 'lighting',
  Einspieler: 'audio',
  Ton: 'audio',
  Requisiten: 'props',
  Szenenbeginn: 'scene',
  Mikrofon: 'microphone',
  Rolle: 'role',
});
const ID = /^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/;
const MAX_BYTES = 20 * 1024 * 1024;
const RAW_FIELDS = [
  'Szene',
  'Kategorie',
  'Charakter',
  'Mikrofon',
  'Text/Anweisung',
];

export class ScriptServiceError extends Error {
  constructor(code, message, status = 502) {
    super(message);
    this.name = 'ScriptServiceError';
    this.code = code;
    this.status = status;
  }
}

export function validateServiceUrl(value, allowLocalHttp = false) {
  if (!value) return null;
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new ScriptServiceError(
      'script_configuration',
      'SCRIPT_SERVICE_URL ist keine gültige URL.',
      503,
    );
  }
  const localhost = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (
    (url.protocol !== 'https:' &&
      !(allowLocalHttp && localhost && url.protocol === 'http:')) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new ScriptServiceError(
      'script_configuration',
      'Skript-Quelle benötigt HTTPS; lokales HTTP nur mit SCRIPT_ALLOW_LOCAL_HTTP=1.',
      503,
    );
  }
  url.pathname = `${url.pathname.replace(/\/+$/, '')}/`;
  return url;
}

function validateRows(rows) {
  if (
    !Array.isArray(rows) ||
    rows.length > 100000 ||
    !rows.every(
      (row) =>
        row &&
        typeof row === 'object' &&
        !Array.isArray(row) &&
        RAW_FIELDS.every(
          (key) => row[key] == null || typeof row[key] === 'string',
        ),
    )
  ) {
    throw new ScriptServiceError(
      'invalid_script',
      'Die Skript-Quelle liefert keine gültigen Drehbuchzeilen.',
    );
  }
  return rows;
}

export function toScriptDocument(productionId, rows, cache = {}) {
  validateRows(rows);
  const canonical = normalizeScriptRows(rows);
  const rolesById = new Map();
  for (const row of rows) {
    if (row.Kategorie?.trim() !== 'Rolle' || !row.Charakter?.trim()) continue;
    const name = row.Charakter.trim().toUpperCase();
    rolesById.set(name, {
      id: name,
      name,
      actor: row['Text/Anweisung']?.trim() || '',
    });
  }
  const scenesById = new Map();
  const cues = canonical.map((row) => {
    const sceneId = row.Szene || '';
    if (sceneId && sceneId !== '0') {
      const scene = scenesById.get(sceneId) || {
        id: sceneId,
        title: `Szene ${sceneId}`,
        ordinal: scenesById.size,
      };
      if (row.Kategorie === 'Szenenbeginn' && row['Text/Anweisung'])
        scene.title = row['Text/Anweisung'];
      scenesById.set(sceneId, scene);
    }
    if (
      row.Kategorie === 'Schauspieler' &&
      row.Charakter &&
      !rolesById.has(row.Charakter)
    ) {
      rolesById.set(row.Charakter, {
        id: row.Charakter,
        name: row.Charakter,
        actor: '',
      });
    }
    return {
      id: row.cueId,
      ordinal: row.cueOrdinal,
      sceneId,
      category: CATEGORY[row.Kategorie] || 'unknown',
      role: row.Charakter || '',
      text: row['Text/Anweisung'] || '',
      microphone: row.Mikrofon || '',
      isAutoMic: row.isAutoMic === true,
      micCueType: row.micCueType || null,
    };
  });
  const collator = new Intl.Collator('de', {
    numeric: true,
    sensitivity: 'base',
  });
  const scenes = [...scenesById.values()]
    .sort((a, b) => {
      const left = Number(a.id),
        right = Number(b.id);
      if (Number.isFinite(left) && Number.isFinite(right)) return left - right;
      if (Number.isFinite(left)) return -1;
      if (Number.isFinite(right)) return 1;
      return collator.compare(a.id, b.id);
    })
    .map((scene, ordinal) => ({ ...scene, ordinal }));
  return {
    productionId,
    revision: computeScriptRevision(canonical),
    cues,
    roles: [...rolesById.values()],
    scenes,
    cache: {
      fetchedAt: cache.fetchedAt || new Date().toISOString(),
      stale: cache.stale === true,
    },
  };
}

export function createScriptService(options = {}) {
  const configuredValue =
    options.baseUrl ?? process.env.SCRIPT_SERVICE_URL ?? '';
  const allowLocalHttp =
    options.allowLocalHttp ?? process.env.SCRIPT_ALLOW_LOCAL_HTTP === '1';
  const fetcher = options.fetch ?? globalThis.fetch;
  const now = options.now ?? Date.now;
  const ttlMs = options.ttlMs ?? 300000;
  const maxStaleMs = options.maxStaleMs ?? 7 * 86400000;
  const cacheDir =
    options.cacheDir ??
    process.env.SCRIPT_CACHE_DIR ??
    path.join(process.cwd(), 'data', 'mobile-script-cache');
  const memory = new Map();
  const pending = new Map();
  const compiled = new Map();
  const namespace = createHash('sha256')
    .update(configuredValue)
    .digest('hex')
    .slice(0, 16);
  const cachePath = (key) =>
    path.join(
      cacheDir,
      `${namespace}-${createHash('sha256').update(key).digest('hex')}.json`,
    );
  const configured = !!configuredValue;

  async function load(key) {
    if (memory.has(key)) return memory.get(key);
    if (cacheDir === false) return null;
    try {
      const entry = JSON.parse(await readFile(cachePath(key), 'utf8'));
      if (
        entry &&
        Number.isFinite(entry.at) &&
        entry.at <= now() + 60000 &&
        'value' in entry
      ) {
        memory.set(key, entry);
        return entry;
      }
    } catch {
      /* Cache is optional; fetch fresh data if absent or invalid. */
    }
    return null;
  }
  async function save(key, entry) {
    memory.set(key, entry);
    if (cacheDir === false) return;
    try {
      await mkdir(cacheDir, { recursive: true, mode: 0o700 });
      const temporary = `${cachePath(key)}.${randomUUID()}.tmp`;
      await writeFile(temporary, JSON.stringify(entry), { mode: 0o600 });
      await rename(temporary, cachePath(key));
    } catch {
      /* A read-only volume must not break the live service. */
    }
  }
  async function fetchJson(relative) {
    const base = validateServiceUrl(configuredValue, allowLocalHttp);
    if (!base)
      throw new ScriptServiceError(
        'script_not_configured',
        'Noch keine Drehbuch-Quelle verbunden.',
        503,
      );
    let response;
    try {
      response = await fetcher(new URL(relative, base), {
        headers: { accept: 'application/json' },
        redirect: 'error',
        signal: AbortSignal.timeout(12000),
      });
    } catch {
      throw new ScriptServiceError(
        'script_unavailable',
        'Die Drehbuch-Quelle ist momentan nicht erreichbar.',
        503,
      );
    }
    if (!response.ok)
      throw new ScriptServiceError(
        'script_upstream_error',
        'Die Drehbuch-Quelle konnte nicht geladen werden.',
        503,
      );
    const contentLength = Number(response.headers.get('content-length'));
    if (contentLength > MAX_BYTES)
      throw new ScriptServiceError(
        'script_too_large',
        'Die Drehbuch-Quelle ist zu groß.',
      );
    let size = 0;
    const chunks = [];
    if (!response.body)
      throw new ScriptServiceError(
        'invalid_script',
        'Die Drehbuch-Quelle liefert keine Daten.',
      );
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > MAX_BYTES)
        throw new ScriptServiceError(
          'script_too_large',
          'Die Drehbuch-Quelle ist zu groß.',
        );
      chunks.push(chunk);
    }
    try {
      return JSON.parse(Buffer.concat(chunks).toString('utf8'));
    } catch {
      throw new ScriptServiceError(
        'invalid_script',
        'Die Drehbuch-Quelle liefert kein gültiges JSON.',
      );
    }
  }
  async function cached(key, relative, validator) {
    const current = await load(key);
    if (current && now() - current.at < ttlMs)
      return {
        value: validator(current.value),
        fetchedAt: new Date(current.at).toISOString(),
        stale: false,
      };
    if (pending.has(key)) return pending.get(key);
    const task = (async () => {
      try {
        const value = validator(await fetchJson(relative));
        const entry = { at: now(), value };
        await save(key, entry);
        return {
          value,
          fetchedAt: new Date(entry.at).toISOString(),
          stale: false,
        };
      } catch (error) {
        if (current && now() - current.at <= maxStaleMs) {
          return {
            value: validator(current.value),
            fetchedAt: new Date(current.at).toISOString(),
            stale: true,
          };
        }
        throw error;
      } finally {
        pending.delete(key);
      }
    })();
    pending.set(key, task);
    return task;
  }
  function catalogValidator(value) {
    if (
      !Array.isArray(value) ||
      value.length > 1000 ||
      !value.every(
        (item) =>
          item &&
          typeof item.id === 'string' &&
          ID.test(item.id) &&
          typeof item.name === 'string',
      )
    ) {
      throw new ScriptServiceError(
        'invalid_catalog',
        'Die Drehbuch-Quelle liefert keine gültige Produktionsliste.',
      );
    }
    return [
      ...new Map(
        value.map((item) => [item.id, { id: item.id, name: item.name }]),
      ).values(),
    ];
  }
  function documentFor(id, entry) {
    let document = compiled.get(id);
    if (!document || document.at !== entry.at) {
      document = {
        at: entry.at,
        value: toScriptDocument(id, entry.value, {
          fetchedAt: new Date(entry.at).toISOString(),
        }),
      };
      compiled.set(id, document);
    }
    return {
      ...document.value,
      cache: {
        fetchedAt: new Date(entry.at).toISOString(),
        stale: now() - entry.at >= ttlMs,
      },
    };
  }
  async function getProductions() {
    if (!configured) return [];
    const catalog = await cached('catalog', 'api/plays', catalogValidator);
    return Promise.all(
      catalog.value.map(async (item) => {
        const script = await load(`script:${item.id}`);
        const doc = script ? documentFor(item.id, script) : null;
        return {
          id: item.id,
          title: item.name,
          subtitle: '',
          revision: doc?.revision ?? null,
          roles: doc?.roles ?? [],
          sceneCount: doc?.scenes.length ?? null,
        };
      }),
    );
  }
  async function getScript(id) {
    if (typeof id !== 'string' || !ID.test(id))
      throw new ScriptServiceError(
        'production_not_found',
        'Produktion nicht gefunden.',
        404,
      );
    const catalog = await cached('catalog', 'api/plays', catalogValidator);
    if (!catalog.value.some((item) => item.id === id))
      throw new ScriptServiceError(
        'production_not_found',
        'Produktion nicht gefunden.',
        404,
      );
    const entry = await cached(
      `script:${id}`,
      `api/script/${encodeURIComponent(id)}`,
      validateRows,
    );
    return {
      ...documentFor(id, {
        at: Date.parse(entry.fetchedAt),
        value: entry.value,
      }),
      cache: { fetchedAt: entry.fetchedAt, stale: entry.stale },
    };
  }
  return { configured, getProductions, getScript };
}

let defaultService;
export function getScriptService() {
  return (defaultService ??= createScriptService());
}
export const getProductions = () => getScriptService().getProductions();
export const getScript = (id) => getScriptService().getScript(id);
