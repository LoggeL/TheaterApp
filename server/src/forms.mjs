import { randomUUID } from 'node:crypto';
import { AppError } from './theater.mjs';

// Forms are kept apart from the general snapshot: answers and signatures are
// returned only by an authenticated, purpose-specific request.
export const formLimits = Object.freeze({ fields: 40, options: 40, templateBytes: 65536, strokes: 100, points: 5000 });
const fail = (status, message, code) => { throw new AppError(status, message, code); };
const object = value => value != null && typeof value === 'object' && !Array.isArray(value);
const string = (value, label, max, required = false) => {
  if (value == null && !required) return '';
  if (typeof value !== 'string' || value.length > max || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value)) fail(400, `${label} ist ungültig oder zu lang.`);
  const result = value.trim();
  if (required && !result) fail(400, `${label} fehlt.`);
  return result;
};
const version = (actual, expected) => {
  if (!Number.isSafeInteger(actual) || actual !== expected) fail(409, 'Das Formular wurde inzwischen geändert. Bitte neu laden.', 'version_conflict');
};
const stamp = theater => theater.clock().toISOString();
const fieldTypes = new Set(['text', 'multiline', 'choice', 'checkbox', 'date']);
const berlinDay = at => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(at);
export const formSubmissionDays = 365;
const realDate = value => {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(+parsed) && parsed.toISOString().slice(0, 10) === value;
};
export const formClosed = (form, at) => !!form?.deleteAfter && form.deleteAfter <= berlinDay(at);
export const submissionExpired = (submission, at) => formClosed(submission.form, at) || Date.parse(submission.submittedAt) <= +at - formSubmissionDays * 86400000;

/** A deleted receipt permanently invalidates earlier submit intents for this pair.
 * Only this counter remains; no answer, signature or request hash is retained.
 * An expired receipt will be deleted on the next write/purge, so reads already
 * expose the generation that a new submission needs after that deletion. */
function submissionGeneration(store, messageId, personId, at) {
  const id = `${messageId}:${personId}`, generation = store.get('formGenerations', id)?.generation ?? 0;
  const receipt = store.get('formSubmissions', id);
  return generation + (receipt && submissionExpired(receipt, at) ? 1 : 0);
}

function definition(body, at) {
  if (!Array.isArray(body.fields) || body.fields.length < 1 || body.fields.length > formLimits.fields) fail(400, `Bitte 1 bis ${formLimits.fields} Felder anlegen.`);
  if (body.signatureRequired != null && typeof body.signatureRequired !== 'boolean') fail(400, 'Die Unterschriften-Einstellung ist ungültig.');
  const ids = new Set();
  const fields = body.fields.map(field => {
    if (!object(field) || !fieldTypes.has(field.type)) fail(400, 'Unbekannter Feldtyp.');
    if (typeof field.id !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(field.id) || ['constructor', 'prototype', '__proto__'].includes(field.id) || ids.has(field.id)) fail(400, 'Feldkennungen müssen eindeutig und gültig sein.');
    ids.add(field.id);
    if (field.required != null && typeof field.required !== 'boolean') fail(400, 'Die Pflichtfeld-Einstellung ist ungültig.');
    const result = { id: field.id, type: field.type, label: string(field.label, 'Feldname', field.type === 'checkbox' ? 2000 : 200, true), required: field.required === true };
    if (field.type === 'choice') {
      if (!Array.isArray(field.options) || field.options.length < 2 || field.options.length > formLimits.options) fail(400, `Eine Auswahl braucht 2 bis ${formLimits.options} Möglichkeiten.`);
      result.options = field.options.map(option => string(option, 'Auswahlmöglichkeit', 200, true));
      if (new Set(result.options).size !== result.options.length) fail(400, 'Auswahlmöglichkeiten dürfen nicht doppelt vorkommen.');
    }
    return result;
  });
  const deleteAfter = body.deleteAfter == null || body.deleteAfter === '' ? null : body.deleteAfter;
  if (deleteAfter != null && (!realDate(deleteAfter) || deleteAfter <= berlinDay(at))) fail(400, 'Bitte ein gültiges Löschdatum nach dem heutigen Tag wählen.');
  const result = {
    title: string(body.title, 'Formulartitel', 160, true),
    description: string(body.description, 'Beschreibung', 10000), fields,
    signatureRequired: body.signatureRequired === true,
    confirmationText: string(body.confirmationText, 'Bestätigungstext', 2000, true),
    deleteAfter,
  };
  if (Buffer.byteLength(JSON.stringify(result)) > formLimits.templateBytes) fail(413, 'Das Formular ist zu groß.');
  return result;
}

export function formTemplates(theater, uid) {
  theater.account(uid, true);
  return { templates: theater.store.all('formTemplates').sort((a, b) => b.updatedAt.localeCompare(a.updatedAt) || a.title.localeCompare(b.title, 'de')) };
}

export function saveForm(theater, account, body) {
  theater.account(account.uid, true);
  const old = body.id ? theater.store.get('formTemplates', body.id) : null;
  if (body.id && !old) fail(404, 'Formular nicht gefunden.');
  if (old) version(body.version, old.version);
  const at = stamp(theater), id = old?.id ?? randomUUID();
  const template = { id, ...definition(body, theater.clock()), version: (old?.version ?? 0) + 1, archived: old?.archived === true, createdAt: old?.createdAt ?? at, updatedAt: at };
  theater.store.put('formTemplates', id, template);
  return { id, version: template.version, template };
}

export function archiveForm(theater, account, body) {
  theater.account(account.uid, true);
  const old = theater.store.get('formTemplates', body.id);
  if (!old) fail(404, 'Formular nicht gefunden.');
  version(body.version, old.version);
  if (typeof body.archived !== 'boolean') fail(400, 'Bitte den Archivierungsstatus angeben.');
  const template = { ...old, archived: body.archived, version: old.version + 1, updatedAt: stamp(theater) };
  theater.store.put('formTemplates', old.id, template);
  return { id: old.id, version: template.version, template };
}

/** A publication freezes the selected version, including the confirmation. */
export function attachForm(theater, body) {
  if (body.formId == null || body.formId === '') return null;
  if (typeof body.formId !== 'string') fail(400, 'Ungültiges Formular.');
  const template = theater.store.get('formTemplates', body.formId);
  if (!template) fail(404, 'Formular nicht gefunden.');
  if (template.archived) fail(409, 'Das Formular wurde archiviert. Bitte ein anderes auswählen.', 'closed');
  if (formClosed(template, theater.clock())) fail(409, 'Das Löschdatum dieses Formulars ist erreicht. Bitte zuerst die Vorlage anpassen.', 'closed');
  version(body.formVersion, template.version);
  const { archived, createdAt, updatedAt, ...form } = template;
  return form;
}

function readableMessage(theater, account, messageId) {
  const message = theater.store.get('messages', messageId);
  if (!message?.form || !theater.canReadMessage(account, message)) fail(404, 'Formular nicht gefunden.');
  return message;
}

export function messageForm(theater, uid, messageId) {
  const account = theater.account(uid), message = readableMessage(theater, account, messageId);
  const at = theater.clock(), closed = formClosed(message.form, at), own = theater.store.get('formSubmissions', `${message.id}:${account.personId}`);
  return {
    form: message.form,
    mySubmission: own && !closed && !submissionExpired(own, at) ? own : null,
    addressedToMe: theater.messageAddresses(theater.store.get('members', account.personId), message),
    closed,
    submissionGeneration: submissionGeneration(theater.store, message.id, account.personId, at),
  };
}

export function formSubmissions(theater, uid, messageId) {
  const account = theater.account(uid, true), message = readableMessage(theater, account, messageId);
  const at = theater.clock();
  return { submissions: formClosed(message.form, at) ? [] : theater.store.all('formSubmissions').filter(s => s.messageId === message.id && !submissionExpired(s, at)).sort((a, b) => b.submittedAt.localeCompare(a.submittedAt)) };
}

/** Metadata only; never copy response bodies into the persisted app snapshot. */
export function formStatus(account, message, submissions, at) {
  if (!message.form) return {};
  const closed = formClosed(message.form, at), relevant = closed ? [] : submissions.filter(s => s.messageId === message.id && !submissionExpired(s, at));
  return { formClosed: closed, myFormSubmittedAt: relevant.find(s => s.personId === account.personId)?.submittedAt ?? null, ...(account.role === 'admin' ? { formSubmissionCount: relevant.length } : {}) };
}

function answersFor(form, input) {
  if (!object(input)) fail(400, 'Die Antworten sind ungültig.');
  const known = new Set(form.fields.map(f => f.id));
  if (Object.keys(input).some(key => !known.has(key))) fail(400, 'Die Antworten enthalten ein unbekanntes Feld.');
  return Object.fromEntries(form.fields.map(field => {
    const value = input[field.id];
    if (field.type === 'checkbox') {
      if (value != null && typeof value !== 'boolean') fail(400, `Bitte „${field.label}“ als Bestätigung ausfüllen.`);
      if (field.required && value !== true) fail(400, `Bitte „${field.label}“ bestätigen.`);
      return [field.id, value === true];
    }
    const answer = string(value, field.label, field.type === 'multiline' ? 10000 : field.type === 'text' ? 1000 : field.type === 'date' ? 10 : 200, field.required);
    if (answer && field.type === 'choice' && !field.options.includes(answer)) fail(400, `Die Auswahl für „${field.label}“ ist ungültig.`);
    if (answer && field.type === 'date' && !realDate(answer)) fail(400, `Bitte für „${field.label}“ ein gültiges Datum eingeben.`);
    return [field.id, answer];
  }));
}

function signatureFor(value, required) {
  if (value == null) { if (required) fail(400, 'Die Unterschrift fehlt.'); return null; }
  if (!object(value) || !Array.isArray(value.strokes) || value.strokes.length > formLimits.strokes) fail(400, 'Die Unterschrift ist ungültig.');
  if (!value.strokes.length) { if (required) fail(400, 'Die Unterschrift fehlt.'); return null; }
  let points = 0, distance = 0;
  const strokes = value.strokes.map(stroke => {
    if (!Array.isArray(stroke) || stroke.length < 2) fail(400, 'Bitte eine vollständige Unterschrift zeichnen.');
    points += stroke.length;
    if (points > formLimits.points) fail(413, 'Die Unterschrift ist zu groß. Bitte erneut zeichnen.');
    return stroke.map((point, i) => {
      if (!Array.isArray(point) || point.length !== 2 || point.some(n => typeof n !== 'number' || !Number.isFinite(n) || n < 0 || n > 1)) fail(400, 'Die Unterschrift enthält ungültige Punkte.');
      if (i) distance += Math.hypot(point[0] - stroke[i - 1][0], point[1] - stroke[i - 1][1]);
      return [...point];
    });
  });
  if (distance < 0.02) fail(400, 'Bitte eine vollständige Unterschrift zeichnen.');
  return { strokes };
}

export function checkFormSubmissionOpen(theater, account, messageId, generation) {
  const message = readableMessage(theater, account, messageId);
  if (!theater.messageAddresses(theater.store.get('members', account.personId), message)) fail(403, 'Dieses Formular ist nicht an dich gerichtet.');
  if (formClosed(message.form, theater.clock())) fail(409, 'Das Löschdatum dieses Formulars ist erreicht. Eine Abgabe ist nicht mehr möglich.', 'closed');
  if (!Number.isSafeInteger(generation) || generation < 0) fail(400, 'Der Abgabestand fehlt. Bitte das Formular neu laden.');
  if (generation !== submissionGeneration(theater.store, message.id, account.personId, theater.clock())) fail(409, 'Die frühere Abgabe wurde gelöscht oder zurückgezogen. Bitte das Formular für eine neue Abgabe neu laden.', 'version_conflict');
  // Runs inside the action transaction, before any cached mutation result is
  // returned. Expiring a receipt advances the same durable generation counter.
  forgetFormSubmissions(theater.store, item => item.messageId === message.id && item.personId === account.personId && submissionExpired(item, theater.clock()));
  return message;
}

export function submitForm(theater, account, body) {
  const message = checkFormSubmissionOpen(theater, account, body.messageId, body.submissionGeneration), form = message.form;
  version(body.formVersion, form.version);
  if (body.confirmed !== true) fail(400, 'Bitte die Angaben vor der Abgabe bestätigen.');
  const answers = answersFor(form, body.answers), signature = signatureFor(body.signature, form.signatureRequired);
  const signerName = string(body.signerName, 'Name der unterschreibenden Person', 120, form.signatureRequired || signature != null);
  const id = `${message.id}:${account.personId}`;
  const old = theater.store.get('formSubmissions', id);
  const confirmed = { answers, signerName, signature, confirmationText: form.confirmationText };
  if (old) {
    const previous = { answers: old.answers, signerName: old.signerName, signature: old.signature, confirmationText: old.confirmationText };
    if (JSON.stringify(previous) !== JSON.stringify(confirmed)) fail(409, 'Du hast dieses Formular bereits abgegeben. Die abgegebenen Angaben bleiben unverändert.', 'already_submitted');
    return { id: old.id, submittedAt: old.submittedAt };
  }
  const submission = {
    id, receiptId: randomUUID(), messageId: message.id, formId: form.id, formVersion: form.version, submissionGeneration: body.submissionGeneration,
    form: structuredClone(form), personId: account.personId, accountUid: account.uid,
    personName: theater.store.get('members', account.personId).name,
    ...confirmed, confirmed: true, submittedAt: stamp(theater),
  };
  theater.store.put('formSubmissions', id, submission);
  // Only the receipt identifier is cached in requests. Reading the full receipt
  // always checks current access and deletion state again.
  return { id, submittedAt: submission.submittedAt };
}

/** Deliberate withdrawal deletes the receipt; subsequent fresh submission is allowed. */
export function withdrawForm(theater, account, body) {
  const personId = body.personId ?? account.personId;
  if (!Number.isSafeInteger(personId) || personId < 1) fail(400, 'Ungültige Person.');
  if (personId !== account.personId && account.role !== 'admin') fail(403, 'Du kannst nur deine eigene Abgabe zurückziehen.');
  const message = readableMessage(theater, account, body.messageId);
  if (typeof body.submittedAt !== 'string' || !Number.isFinite(Date.parse(body.submittedAt)) || typeof body.receiptId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.receiptId)) fail(400, 'Die Kennung der Abgabe fehlt. Bitte neu laden.');
  const id = `${message.id}:${personId}`, submission = theater.store.get('formSubmissions', id);
  if (!submission) return { withdrawn: false };
  if (submission.submittedAt !== body.submittedAt || submission.receiptId !== body.receiptId) fail(409, 'Die Abgabe hat sich inzwischen geändert. Bitte neu laden.', 'version_conflict');
  forgetFormSubmissions(theater.store, item => item.id === id);
  // No receipt id in this result: its replay marker must survive subsequent
  // submissions and withdrawals, so an old retry never deletes a new receipt.
  return { withdrawn: true };
}

export function forgetFormSubmissions(store, predicate) {
  let count = 0;
  for (const submission of store.all('formSubmissions').filter(predicate)) {
    store.delete('formSubmissions', submission.id);
    const id = `${submission.messageId}:${submission.personId}`, generation = (store.get('formGenerations', id)?.generation ?? 0) + 1;
    store.put('formGenerations', id, { id, messageId: submission.messageId, personId: submission.personId, generation });
    store.db.prepare("DELETE FROM requests WHERE json_extract(result, '$.id') = ?").run(submission.id);
    count++;
  }
  return count;
}

/** Permanent message/person deletion also removes its content-free counters.
 * Account deletion keeps them because the same person may receive a new login. */
export function forgetFormGenerations(store, predicate) {
  for (const marker of store.all('formGenerations').filter(predicate)) store.delete('formGenerations', marker.id);
}
