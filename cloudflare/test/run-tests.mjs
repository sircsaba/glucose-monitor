// Tests for the glucose server, run with plain Node (no Cloudflare account needed):
//   node --experimental-sqlite test/run-tests.mjs
// Optional relay/copy tests: set FAKE_NS_URL and FAKE_NS_SECRET to a Nightscout-compatible
// server (for example the PHP server in ../server) before running.

import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import worker, { copyFromNightscout, parseQuery, compileFind, relayQuery, saveMany } from '../src/index.js';

// ---- a tiny stand-in for Cloudflare D1 on top of SQLite
class Stmt {
  constructor(db, sql) {
    this.db = db;
    this.sql = sql;
    this.args = [];
  }
  bind(...a) {
    const s = new Stmt(this.db, this.sql);
    s.args = a.map((x) => (typeof x === 'boolean' ? (x ? 1 : 0) : x));
    return s;
  }
  async first() {
    return this.db.prepare(this.sql).get(...this.args) ?? null;
  }
  async all() {
    return { results: this.db.prepare(this.sql).all(...this.args) };
  }
  async run() {
    const r = this.db.prepare(this.sql).run(...this.args);
    return { meta: { changes: Number(r.changes) } };
  }
}
class D1 {
  constructor() {
    this.db = new DatabaseSync(':memory:');
    this.db.exec(readFileSync(new URL('../migrations/0001_init.sql', import.meta.url), 'utf8'));
  }
  prepare(sql) {
    return new Stmt(this.db, sql);
  }
  async batch(stmts) {
    const out = [];
    for (const s of stmts) out.push(await s.run());
    return out;
  }
}

const sha1 = (s) => createHash('sha1').update(s).digest('hex');
let failures = 0;
async function test(name, fn) {
  try {
    await fn();
    console.log('ok   ', name);
  } catch (e) {
    failures++;
    console.log('FAIL ', name, '\n     ', e.message);
  }
}

function makeEnv(extra = {}) {
  return {
    DB: new D1(),
    API_SECRET: 'server-secret-123',
    READ_TOKENS: 'readable-abc, readable-two',
    CARE_TOKENS: 'care-xyz',
    SITE_NAME: 'Test',
    UNITS: 'mmol',
    NIGHTSCOUT_URL: '',
    ...extra,
  };
}

async function call(env, method, path, { body, secret, token, headers = {} } = {}) {
  const url = 'https://glucose.example.workers.dev' + path + (token ? (path.includes('?') ? '&' : '?') + 'token=' + token : '');
  const h = { 'Content-Type': 'application/json', ...headers };
  if (secret) h['api-secret'] = sha1(secret);
  const waits = [];
  const ctx = { waitUntil: (p) => waits.push(p) };
  const res = await worker.fetch(new Request(url, { method, headers: h, body: body === undefined ? undefined : JSON.stringify(body) }), env, ctx);
  await Promise.all(waits);
  const text = await res.text();
  let data = null;
  try {
    data = JSON.parse(text);
  } catch {
    data = text;
  }
  return { status: res.status, data };
}

const S = 'server-secret-123';
// Test data is dated yesterday: inside the 4-day window Nightscout uses for queries without a date.
const D = new Date(Date.now() - 86400e3).toISOString().slice(0, 10);
const q = (o) => '?' + new URLSearchParams(o).toString();

// ---------------------------------------------------------------- standalone (Loop)
const env = makeEnv();
const now = Date.now();

await test('auth test: right secret 200, wrong 401', async () => {
  assert.equal((await call(env, 'GET', '/api/v1/experiments/test', { secret: S })).status, 200);
  assert.equal((await call(env, 'GET', '/api/v1/experiments/test', { secret: 'nope' })).status, 401);
  assert.equal((await call(env, 'GET', '/api/v1/experiments/test', { token: 'readable-abc' })).status, 401);
});

await test('Loop uploads entries; same reading twice is kept once', async () => {
  const r = await call(env, 'POST', '/api/v1/entries', {
    secret: S,
    body: [
      { date: now, sgv: 120, type: 'sgv', direction: 'Flat', device: 'loop://iPhone' },
      { date: now - 300000, sgv: 115, type: 'sgv', direction: 'Flat' },
    ],
  });
  assert.equal(r.status, 200);
  assert.equal(r.data.length, 2);
  assert.ok(r.data.every((d) => typeof d._id === 'string' && d._id.length === 24));
  await call(env, 'POST', '/api/v1/entries', { secret: S, body: [{ date: now, sgv: 121, type: 'sgv' }] });
  const g = await call(env, 'GET', '/api/v1/entries/sgv.json' + q({ count: 10, 'find[date][$gte]': now - 3600000 }), { token: 'readable-abc' });
  assert.equal(g.data.length, 2);
  assert.equal(g.data[0].sgv, 121);
});

await test('read token cannot write; no token cannot read', async () => {
  assert.equal((await call(env, 'POST', '/api/v1/entries', { token: 'readable-abc', body: [{ date: now, sgv: 1 }] })).status, 401);
  assert.equal((await call(env, 'GET', '/api/v1/entries/sgv.json')).status, 401);
});

let bolusId;
await test('Loop treatments: upload, duplicate merged, edit with PUT, delete by id', async () => {
  const t = [{ eventType: 'Correction Bolus', created_at: `${D}T14:00:00.000Z`, insulin: 1.5, syncIdentifier: 'abc-1' }];
  const a = await call(env, 'POST', '/api/v1/treatments', { secret: S, body: t });
  const b = await call(env, 'POST', '/api/v1/treatments', { secret: S, body: t });
  assert.equal(a.data[0]._id, b.data[0]._id);
  bolusId = a.data[0]._id;
  await call(env, 'PUT', '/api/v1/treatments', { secret: S, body: { _id: bolusId, eventType: 'Correction Bolus', created_at: `${D}T14:00:00Z`, insulin: 2 } });
  const l = await call(env, 'GET', '/api/v1/treatments.json' + q({ 'find[created_at][$gte]': `${D}T00:00:00Z` }), { token: 'readable-abc' });
  assert.equal(l.data.length, 1);
  assert.equal(l.data[0].insulin, 2);
  // Loop deletes overrides by their UUID _id.
  await call(env, 'PUT', '/api/v1/treatments', { secret: S, body: { _id: 'C0FFEE-UUID', eventType: 'Temporary Override', created_at: `${D}T14:05:00Z` } });
  const d = await call(env, 'DELETE', '/api/v1/treatments/C0FFEE-UUID', { secret: S });
  assert.equal(d.data.n, 1);
  assert.equal((await call(env, 'DELETE', '/api/v1/treatments/missing', { secret: S })).status, 200);
});

await test('DELETE without id or filter is refused (never deletes everything)', async () => {
  assert.equal((await call(env, 'DELETE', '/api/v1/treatments', { secret: S })).status, 400);
  const l = await call(env, 'GET', '/api/v1/treatments.json', { secret: S });
  assert.equal(l.data.length, 1);
});

await test('devicestatus keeps {} objects and pump data; profile/current', async () => {
  await call(env, 'POST', '/api/v1/devicestatus', {
    secret: S,
    body: [{ device: 'loop://iPhone', created_at: `${D}T14:10:00Z`, pump: { reservoir: 112.5, battery: { percent: 68 } }, empty: {} }],
  });
  const ds = await call(env, 'GET', '/api/v1/devicestatus.json?count=40', { token: 'readable-abc' });
  assert.deepEqual(ds.data[0].empty, {});
  assert.equal(ds.data[0].pump.reservoir, 112.5);
  await call(env, 'POST', '/api/v1/profile', { secret: S, body: [{ defaultProfile: 'Default', startDate: `${D}T00:00:00Z`, store: { Default: { dia: 6 } } }] });
  const p = await call(env, 'GET', '/api/v1/profile/current', { secret: S });
  assert.equal(p.data.store.Default.dia, 6);
});

await test('careportal token can log a treatment, read token cannot', async () => {
  assert.equal((await call(env, 'POST', '/api/v1/treatments', { token: 'care-xyz', body: { eventType: 'Note', notes: 'hi' } })).status, 200);
  assert.equal((await call(env, 'POST', '/api/v1/treatments', { token: 'readable-abc', body: { eventType: 'Note' } })).status, 401);
});

// ---------------------------------------------------------------- Trio-style queries
const tenv = makeEnv();
await call(tenv, 'POST', '/api/v1/treatments', {
  secret: S,
  body: [
    { eventType: 'Carb Correction', created_at: `${D}T10:00:00Z`, carbs: 30, enteredBy: 'Trio', id: 'T1' },
    { eventType: 'Carb Correction', created_at: `${D}T11:00:00Z`, carbs: 20, enteredBy: 'careportal', id: 'C1' },
    { eventType: 'Correction Bolus', created_at: `${D}T11:30:00Z`, insulin: 1, enteredBy: 'Trio', id: 'B1' },
    { eventType: 'Temporary Target', created_at: `${D}T12:00:00Z`, duration: 60, targetTop: 140, enteredBy: 'careportal' },
    { eventType: 'Temporary Target', created_at: `${D}T12:30:00Z`, enteredBy: 'careportal' },
  ],
});

await test("Trio carbs query: carbs exist AND enteredBy not Trio (only the remote carbs come back)", async () => {
  const qs = new URLSearchParams();
  qs.append('find[carbs][$exists]', 'true');
  qs.append('find[$and][0][enteredBy][$ne]', 'Trio');
  qs.append('find[$and][1][enteredBy][$ne]', 'iAPS');
  qs.append('find[created_at][$gt]', `${D}T00:00:00.000Z`);
  const r = await call(tenv, 'GET', '/api/v1/treatments.json?' + qs, { secret: S });
  assert.equal(r.status, 200);
  assert.deepEqual(r.data.map((d) => d.id), ['C1']);
});

await test('Trio temp targets: eventType "Temporary+Target" and duration exists', async () => {
  const r = await call(tenv, 'GET', '/api/v1/treatments.json?find[eventType]=Temporary+Target&find[duration][$exists]=true', { secret: S });
  assert.equal(r.data.length, 1);
  assert.equal(r.data[0].duration, 60);
});

await test('Trio deletes carbs with find[id][$eq] (only that one)', async () => {
  const r = await call(tenv, 'DELETE', '/api/v1/treatments.json?find[id][$eq]=T1', { secret: S });
  assert.equal(r.data.n, 1);
  const all = await call(tenv, 'GET', '/api/v1/treatments.json', { secret: S });
  assert.equal(all.data.length, 4);
});

await test('Trio deletes glucose with $or (id or dateString)', async () => {
  const t = Date.parse(`${D}T09:00:00Z`);
  await call(tenv, 'POST', '/api/v1/entries.json', { secret: S, body: [{ date: t, dateString: `${D}T09:00:00.000Z`, sgv: 99, type: 'sgv', id: 'G1' }, { date: t + 300000, sgv: 100, type: 'sgv' }] });
  const qs = new URLSearchParams();
  qs.append('find[$or][0][id][$eq]', 'NOPE');
  qs.append('find[$or][1][dateString][$eq]', `${D}T09:00:00.000Z`);
  const r = await call(tenv, 'DELETE', '/api/v1/entries.json?' + qs, { secret: S });
  assert.equal(r.data.n, 1);
});

await test('unknown query operators are refused, not ignored', async () => {
  const r = await call(tenv, 'GET', '/api/v1/treatments.json?find[notes][$regex]=x', { secret: S });
  assert.equal(r.status, 400);
});

await test('query parser and compiler', async () => {
  const f = parseQuery(new URLSearchParams('find[$and][0][a][$ne]=x&find[b][$gte]=5&count=3'));
  assert.equal(f.count, '3');
  assert.equal(f.find.$and[0].a.$ne, 'x');
  const args = [];
  const sql = compileFind(f.find, 'treatments', args);
  assert.match(sql, /json_extract\(doc, '\$\.a'\)/);
  assert.deepEqual(args, ['x', 5, '5'].slice(0, args.length));
});


// ---------------------------------------------------------------- review fixes
await test('no date in the query: only the last 4 days, like Nightscout (old carbs are not returned)', async () => {
  const e = makeEnv();
  const old = new Date(Date.now() - 6 * 86400e3).toISOString();
  await call(e, 'POST', '/api/v1/treatments', { secret: S, body: [
    { eventType: 'Carb Correction', created_at: old, carbs: 50, enteredBy: 'careportal' },
    { eventType: 'Carb Correction', created_at: `${D}T10:00:00Z`, carbs: 10, enteredBy: 'careportal' },
  ] });
  const r = await call(e, 'GET', '/api/v1/treatments.json?find[carbs][$exists]=true&find[$and][0][enteredBy][$ne]=Trio', { secret: S });
  assert.deepEqual(r.data.map((d) => d.carbs), [10]);
  const withDate = await call(e, 'GET', '/api/v1/treatments.json' + q({ 'find[created_at][$gte]': new Date(Date.now() - 7 * 86400e3).toISOString() }), { secret: S });
  assert.equal(withDate.data.length, 2);
  // Deletes are limited the same way.
  assert.equal((await call(e, 'DELETE', '/api/v1/treatments.json?find[carbs]=50', { secret: S })).data.n, 0);
});

await test('treatments: default count is 1000 with a filter, 100 without (Nightscout defaults)', async () => {
  const e = makeEnv();
  const t0 = Date.now() - 86400e3;
  await call(e, 'POST', '/api/v1/treatments', { secret: S, body: Array.from({ length: 150 }, (_, i) => ({ eventType: 'Note', created_at: new Date(t0 + i * 1000).toISOString(), notes: 'n' + i })) });
  assert.equal((await call(e, 'GET', '/api/v1/treatments.json', { secret: S })).data.length, 100);
  assert.equal((await call(e, 'GET', '/api/v1/treatments.json?find[eventType]=Note', { secret: S })).data.length, 150);
});

await test('big uploads and long $in lists stay under D1 limits (100 values per query, few queries)', async () => {
  const e = makeEnv();
  let queries = 0;
  const prep = e.DB.prepare.bind(e.DB);
  e.DB.prepare = (sql) => (queries++, prep(sql));
  const t0 = Date.now() - 86400e3;
  const body = Array.from({ length: 600 }, (_, i) => ({ date: t0 + i * 60000, sgv: 100 + (i % 50), type: 'sgv' }));
  const r = await call(e, 'POST', '/api/v1/entries', { secret: S, body });
  assert.equal(r.status, 200);
  assert.ok(queries <= 3, `used ${queries} statements`);
  const ids = r.data.slice(0, 150).map((d) => d._id);
  const qs = new URLSearchParams();
  ids.forEach((id, i) => qs.append(`find[_id][$in][${i}]`, id));
  qs.append('count', '1000');
  const g = await call(e, 'GET', '/api/v1/entries.json?' + qs, { secret: S });
  assert.equal(g.status, 200);
  assert.equal(g.data.length, 150);
});

await test('two different carb entries at the same second are both kept', async () => {
  const e = makeEnv();
  const at = `${D}T08:00:00Z`;
  await call(e, 'POST', '/api/v1/treatments', { secret: S, body: [{ eventType: 'Carb Correction', created_at: at, carbs: 20, id: 'A' }] });
  await call(e, 'POST', '/api/v1/treatments', { secret: S, body: [{ eventType: 'Carb Correction', created_at: at, carbs: 15, id: 'B' }] });
  await call(e, 'POST', '/api/v1/treatments', { secret: S, body: [{ eventType: 'Carb Correction', created_at: at, carbs: 15, id: 'B' }] });
  const r = await call(e, 'GET', '/api/v1/treatments.json' + q({ 'find[created_at][$gte]': `${D}T00:00:00Z` }), { secret: S });
  assert.deepEqual(r.data.map((d) => d.carbs).sort(), [15, 20]);
});

await test('malformed $or/$and is refused; x[]=a&x[]=b keeps both values', async () => {
  assert.equal((await call(tenv, 'GET', '/api/v1/treatments.json?find[$or]=x', { secret: S })).status, 400);
  const f = parseQuery(new URLSearchParams('find[enteredBy][$nin][]=Trio&find[enteredBy][$nin][]=iAPS'));
  assert.deepEqual(Object.values(f.find.enteredBy.$nin), ['Trio', 'iAPS']);
});

await test('relayQuery keeps the query text byte for byte and removes only token', async () => {
  const raw = '?find[eventType]=Temporary+Target&find[duration][$exists]=true&find[$and][0][enteredBy][$ne]=openaps://AndroidAPS&find[created_at][$gt]=2026-10-14T00:00:00.000Z';
  assert.equal(relayQuery(raw), raw);
  assert.equal(relayQuery('?token=abc&count=1&a%5B%24b%5D=c%2Bd'), '?count=1&a%5B%24b%5D=c%2Bd');
  assert.equal(relayQuery('?token=abc'), '');
});

// Relay with a stand-in Nightscout (fetch replaced), so it runs without a network.
async function withFakeNs(handler, fn) {
  const real = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (u, init = {}) => {
    seen.push({ url: String(u), method: init.method || 'GET', body: init.body, headers: init.headers, redirect: init.redirect });
    return handler(String(u), init);
  };
  try {
    await fn(seen);
  } finally {
    globalThis.fetch = real;
  }
}
const nsResp = (body, status = 200) => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });

await test('relay: Trio GETs go to Nightscout with the exact query; status and body come back unchanged', async () => {
  const e = makeEnv({ NIGHTSCOUT_URL: 'https://ns.example', NIGHTSCOUT_SECRET: 'ns-secret-456789' });
  // Something in the local copy that must NOT be returned to Trio.
  await saveMany(e.DB, 'treatments', [{ eventType: 'Carb Correction', created_at: new Date().toISOString(), carbs: 99 }]);
  const nsBody = '[{"_id":"x1","eventType":"Temporary Target","duration":30}]';
  await withFakeNs(() => nsResp(nsBody), async (seen) => {
    const path = '/api/v1/treatments.json?find[eventType]=Temporary+Target&find[duration][$exists]=true&find[$and][0][enteredBy][$ne]=Trio';
    const r = await worker.fetch(new Request('https://glucose.example' + path, { headers: { 'api-secret': sha1(S) } }), e, { waitUntil() {} });
    assert.equal(await r.text(), nsBody);
    assert.equal(seen.length, 1);
    assert.equal(seen[0].url, 'https://ns.example' + path);
    assert.equal(seen[0].headers['api-secret'], sha1('ns-secret-456789'));
    assert.equal(seen[0].redirect, 'manual');
  });
  await withFakeNs(() => nsResp('{"status":401,"message":"Unauthorized"}', 401), async () => {
    const r = await worker.fetch(new Request('https://glucose.example/api/v1/treatments.json?find[carbs][$exists]=true', { headers: { 'api-secret': sha1(S) } }), e, { waitUntil() {} });
    assert.equal(r.status, 401);
    assert.equal(await r.text(), '{"status":401,"message":"Unauthorized"}');
  });
  await withFakeNs(() => new Response(null, { status: 204 }), async () => {
    const r = await worker.fetch(new Request('https://glucose.example/api/v1/treatments.json', { headers: { 'api-secret': sha1(S) } }), e, { waitUntil() {} });
    assert.equal(r.status, 204);
  });
});

await test('relay: Trio DELETE with a query and POST body reach Nightscout unchanged; copy follows', async () => {
  const e = makeEnv({ NIGHTSCOUT_URL: 'https://ns.example', NIGHTSCOUT_SECRET: 'none' });
  const body = '[{"eventType":"Carb Correction","created_at":"' + new Date().toISOString() + '","carbs":12,"id":"Z9","enteredBy":"Trio"}]';
  await withFakeNs((u, init) => (init.method === 'POST' ? nsResp([{ ...JSON.parse(init.body)[0], _id: '0123456789abcdef01234567' }]) : nsResp({ n: 1, ok: 1 })), async (seen) => {
    const waits = [];
    const ctx = { waitUntil: (p) => waits.push(p) };
    await worker.fetch(new Request('https://glucose.example/api/v1/treatments.json', { method: 'POST', headers: { 'api-secret': sha1(S), 'Content-Type': 'application/json' }, body }), e, ctx);
    await Promise.all(waits);
    assert.equal(seen[0].body, body);
    assert.equal(seen[0].headers['api-secret'], sha1(S)); // NIGHTSCOUT_SECRET "none" -> API_SECRET
    const del = '/api/v1/treatments.json?find[id][$eq]=Z9';
    await worker.fetch(new Request('https://glucose.example' + del, { method: 'DELETE', headers: { 'api-secret': sha1(S) } }), e, ctx);
    await Promise.all(waits);
    assert.equal(seen[1].url, 'https://ns.example' + del);
    assert.equal(seen[1].method, 'DELETE');
    const local = await call(e, 'GET', '/api/v1/treatments.json', { token: 'readable-abc' });
    assert.equal(local.data.length, 0);
  });
});

await test('relay: careportal carbs that fail to reach Nightscout are reported (502), not silently dropped', async () => {
  const e = makeEnv({ NIGHTSCOUT_URL: 'https://ns.example' });
  await withFakeNs(() => nsResp('{"message":"down"}', 503), async (seen) => {
    const r = await call(e, 'POST', '/api/v1/treatments', { token: 'care-xyz', body: { eventType: 'Carb Correction', carbs: 10 } });
    assert.equal(r.status, 502);
    assert.ok(!seen[0].url.includes('token='));
  });
  await withFakeNs(() => nsResp([{ _id: 'a' }]), async () => {
    assert.equal((await call(e, 'POST', '/api/v1/treatments', { token: 'care-xyz', body: { eventType: 'Note', notes: 'x' } })).status, 200);
  });
});

await test('copy: a 2-day backlog with full pages stays under the free-plan call limits', async () => {
  const e = makeEnv({ NIGHTSCOUT_URL: 'https://ns.example' });
  let d1 = 0;
  const prep = e.DB.prepare.bind(e.DB);
  e.DB.prepare = (sql) => (d1++, prep(sql));
  const t = Date.now();
  await withFakeNs((u) => {
    const url = new URL(u);
    const n = Number(url.searchParams.get('count') || 1);
    if (url.pathname.includes('profile')) return nsResp([{ startDate: new Date(t).toISOString(), store: {} }]);
    const from = toMsQ(url.searchParams.get('find[date][$gte]') || url.searchParams.get('find[created_at][$gte]'));
    // Always a full page: forces the smaller-window path.
    return nsResp(Array.from({ length: n }, (_, i) => ({ date: from + i * 1000, created_at: new Date(from + i * 1000).toISOString(), sgv: 100, type: 'sgv', eventType: 'Note' })));
  }, async (seen) => {
    await copyFromNightscout(e, t);
    assert.ok(seen.length + d1 <= 50, `fetch ${seen.length} + D1 ${d1}`);
  });
});
function toMsQ(v) {
  return /^\d+$/.test(v) ? Number(v) : Date.parse(v);
}

// ---------------------------------------------------------------- relay + copy (needs a fake Nightscout)
const NS = process.env.FAKE_NS_URL;
const NS_SECRET = process.env.FAKE_NS_SECRET;
if (NS && NS_SECRET) {
  const renv = makeEnv({ NIGHTSCOUT_URL: NS, NIGHTSCOUT_SECRET: NS_SECRET });
  const nsCall = async (path) => (await fetch(NS + path, { headers: { 'api-secret': sha1(NS_SECRET), Accept: 'application/json' } })).json();

  await test('relay: auth test is answered by Nightscout', async () => {
    assert.equal((await call(renv, 'GET', '/api/v1/experiments/test', { secret: S })).status, 200);
  });

  await test('relay: Loop upload reaches Nightscout and a copy is kept with the same _id', async () => {
    const t = Date.now();
    const r = await call(renv, 'POST', '/api/v1/entries', { secret: S, body: [{ date: t, sgv: 140, type: 'sgv', direction: 'FortyFiveUp' }] });
    assert.equal(r.status, 200);
    const id = r.data[0]._id;
    const inNs = await nsCall('/api/v1/entries/sgv.json?count=5');
    assert.ok(inNs.some((e) => e._id === id), 'not in Nightscout');
    const local = await call(renv, 'GET', '/api/v1/entries/sgv.json?count=5', { token: 'readable-abc' });
    assert.ok(local.data.some((e) => e._id === id), 'not in copy');
  });

  await test('relay: Trio reads come from Nightscout itself', async () => {
    const r = await call(renv, 'GET', '/api/v1/treatments.json?count=5', { secret: S });
    assert.equal(r.status, 200);
    assert.ok(Array.isArray(r.data));
  });

  await test('relay: delete by id is applied to both', async () => {
    const r = await call(renv, 'POST', '/api/v1/treatments', { secret: S, body: [{ eventType: 'Note', created_at: new Date().toISOString(), notes: 'relay' }] });
    const id = r.data[0]._id;
    await call(renv, 'DELETE', '/api/v1/treatments/' + id, { secret: S });
    const inNs = await nsCall('/api/v1/treatments.json?count=50');
    assert.ok(!inNs.some((e) => e._id === id));
    const local = await call(renv, 'GET', '/api/v1/treatments.json?count=50', { token: 'readable-abc' });
    assert.ok(!local.data.some((e) => e._id === id));
  });

  await test('relay: Nightscout down -> error to Loop (so it retries) but the copy keeps the data', async () => {
    const down = makeEnv({ NIGHTSCOUT_URL: 'http://127.0.0.1:9', NIGHTSCOUT_SECRET: NS_SECRET });
    const t = Date.now();
    const r = await call(down, 'POST', '/api/v1/entries', { secret: S, body: [{ date: t, sgv: 150, type: 'sgv' }] });
    assert.equal(r.status, 502);
    const local = await call(down, 'GET', '/api/v1/entries/sgv.json?count=5', { token: 'readable-abc' });
    assert.equal(local.data[0].sgv, 150);
  });

  await test('copy: pulls entries, treatments, device status and profile from Nightscout', async () => {
    const cenv = makeEnv({ NIGHTSCOUT_URL: NS, NIGHTSCOUT_SECRET: NS_SECRET });
    const done = await copyFromNightscout(cenv);
    assert.ok(done.entries >= 1, JSON.stringify(done));
    const local = await call(cenv, 'GET', '/api/v1/entries/sgv.json?count=5', { token: 'readable-abc' });
    assert.ok(local.data.length >= 1);
    // A second run does not create duplicates.
    await copyFromNightscout(cenv);
    const again = await call(cenv, 'GET', '/api/v1/entries/sgv.json?count=50', { token: 'readable-abc' });
    const ids = again.data.map((d) => d._id);
    assert.equal(new Set(ids).size, ids.length);
  });
} else {
  console.log('skip  relay/copy tests (set FAKE_NS_URL and FAKE_NS_SECRET)');
}

console.log(failures ? `\n${failures} test(s) failed` : '\nall tests passed');
process.exit(failures ? 1 : 0);
