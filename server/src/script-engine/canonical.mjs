/* eslint-disable unicorn/no-new-array -- Preserve upstream canonicalization implementation. */
/**
 * Canonical cue identities adapted from Kolpingtheater Ramsen/Skript.
 * Source commit 3e84c698ecd59776fad5d1f32ebf84e8b481fe19.
 * Copyright (c) 2025 Kolpingtheater Ramsen, MIT; see LICENSE.Skript.
 * Preserve every source-controlled field: revisions intentionally depend on them.
 */
import { generateSceneMicCues } from './mic-cues.mjs';

const CUE_METADATA_FIELDS = new Set(['cueId', 'cueOrdinal'])

/**
 * Return a compact deterministic hash for stable client-side identities.
 * Two independently seeded 32-bit hashes keep accidental collisions unlikely
 * without requiring the asynchronous Web Crypto interface.
 *
 * @param {string} value - Value to hash
 * @returns {string} 16-character hexadecimal hash
 */
export function stableScriptHash(value) {
  const input = String(value)
  let first = 0x811c9dc5
  let second = 0x9e3779b9

  for (let index = 0; index < input.length; index++) {
    const code = input.charCodeAt(index)
    first = Math.imul(first ^ code, 0x01000193)
    second = Math.imul(second ^ code, 0x85ebca6b)
  }

  const firstHex = (first >>> 0).toString(16).padStart(8, '0')
  const secondHex = (second >>> 0).toString(16).padStart(8, '0')
  return `${firstHex}${secondHex}`
}

/**
 * Serialize all sheet-controlled fields in a deterministic order. Cue metadata
 * is intentionally excluded so identities and revisions never depend on
 * themselves.
 *
 * @param {Object} row - Script row
 * @returns {string} Canonical row representation
 */
function canonicalRowValue(row) {
  return JSON.stringify(
    Object.keys(row)
      .filter((key) => !CUE_METADATA_FIELDS.has(key))
      .sort()
      .map((key) => [key, row[key] === null || row[key] === undefined ? '' : row[key]])
  )
}

/**
 * Attach deterministic IDs to source rows before derived cues are inserted.
 * Identical source rows are disambiguated by their occurrence number.
 *
 * @param {Array<Object>} rows - Normalized source rows
 */
function assignSourceCueIds(rows) {
  const occurrences = new Map()

  rows.forEach((row) => {
    const fingerprint = stableScriptHash(canonicalRowValue(row))
    const occurrence = occurrences.get(fingerprint) || 0
    occurrences.set(fingerprint, occurrence + 1)
    row.cueId = `cue-s-${fingerprint}-${occurrence}`
  })
}

/**
 * Attach deterministic IDs to automatically generated microphone rows. Their
 * identity includes the adjacent source cues, so equal mic cues in different
 * parts of a scene do not collapse onto the same ID.
 *
 * @param {Array<Object>} rows - Source and generated rows
 */
function assignDerivedCueIds(rows) {
  const nextSourceIds = new Array(rows.length)
  let nextSourceId = 'end'

  for (let index = rows.length - 1; index >= 0; index--) {
    nextSourceIds[index] = nextSourceId
    if (rows[index].cueId) nextSourceId = rows[index].cueId
  }

  const occurrences = new Map()
  let previousSourceId = 'start'

  rows.forEach((row, index) => {
    if (row.cueId) {
      previousSourceId = row.cueId
      return
    }

    const identityValue = JSON.stringify([
      previousSourceId,
      nextSourceIds[index],
      canonicalRowValue(row),
    ])
    const fingerprint = stableScriptHash(identityValue)
    const occurrence = occurrences.get(fingerprint) || 0
    occurrences.set(fingerprint, occurrence + 1)
    row.cueId = `cue-a-${fingerprint}-${occurrence}`
  })
}

/**
 * Calculate the revision of a complete canonical script model.
 *
 * @param {Array<Object>} data - Canonical rows in playback order
 * @returns {string} Deterministic script revision
 */
export function computeScriptRevision(data) {
  const revisionValue = (data || [])
    .map((row) => canonicalRowValue(row))
    .join('\n')
  return `script-v1-${stableScriptHash(revisionValue)}`
}

export function normalizeScriptRows(data) {
    // Remove scene 0
    let normalized = (Array.isArray(data) ? data : [])
      .filter((row) => row.Szene !== '0')
      .map((row) => ({ ...row }))

    // Trim and uppercase fields
    normalized.forEach((row) => {
      row.Charakter = row.Charakter?.trim().toUpperCase()
      row.Szene = row.Szene?.trim()
      row['Text/Anweisung'] = row['Text/Anweisung']?.trim()
      row.Mikrofon = row.Mikrofon?.trim()
      row.Kategorie = row.Kategorie?.trim()
    })

    // Source IDs must exist before derived rows are inserted, because the
    // neighbouring source cues form the anchors for automatic microphone cues.
    assignSourceCueIds(normalized)

    // Inject automatic mic cues
    normalized = generateSceneMicCues(normalized)

    assignDerivedCueIds(normalized)
    normalized.forEach((row, cueOrdinal) => {
      row.cueOrdinal = cueOrdinal
    })

    return normalized
}
