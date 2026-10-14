// Glucose server for Cloudflare Workers + D1.
//
// A Nightscout-compatible API (v1) that keeps its own copy of your diabetes data.
// Three ways to use it (see README.md):
//   - Copy:       Loop/Trio keep uploading to Nightscout; this server copies from
//                 Nightscout every minute (set NIGHTSCOUT_URL).
//   - Relay:      Loop/Trio upload to this server; every request is passed to your
//                 Nightscout unchanged and Nightscout's answer is returned. A copy is
//                 kept here, even while Nightscout is down (set NIGHTSCOUT_URL).
//   - Standalone: this server is your Nightscout (leave NIGHTSCOUT_URL empty).

const COLLECTIONS = ['entries', 'treatments', 'devicestatus', 'profile'];

// Fields stored as milliseconds in their own column, so date filters work no
// matter how the date text was written.
const DATE_COLUMNS = {
  entries: { date: 'date_ms', dateString: 'date_ms', mills: 'date_ms', sysTime: 'date_ms' },
  treatments: { created_at: 'created_ms', mills: 'created_ms', timestamp: 'created_ms' },
  devicestatus: { created_at: 'created_ms', mills: 'created_ms' },
  profile: { startDate: 'start_ms', created_at: 'created_ms', mills: 'created_ms' },
};
const ORDER = { entries: 'date_ms', treatments: 'created_ms', devicestatus: 'created_ms', profile: 'start_ms' };
const DEFAULT_COUNT = { entries: 10, treatments: 100, devicestatus: 10, profile: 10 };

const READ = 1;
const CARE = 2;
const ADMIN = 3;

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// ---------------------------------------------------------------- helpers

const enc = new TextEncoder();

async function sha1(text) {
  const d = await crypto.subtle.digest('SHA-1', enc.encode(text));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function same(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

/** Optional settings may be typed as "none" or "-" on the setup page: treat as empty. */
function opt(v) {
  const s = String(v ?? '').trim();
  return ['none', '-', 'empty', 'no'].includes(s.toLowerCase()) ? '' : s;
}

function list(v) {
  return String(opt(v))
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS },
  });
}

function jsonText(text, status = 200) {
  return new Response(text, { status, headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS } });
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Accept, api-secret, Authorization',
};

/** Milliseconds since 1970 from a number (ms or seconds) or a date text. */
export function toMs(v) {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'number' || (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim()))) {
    let n = Number(v);
    if (Math.abs(n) < 100000000000) n *= 1000; // seconds
    return Math.round(n);
  }
  if (typeof v === 'string') {
    // An unescaped "+" in a query arrives as a space (Nightscout fixes it the same way).
    const t = Date.parse(v.trim().replace(' ', '+'));
    return Number.isNaN(t) ? null : t;
  }
  return null;
}

const iso = (ms) => new Date(ms).toISOString();

function newId() {
  const t = Math.floor(Date.now() / 1000).toString(16).padStart(8, '0');
  const r = crypto.getRandomValues(new Uint8Array(8));
  return t + [...r].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Parses find[a][b][$gt]=x style query parameters into a nested object. */
export function parseQuery(searchParams) {
  const root = {};
  for (const [key, value] of searchParams) {
    const segs = [];
    const m = key.match(/^([^[\]]+)((?:\[[^\]]*\])*)$/);
    if (!m) continue;
    segs.push(m[1]);
    for (const s of m[2].matchAll(/\[([^\]]*)\]/g)) segs.push(s[1]);
    let node = root;
    for (let i = 0; i < segs.length; i++) {
      // "x[]=a&x[]=b" is a list: each [] gets the next index instead of overwriting.
      const k = segs[i] === '' ? String(Object.keys(node).length) : segs[i];
      if (i === segs.length - 1) {
        node[k] = value;
        break;
      }
      if (node[k] === undefined || typeof node[k] !== 'object') node[k] = {};
      node = node[k];
    }
  }
  return root;
}

// ---------------------------------------------------------------- query filters

const FIELD_RE = /^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*$/;

function values(v) {
  if (Array.isArray(v)) return v;
  if (v && typeof v === 'object') return Object.values(v);
  return String(v).split(',');
}

function typed(v) {
  if (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v)) return Number(v);
  if (v === 'true') return true;
  if (v === 'false') return false;
  return v;
}

/**
 * Turns a Nightscout/MongoDB-style find object into SQL. Unknown operators are
 * refused (HTTP 400) instead of ignored, so a client never gets more records
 * than it asked for.
 */
export function compileFind(node, table, args) {
  const parts = [];
  for (const [key, spec] of Object.entries(node || {})) {
    if (key === '$and' || key === '$or') {
      const items = spec && typeof spec === 'object' ? Object.values(spec) : [];
      // A malformed $and/$or must not be dropped (that would return more records).
      if (!items.length || items.some((x) => !x || typeof x !== 'object')) throw new HttpError(400, `Bad ${key} filter`);
      const subs = items.map((x) => compileFind(x, table, args) || '1');
      parts.push('(' + subs.join(key === '$and' ? ' AND ' : ' OR ') + ')');
      continue;
    }
    if (key.startsWith('$')) throw new HttpError(400, `Unsupported query operator ${key}`);
    if (!FIELD_RE.test(key)) throw new HttpError(400, `Unsupported field ${key}`);
    parts.push(fieldCondition(key, spec, table, args));
  }
  return parts.length ? parts.join(' AND ') : null;
}

function fieldCondition(field, spec, table, args) {
  const ops = spec !== null && typeof spec === 'object' && !Array.isArray(spec) ? spec : { $eq: spec };
  const dateCol = DATE_COLUMNS[table][field];
  const col = field === '_id' ? 'id' : dateCol || `json_extract(doc, '$.${field}')`;
  const conds = [];
  for (const [op, raw] of Object.entries(ops)) {
    if (op === '$exists') {
      const want = raw === true || raw === 'true' || raw === '1';
      conds.push(want ? `${col} IS NOT NULL` : `${col} IS NULL`);
      continue;
    }
    if (op === '$in' || op === '$nin') {
      const vals = values(raw).map((x) => (dateCol ? toMs(x) : typed(x)));
      if (!vals.length) {
        conds.push(op === '$in' ? '0' : '1');
        continue;
      }
      // One bound value (a JSON list), so long lists stay under D1's 100-value limit.
      args.push(JSON.stringify(vals));
      const sub = '(SELECT value FROM json_each(?))';
      conds.push(op === '$in' ? `${col} IN ${sub}` : `(${col} IS NULL OR ${col} NOT IN ${sub})`);
      continue;
    }
    const sqlOp = { $eq: '=', $ne: '<>', $gt: '>', $gte: '>=', $lt: '<', $lte: '<=' }[op];
    if (!sqlOp) throw new HttpError(400, `Unsupported query operator ${op}`);
    if (dateCol) {
      const ms = toMs(raw);
      if (ms === null) throw new HttpError(400, `Not a date: ${raw}`);
      args.push(ms);
      conds.push(`${col} ${sqlOp} ?`);
      continue;
    }
    const v = field === '_id' ? String(raw) : typed(raw);
    if (op === '$eq' || op === '$ne') {
      // Match both the number and the text form, like a loose Mongo match.
      const alts = typeof v === 'number' || typeof v === 'boolean' ? [v, String(raw)] : [v];
      if (typeof v === 'boolean') alts[0] = v ? 1 : 0;
      const ph = alts.map(() => '?').join(', ');
      args.push(...alts);
      conds.push(op === '$eq' ? `${col} IN (${ph})` : `(${col} IS NULL OR ${col} NOT IN (${ph}))`);
    } else {
      args.push(v);
      conds.push(`${col} ${sqlOp} ?`);
    }
  }
  return conds.length ? '(' + conds.join(' AND ') + ')' : '1';
}

// ---------------------------------------------------------------- storage

function docId(doc) {
  return typeof doc._id === 'string' && doc._id !== '' ? doc._id : null;
}

// D1 limits (free plan): 50 queries per invocation, 100 bound values per query and
// 2 MB per value. Lists are therefore sent as ONE bound JSON text and unpacked in
// SQL with json_each, so saving 1000 records costs a couple of queries, not hundreds.
const MAX_JSON_BYTES = 1500000;

/** Splits rows into JSON texts of at most MAX_JSON_BYTES each. */
function jsonChunks(rows) {
  const out = [];
  let cur = [];
  let size = 2;
  for (const r of rows) {
    const s = JSON.stringify(r);
    if (cur.length && size + s.length + 1 > MAX_JSON_BYTES) {
      out.push('[' + cur.join(',') + ']');
      cur = [];
      size = 2;
    }
    cur.push(s);
    size += s.length + 1;
  }
  if (cur.length) out.push('[' + cur.join(',') + ']');
  return out;
}

/** `sql` contains `(?LIST)`, replaced by a json_each over one bound JSON list. */
async function lookup(db, sql, keys) {
  const uniq = [...new Set(keys)];
  if (!uniq.length) return [];
  const found = [];
  for (const part of jsonChunks(uniq)) {
    const rows = await db.prepare(sql.replace('(?LIST)', '(SELECT value FROM json_each(?))')).bind(part).all();
    found.push(...(rows.results || []));
  }
  return found;
}

const UPSERT = {
  entries: ['id, date_ms, type, doc', 'date_ms = excluded.date_ms, type = excluded.type, doc = excluded.doc'],
  treatments: [
    'id, created_ms, event_type, sync_id, doc',
    'created_ms = excluded.created_ms, event_type = excluded.event_type, sync_id = excluded.sync_id, doc = excluded.doc',
  ],
  devicestatus: ['id, created_ms, doc', 'created_ms = excluded.created_ms, doc = excluded.doc'],
  profile: ['id, created_ms, start_ms, doc', 'created_ms = excluded.created_ms, start_ms = excluded.start_ms, doc = excluded.doc'],
};

/** Insert-or-replace many rows (arrays of column values) with one statement per ~1.5 MB. */
function upsertStatements(db, table, rows) {
  const [cols, set] = UPSERT[table];
  const n = cols.split(',').length;
  const picks = Array.from({ length: n }, (_, i) => `json_extract(value, '$[${i}]')`).join(', ');
  // "WHERE true" is needed by SQLite before ON CONFLICT in an INSERT ... SELECT.
  const sql = `INSERT INTO ${table} (${cols}) SELECT ${picks} FROM json_each(?) WHERE true ON CONFLICT(id) DO UPDATE SET ${set}`;
  return jsonChunks(rows).map((t) => db.prepare(sql).bind(t));
}

/** Normalises one record and returns the values used for searching. */
function prepare(table, doc, now) {
  if (table === 'entries') {
    const date = toMs(doc.date) ?? toMs(doc.dateString) ?? now;
    doc.date = date;
    if (!doc.dateString) doc.dateString = iso(date);
    return { date, type: String(doc.type || 'sgv') };
  }
  if (table === 'treatments') {
    const created = toMs(doc.created_at) ?? toMs(doc.timestamp) ?? toMs(doc.mills) ?? now;
    if (!doc.created_at) doc.created_at = iso(created);
    let sync = null;
    for (const k of ['syncIdentifier', 'identifier', 'id', 'pumpId']) {
      if (doc[k] !== undefined && doc[k] !== null && typeof doc[k] !== 'object' && String(doc[k]) !== '') {
        sync = `${k}:${doc[k]}`.slice(0, 128);
        break;
      }
    }
    return { created, type: String(doc.eventType || ''), sync };
  }
  const created = toMs(doc.created_at) ?? toMs(doc.mills) ?? now;
  if (!doc.created_at) doc.created_at = iso(created);
  return { created, start: table === 'profile' ? toMs(doc.startDate) ?? created : null };
}

/**
 * Saves records, merging duplicates the way Nightscout does (same reading time,
 * or same treatment id / time + event type). Returns the saved docs with _id.
 * Costs at most 3 D1 calls for normal batches (lookups + one batch).
 */
export async function saveMany(db, table, docs, now = Date.now()) {
  if (!docs.length) return [];
  const meta = docs.map((d) => prepare(table, d, now));
  const rows = [];
  const drop = new Set();

  if (table === 'entries') {
    const existing = await lookup(db, 'SELECT id, type, date_ms FROM entries WHERE date_ms IN (?LIST)', meta.map((m) => m.date));
    const byKey = new Map(existing.map((r) => [`${r.type}|${r.date_ms}`, r.id]));
    docs.forEach((doc, i) => {
      const key = `${meta[i].type}|${meta[i].date}`;
      const dup = byKey.get(key);
      let id = docId(doc);
      if (!id) id = dup || newId();
      else if (dup && dup !== id) drop.add(dup);
      byKey.set(key, id);
      doc._id = id;
      rows.push([id, meta[i].date, meta[i].type, JSON.stringify(doc)]);
    });
  } else if (table === 'treatments') {
    const bySync = new Map(
      (await lookup(db, 'SELECT id, sync_id FROM treatments WHERE sync_id IN (?LIST)', meta.map((m) => m.sync).filter(Boolean))).map((r) => [r.sync_id, r.id])
    );
    const byTime = new Map(
      (await lookup(db, 'SELECT id, created_ms, event_type, sync_id FROM treatments WHERE created_ms IN (?LIST)', meta.map((m) => m.created))).map((r) => [
        `${r.created_ms}|${r.event_type}`,
        { id: r.id, sync: r.sync_id },
      ])
    );
    docs.forEach((doc, i) => {
      const m = meta[i];
      const timeKey = `${m.created}|${m.type}`;
      const t = byTime.get(timeKey);
      // Same time + type is only the same treatment when the ids don't say otherwise:
      // two different carb entries at the same second must both be kept.
      const timeDup = t && (!m.sync || !t.sync || t.sync === m.sync) ? t.id : null;
      const dup = (m.sync && bySync.get(m.sync)) || timeDup || null;
      let id = docId(doc);
      if (!id) id = dup || newId();
      else if (dup && dup !== id) drop.add(dup);
      if (m.sync) bySync.set(m.sync, id);
      byTime.set(timeKey, { id, sync: m.sync });
      doc._id = id;
      rows.push([id, m.created, m.type, m.sync, JSON.stringify(doc)]);
    });
  } else {
    docs.forEach((doc, i) => {
      const id = docId(doc) || newId();
      doc._id = id;
      rows.push(table === 'profile' ? [id, meta[i].created, meta[i].start, JSON.stringify(doc)] : [id, meta[i].created, JSON.stringify(doc)]);
    });
  }
  const kept = new Set(docs.map((d) => d._id));
  const dropIds = [...drop].filter((id) => !kept.has(id));
  const drops = dropIds.length ? jsonChunks(dropIds).map((t) => db.prepare(`DELETE FROM ${table} WHERE id IN (SELECT value FROM json_each(?))`).bind(t)) : [];
  await db.batch([...drops, ...upsertStatements(db, table, rows)]);
  return docs;
}

// Like Nightscout: a query that names no date (and no _id) only looks at the last
// 4 days, so an app never gets older records than Nightscout would give it.
const DEFAULT_DAYS_MS = 4 * 86400e3;
const NS_DATE_FIELD = { entries: 'date', treatments: 'created_at', devicestatus: 'created_at' };

function findWhere(table, find, args, now = Date.now()) {
  const parts = [];
  const f = compileFind(find, table, args);
  if (f) parts.push(f);
  const field = NS_DATE_FIELD[table];
  const has = (k) => find && typeof find === 'object' && find[k] !== undefined && find[k] !== '';
  if (field && !has(field) && !has('dateString') && !has('_id')) {
    parts.push(`${ORDER[table]} >= ?`);
    args.push(now - DEFAULT_DAYS_MS);
  }
  return parts.length ? parts.join(' AND ') : null;
}

function checkArgs(args) {
  if (args.length > 100) throw new HttpError(400, 'Query has too many values');
}

async function deleteMatching(db, table, idFromPath, query, now = Date.now()) {
  const args = [];
  let where;
  if (idFromPath) {
    where = 'id = ?';
    args.push(idFromPath);
  } else {
    // Never delete everything because a filter was missing.
    if (!compileFind(query.find, table, [])) throw new HttpError(400, 'Give an id or a find filter to delete');
    where = findWhere(table, query.find, args, now);
  }
  checkArgs(args);
  const r = await db.prepare(`DELETE FROM ${table} WHERE ${where}`).bind(...args).run();
  return r.meta?.changes ?? 0;
}

async function readDocs(db, table, query, sub, now = Date.now()) {
  const args = [];
  const where = [];
  if (table === 'entries' && ['sgv', 'mbg', 'cal'].includes(sub)) {
    where.push('type = ?');
    args.push(sub);
  }
  if (table === 'entries' && sub === 'current') {
    where.push("type = 'sgv'");
  }
  const byId = sub && !['sgv', 'mbg', 'cal', 'current', 'list'].includes(sub);
  if (byId) {
    where.push('id = ?');
    args.push(sub);
  }
  const f = byId ? compileFind(query.find, table, args) : findWhere(table, query.find, args, now);
  if (f) where.push(f);
  checkArgs(args);
  // Nightscout's defaults: treatments 1000 when filtered, else 100; others 10.
  const dflt = table === 'treatments' && query.find ? 1000 : DEFAULT_COUNT[table];
  let count = Number(query.count ?? dflt);
  if (!Number.isFinite(count) || count < 1) count = dflt;
  count = Math.min(Math.floor(count), 50000);
  if (sub === 'current') count = 1;
  const sql = `SELECT doc FROM ${table}${where.length ? ' WHERE ' + where.join(' AND ') : ''} ORDER BY ${ORDER[table]} DESC LIMIT ${count}`;
  const rows = await db.prepare(sql).bind(...args).all();
  // Raw JSON texts: no parse + re-stringify, which saves CPU on big answers.
  return (rows.results || []).map((r) => r.doc);
}

// ---------------------------------------------------------------- auth

async function authLevel(request, env, url) {
  const secret = opt(env.API_SECRET);
  if (secret && secret.length < 12) throw new HttpError(500, 'API_SECRET must be at least 12 characters');
  const hash = secret ? await sha1(secret) : '';
  const given = (request.headers.get('api-secret') || '').trim();
  if (secret && given && (same(hash, given.toLowerCase()) || same(secret, given))) return { level: ADMIN, bySecret: true };
  let token = url.searchParams.get('token') || '';
  const auth = request.headers.get('Authorization') || '';
  if (!token && auth.toLowerCase().startsWith('bearer ')) token = auth.slice(7).trim();
  if (token) {
    if (secret && (same(secret, token) || same(hash, token.toLowerCase()))) return { level: ADMIN, bySecret: false };
    if (list(env.CARE_TOKENS).some((t) => same(t, token))) return { level: CARE, bySecret: false };
    if (list(env.READ_TOKENS).some((t) => same(t, token))) return { level: READ, bySecret: false };
  }
  return { level: 0, bySecret: false };
}

function need(have, level) {
  if (have < level) throw new HttpError(401, 'Unauthorized');
}

// ---------------------------------------------------------------- Nightscout link

function nightscoutBase(env) {
  const u = opt(env.NIGHTSCOUT_URL).replace(/\/+$/, '');
  return u ? (/^https?:\/\//.test(u) ? u : `https://${u}`) : '';
}

async function nightscoutSecretHash(env) {
  return sha1(opt(env.NIGHTSCOUT_SECRET) || env.API_SECRET || '');
}

/**
 * The query text exactly as the app sent it (no decoding / re-encoding, so
 * "Temporary+Target", "$" and "[ ]" reach Nightscout byte for byte), minus `token`.
 */
export function relayQuery(search) {
  if (!search || search === '?') return '';
  const kept = search
    .slice(1)
    .split('&')
    .filter((p) => {
      if (p === '') return false;
      let name = p.split('=')[0];
      try {
        name = decodeURIComponent(name.replace(/\+/g, ' '));
      } catch {
        /* keep the raw name */
      }
      return name !== 'token';
    });
  return kept.length ? '?' + kept.join('&') : '';
}

/** Sends the request to Nightscout unchanged (except our token) and returns its answer. */
async function relay(env, method, url, bodyText) {
  const target = nightscoutBase(env) + url.pathname + relayQuery(url.search);
  const headers = { Accept: 'application/json', 'api-secret': await nightscoutSecretHash(env) };
  if (bodyText !== null) headers['Content-Type'] = 'application/json';
  // redirect: manual, so a POST is never silently turned into a GET by a redirect.
  const r = await fetch(target, { method, headers, body: bodyText === null ? undefined : bodyText, redirect: 'manual' });
  const text = await r.text();
  return { status: r.status, text, type: r.headers.get('Content-Type') || 'application/json', location: r.headers.get('Location') };
}

async function setMeta(db, k, v) {
  await db.prepare('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v').bind(k, String(v)).run();
}

/**
 * Copies new records from Nightscout (run every minute by the cron trigger).
 * Free plan: at most 50 fetches + 50 D1 queries per run, 10 ms CPU. Each round
 * costs about 5 calls (1 fetch, up to 3 for saving, 1 bookmark), so a run is capped
 * at COPY_BUDGET calls and small pages; a long backlog is caught up over several minutes.
 */
const COPY_BUDGET = 36;
const COPY_PAGE = 300;
export async function copyFromNightscout(env, now = Date.now()) {
  const base = nightscoutBase(env);
  if (!base) return { skipped: true };
  const db = env.DB;
  const headers = { Accept: 'application/json', 'api-secret': await nightscoutSecretHash(env) };
  const done = {};
  let budget = COPY_BUDGET - 1;
  const marks = Object.fromEntries(((await db.prepare("SELECT k, v FROM meta WHERE k LIKE 'copy_%'").all()).results || []).map((r) => [r.k, r.v]));
  const plans = [
    // `first`: how far back the very first copy starts, so recent data arrives in the first minute.
    { table: 'entries', path: '/api/v1/entries.json', field: 'date', window: 12 * 3600e3, asIso: false, first: 30 * 3600e3 },
    { table: 'treatments', path: '/api/v1/treatments.json', field: 'created_at', window: 12 * 3600e3, asIso: true, first: 30 * 3600e3 },
    { table: 'devicestatus', path: '/api/v1/devicestatus.json', field: 'created_at', window: 3 * 3600e3, asIso: true, first: 6 * 3600e3 },
  ];
  for (const p of plans) {
    let from = Number(marks[`copy_${p.table}`] || now - p.first);
    let win = p.window;
    let saved = 0;
    // At most 3 rounds per table so one busy table cannot starve the others.
    for (let round = 0; round < 3 && from < now && budget >= 5; round++) {
      const start = from - 10 * 60e3; // small overlap; duplicates are merged
      const end = Math.min(now, from + win);
      const u = new URL(base + p.path);
      u.searchParams.set(`find[${p.field}][$gte]`, p.asIso ? iso(start) : String(start));
      u.searchParams.set(`find[${p.field}][$lte]`, p.asIso ? iso(end) : String(end));
      u.searchParams.set('count', String(COPY_PAGE));
      budget--;
      const r = await fetch(u.toString(), { headers });
      if (!r.ok) throw new Error(`Nightscout ${p.table}: HTTP ${r.status}`);
      const docs = await r.json();
      if (!Array.isArray(docs)) break;
      if (docs.length >= COPY_PAGE && win > 10 * 60e3) {
        // Page full (Nightscout returns the newest first, older ones would be
        // missed): retry the same start with a smaller window.
        win = Math.max(10 * 60e3, win / 4);
        continue;
      }
      budget -= 4;
      await saveMany(db, p.table, docs.filter((d) => d && typeof d === 'object'), now);
      saved += docs.length;
      from = end;
      await setMeta(db, `copy_${p.table}`, from);
    }
    done[p.table] = saved;
  }
  // Sensor, site, insulin and battery changes can be days old: fetch the latest of
  // each (last 30 days) at the start and every 6 hours, so their ages are known.
  const lastAges = Number(marks.copy_ages || 0);
  if (now - lastAges > 6 * 3600e3 && budget >= 12) {
    const since = iso(now - 30 * 86400e3);
    for (const type of ['Sensor Change', 'Sensor Start', 'Site Change', 'Insulin Change', 'Pump Battery Change']) {
      const u = new URL(base + '/api/v1/treatments.json');
      u.searchParams.set('find[eventType]', type);
      u.searchParams.set('find[created_at][$gte]', since);
      u.searchParams.set('count', '1');
      budget -= 2;
      const r = await fetch(u.toString(), { headers });
      if (!r.ok) continue;
      const docs = await r.json();
      if (Array.isArray(docs) && docs.length) await saveMany(db, 'treatments', docs.filter((d) => d && typeof d === 'object'), now);
    }
    await setMeta(db, 'copy_ages', now);
  }
  // Profile: the latest one, every 30 minutes.
  const lastProfile = Number(marks.copy_profile || 0);
  if (now - lastProfile > 30 * 60e3 && budget >= 4) {
    const r = await fetch(base + '/api/v1/profile.json?count=1', { headers });
    if (r.ok) {
      const docs = await r.json();
      if (Array.isArray(docs)) await saveMany(db, 'profile', docs.filter((d) => d && typeof d === 'object'), now);
      await setMeta(db, 'copy_profile', now);
    }
  }
  await setMeta(db, 'copy_last_ok', now);
  return done;
}

async function cleanup(env, now = Date.now()) {
  const days = Number(env.KEEP_DAYS || 0);
  if (!(days > 0)) return;
  const cut = now - days * 86400e3;
  await env.DB.batch([
    env.DB.prepare('DELETE FROM entries WHERE date_ms < ?').bind(cut),
    env.DB.prepare('DELETE FROM treatments WHERE created_ms < ?').bind(cut),
    env.DB.prepare('DELETE FROM devicestatus WHERE created_ms < ?').bind(cut),
  ]);
}

// ---------------------------------------------------------------- request handling

function parseBody(text) {
  if (!text) return [];
  let j;
  try {
    j = JSON.parse(text);
  } catch {
    throw new HttpError(400, 'Body is not valid JSON');
  }
  if (Array.isArray(j)) return j.filter((x) => x && typeof x === 'object' && !Array.isArray(x));
  if (j && typeof j === 'object') return [j];
  return [];
}

async function status(env, level) {
  const units = String(env.UNITS || 'mmol').toLowerCase().startsWith('mmol') ? 'mmol' : 'mg/dl';
  const mode = nightscoutBase(env) ? 'copy+relay' : 'standalone';
  return {
    status: 'ok',
    name: 'nightscout',
    version: '15.0.0-glucose-server',
    serverTime: iso(Date.now()),
    serverTimeEpoch: Date.now(),
    apiEnabled: true,
    careportalEnabled: true,
    mode,
    settings: {
      units,
      customTitle: env.SITE_NAME || 'Glucose',
      enable: ['careportal', 'iob', 'cob', 'basal', 'loop', 'pump', 'cage', 'sage', 'iage'],
    },
    authorized: { canRead: level >= READ, canWrite: level >= CARE },
  };
}

async function handle(request, env, ctx) {
  const url = new URL(request.url);
  const method = request.method.toUpperCase();
  if (method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });

  const path = url.pathname.replace(/\/+$/, '').replace(/\.json$/, '') || '/';
  if (path === '/') {
    const name = String(env.SITE_NAME || 'Glucose').replace(/[<>&"]/g, '');
    return new Response(
      `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>${name}</title>` +
        `<body style="font-family:system-ui;background:#0D1117;color:#E6EDF3;padding:32px"><h1>${name}</h1>` +
        `<p>The glucose server is running (${nightscoutBase(env) ? 'copying from Nightscout' : 'standalone'}).</p>`,
      { headers: { 'Content-Type': 'text/html; charset=utf-8' } }
    );
  }

  const parts = path.split('/').filter(Boolean); // api, v1, collection, sub
  const { level, bySecret } = await authLevel(request, env, url);
  const relayOn = !!nightscoutBase(env);
  const query = parseQuery(url.searchParams);

  if (parts[0] !== 'api') throw new HttpError(404, 'Not found');

  // Relay: Loop / Trio talk to this server with the API secret. Everything is
  // passed to Nightscout, and Nightscout's answer goes back unchanged.
  if (relayOn && bySecret) {
    const bodyText = ['POST', 'PUT', 'PATCH', 'DELETE'].includes(method) ? await request.text() : null;
    const coll = parts[1] === 'v1' ? parts[2] : null;
    const sub = parts[3] || '';
    let res = null;
    let failure = null;
    try {
      res = await relay(env, method, url, bodyText && bodyText.length ? bodyText : method === 'DELETE' ? null : bodyText);
    } catch (e) {
      failure = e;
    }
    if (coll && COLLECTIONS.includes(coll) && method !== 'GET') {
      // Keep our copy in step, without slowing the answer to Loop / Trio.
      ctx.waitUntil(
        (async () => {
          try {
            const ok = res && res.status >= 200 && res.status < 300;
            if (method === 'DELETE') {
              if (ok) await deleteMatching(env.DB, coll, sub, query);
              return;
            }
            const sent = parseBody(bodyText || '');
            let docs = sent;
            if (ok && method === 'POST') {
              try {
                const back = JSON.parse(res.text);
                if (Array.isArray(back) && back.length === sent.length && back.every((d) => d && d._id)) docs = back;
              } catch {
                /* keep what was sent */
              }
            }
            // Also kept when Nightscout is down: then this copy has data Nightscout lacks.
            await saveMany(env.DB, coll, docs);
          } catch (e) {
            console.log('copy after relay failed', e && e.message);
          }
        })()
      );
    }
    if (failure) return json({ status: 502, message: `Nightscout could not be reached: ${failure.message}` }, 502);
    const headers = { 'Content-Type': res.type, ...CORS };
    if (res.location) headers.Location = res.location;
    // 204/304 answers must not carry a body (new Response would throw).
    const empty = [101, 204, 205, 304].includes(res.status);
    return new Response(empty ? null : res.text, { status: res.status, headers });
  }

  if (parts[1] !== 'v1') throw new HttpError(404, 'Not found');
  const coll = parts[2] || '';
  const sub = parts[3] || '';

  if (coll === 'status') {
    need(level, READ);
    return json(await status(env, level));
  }
  if (coll === 'verifyauth') {
    return json({
      message: { canRead: level >= READ, canWrite: level >= CARE, isAdmin: level >= ADMIN, message: level ? 'OK' : 'UNAUTHORIZED' },
    });
  }
  if (coll === 'experiments' && sub === 'test') {
    need(level, ADMIN);
    return json({ status: 'ok' });
  }
  const table = coll === 'profiles' ? 'profile' : coll;
  if (!COLLECTIONS.includes(table)) throw new HttpError(404, 'Not found');
  const db = env.DB;

  if (method === 'GET') {
    need(level, READ);
    if (table === 'profile' && sub === 'current') {
      const docs = await readDocs(db, 'profile', { count: 1 }, '');
      if (!docs.length) throw new HttpError(404, 'No profile yet');
      return jsonText(docs[0]);
    }
    return jsonText('[' + (await readDocs(db, table, query, coll === 'profiles' ? 'list' : sub)).join(',') + ']');
  }

  if (method === 'POST' || method === 'PUT') {
    // Careportal keys may log treatments; everything else needs the API secret.
    need(level, table === 'treatments' && method === 'POST' ? CARE : ADMIN);
    const bodyText = await request.text();
    const docs = parseBody(bodyText);
    const saved = await saveMany(db, table, docs);
    if (relayOn && level === CARE && table === 'treatments' && method === 'POST') {
      // A careportal entry made through this server also goes to Nightscout,
      // like an entry made on the Nightscout website (Loop / Trio may read it there).
      // Waited for, so the person logging it knows if it did NOT reach Nightscout.
      let r = null;
      try {
        r = await relay(env, 'POST', url, JSON.stringify(saved.map(({ _id, ...rest }) => rest)));
      } catch {
        /* reported below */
      }
      if (!r || r.status < 200 || r.status >= 300) {
        return json({ status: 502, message: `Saved here, but NOT sent to Nightscout (${r ? 'HTTP ' + r.status : 'unreachable'}). Loop / Trio will not see it.` }, 502);
      }
    }
    if (Math.random() < 0.01) ctx.waitUntil(cleanup(env));
    return json(method === 'PUT' && saved.length === 1 ? saved[0] : saved);
  }

  if (method === 'DELETE') {
    need(level, ADMIN);
    const n = await deleteMatching(db, table, sub, query);
    return json({ n, ok: 1 });
  }
  throw new HttpError(405, 'Method not allowed');
}

export default {
  async fetch(request, env, ctx) {
    try {
      return await handle(request, env, ctx);
    } catch (e) {
      if (e instanceof HttpError) return json({ status: e.status, message: e.message }, e.status);
      console.log('server error', e && e.stack);
      return json({ status: 500, message: 'Server error' }, 500);
    }
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      (async () => {
        try {
          await copyFromNightscout(env);
        } catch (e) {
          console.log('copy from Nightscout failed', e && e.message);
        }
        if (new Date().getUTCMinutes() === 7) await cleanup(env);
      })()
    );
  },
};
