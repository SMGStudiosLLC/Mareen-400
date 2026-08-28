// Relay guard: watches the Jackson sibling accounts and DMs @tobywankenobi from
// @claude on any activity. Alert-only by default; see ARM_AUTOBAN.
//
//   node watch.mjs           run forever, polling every 45s
//   node watch.mjs --once    single pass (for cron)
//
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const BASE = 'https://firestore.googleapis.com/v1/projects/relaybytss/databases/(default)/documents';
const DIR = path.dirname(fileURLToPath(import.meta.url));
const STATE = path.join(DIR, 'state.json');
const LOG = path.join(DIR, 'watch.log');

const WATCH = ['jack', 'izzy_jackson_13']; // accounts under observation
const FAMILY = new Set(WATCH);             // traffic between these two is expected
const OWNER = 'tobywankenobi';
const BOT = 'claude';

const POLL_MS = 45_000;
const LOW_DIGEST_MS = 30 * 60_000;     // batch quiet activity into a half-hourly digest
const SPRAY_COUNT = 6;                 // non-family friend requests ...
const SPRAY_WINDOW_MS = 15 * 60_000;   // ... inside this window = the mary_ signature
const ARM_AUTOBAN = false;             // true = ban on the spray signature without asking

const SUSPICIOUS = [
  /\bhow old (are|r) (you|u)\b/i, /\bwhat('?s| is) your age\b/i,
  /\bwhere (do|r) (you|u) live\b/i, /\byour address\b/i,
  /\bsend (me )?(a )?(pic|photo|nude|selfie)/i,
  /\bare (you|u) (real|alone|home)\b/i, /\bdon'?t tell\b/i, /\bour secret\b/i,
  /\b(cash ?app|venmo|zelle|paypal|bitcoin|btc|crypto|gift ?card|western union)\b/i,
  /\b(snap(chat)?|insta(gram)?|telegram|whatsapp|kik|discord)\b/i,
  /https?:\/\//i,
];

const dec = v => {
  if (v == null) return null;
  const k = Object.keys(v)[0];
  if (k === 'integerValue' || k === 'doubleValue') return Number(v[k]);
  if (k === 'arrayValue') return (v[k].values || []).map(dec);
  if (k === 'mapValue') return decF(v[k].fields || {});
  if (k === 'nullValue') return null;
  return v[k];
};
const decF = f => Object.fromEntries(Object.entries(f || {}).map(([k, v]) => [k, dec(v)]));
const decDoc = d => (d ? { __id: d.name.split('/').pop(), ...decF(d.fields) } : null);

const log = m => {
  const line = `[${new Date().toISOString()}] ${m}`;
  console.log(line);
  try { fs.appendFileSync(LOG, line + '\n'); } catch {}
};

async function query(body) {
  const r = await fetch(`${BASE}:runQuery`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return (Array.isArray(j) ? j : []).filter(x => x.document).map(x => decDoc(x.document));
}

async function getDoc(p) {
  const r = await fetch(`${BASE}/${p}`);
  const j = await r.json();
  return j.error ? null : decDoc(j);
}

// docs in `collection` where `field` is one of WATCH and created > sinceIso
async function since(collection, field, sinceIso) {
  const out = [];
  for (const u of WATCH) {
    out.push(...await query({
      structuredQuery: {
        from: [{ collectionId: collection }],
        where: { compositeFilter: { op: 'AND', filters: [
          { fieldFilter: { field: { fieldPath: field }, op: 'EQUAL', value: { stringValue: u } } },
          { fieldFilter: { field: { fieldPath: 'created' }, op: 'GREATER_THAN', value: { stringValue: sinceIso } } },
        ] } },
        orderBy: [{ field: { fieldPath: 'created' }, direction: 'ASCENDING' }],
        limit: 50,
      },
    }));
  }
  return out;
}

const freshState = () => ({
  cursor: new Date().toISOString(), seen: [], lastSeenAt: {}, sigs: {},
  pendingLow: [], lastDigestAt: 0, reqLog: [], banned: [],
});
const loadState = () => { try { return { ...freshState(), ...JSON.parse(fs.readFileSync(STATE, 'utf8')) }; } catch { return freshState(); } };
const saveState = s => fs.writeFileSync(STATE, JSON.stringify(s, null, 1));

async function dm(text) {
  const body = { fields: {
    sender: { stringValue: BOT },
    recipient: { stringValue: OWNER },
    message: { stringValue: text },
    type: { stringValue: 'text' },
    participants: { arrayValue: { values: [{ stringValue: BOT }, { stringValue: OWNER }] } },
    created: { stringValue: new Date().toISOString() },
    read: { booleanValue: false },
  } };
  const r = await fetch(`${BASE}/messages`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const j = await r.json();
  if (j.error) { log('DM FAILED: ' + j.error.message); return false; }
  log('DM sent -> ' + text.split('\n')[0].slice(0, 90));
  return true;
}

export async function ban(username, why) {
  const fields = ['banned', 'active', 'bannedAt', 'bannedReason'];
  const qs = fields.map(f => `updateMask.fieldPaths=${f}`).join('&');
  const body = { fields: {
    banned: { booleanValue: true },
    active: { booleanValue: false },
    bannedAt: { stringValue: new Date().toISOString() },
    bannedReason: { stringValue: why },
  } };
  const r = await fetch(`${BASE}/users/${username}?${qs}`, {
    method: 'PATCH', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  const j = await r.json();
  if (j.error) { log(`BAN FAILED ${username}: ${j.error.message}`); return false; }
  log(`BANNED ${username}: ${why}`);
  return true;
}

function classify(ev) {
  if (ev.kind === 'message' && !FAMILY.has(ev.other)) {
    return SUSPICIOUS.some(re => re.test(ev.text || '')) ? 'HIGH' : 'MEDIUM';
  }
  if (ev.kind === 'friendRequest' && !FAMILY.has(ev.other)) return 'MEDIUM';
  if (ev.kind === 'profile' && /https?:\/\/|@\w|\d{7}/.test(ev.text || '')) return 'MEDIUM';
  return 'LOW';
}

const fmt = e => `- ${e.kind}: @${e.who} ${e.dir || ''} ${e.other !== '-' ? '@' + e.other : ''}`
  .replace(/\s+/g, ' ').trim() + (e.text ? ` | ${String(e.text).slice(0, 140)}` : '');

async function tick() {
  const s = loadState();
  const cursor = s.cursor;
  const seen = new Set(s.seen);
  const events = [];

  for (const [coll, field] of [
    ['messages', 'sender'], ['messages', 'recipient'],
    ['friendRequests', 'from'], ['friendRequests', 'to'],
    ['snaps', 'username'],
  ]) {
    let docs = [];
    try { docs = await since(coll, field, cursor); }
    catch (e) { log(`${coll}.${field}: ${e.message}`); continue; }

    for (const d of docs) {
      const key = `${coll}:${d.__id}`;
      if (seen.has(key)) continue;
      seen.add(key);

      if (coll === 'messages') {
        const who = WATCH.includes(d.sender) ? d.sender : d.recipient;
        const other = d.sender === who ? d.recipient : d.sender;
        events.push({ kind: 'message', who, other, dir: d.sender === who ? '->' : '<-',
          text: d.message || (d.imageUrl ? '[photo]' : ''), created: d.created });
      } else if (coll === 'friendRequests') {
        const who = WATCH.includes(d.from) ? d.from : d.to;
        const other = d.from === who ? d.to : d.from;
        events.push({ kind: 'friendRequest', who, other, dir: d.from === who ? '->' : '<-',
          text: d.status, created: d.created });
        if (d.from === who && !FAMILY.has(other)) {
          s.reqLog.push({ who, t: Date.parse(d.created) || Date.now() });
        }
      } else {
        events.push({ kind: 'snap', who: d.username, other: '-',
          text: `${d.status} story=${d.story} caption=${JSON.stringify(d.caption || '')}`, created: d.created });
      }
    }
  }

  for (const u of WATCH) {
    const doc = await getDoc(`users/${u}`);
    if (!doc) continue;
    if (doc.banned && !s.banned.includes(u)) s.banned.push(u);

    const prev = s.lastSeenAt[u];
    if (doc.lastSeen && doc.lastSeen !== prev) {
      s.lastSeenAt[u] = doc.lastSeen;
      if (prev) events.push({ kind: 'presence', who: u, other: '-', text: 'opened the app', created: doc.lastSeen });
    }

    const sig = JSON.stringify([doc.bio, doc.displayName, doc.profilePic, doc.birthday, doc.phone]);
    if (s.sigs[u] && s.sigs[u] !== sig) {
      events.push({ kind: 'profile', who: u, other: '-',
        text: `bio=${JSON.stringify(doc.bio || '')} name=${doc.displayName} bday=${doc.birthday}`,
        created: new Date().toISOString() });
    }
    s.sigs[u] = sig;
  }

  // spray signature (the pattern mary_ used)
  const now = Date.now();
  s.reqLog = s.reqLog.filter(r => now - r.t < SPRAY_WINDOW_MS);
  for (const u of WATCH) {
    const n = s.reqLog.filter(r => r.who === u).length;
    if (n < SPRAY_COUNT || s.banned.includes(u)) continue;
    const why = `${n} friend requests to non-family inside ${SPRAY_WINDOW_MS / 60000}m (spray signature)`;
    if (ARM_AUTOBAN) {
      if (await ban(u, 'auto: ' + why)) {
        s.banned.push(u);
        await dm(`AUTO-BAN @${u}\n${why}\nUndo: set banned=false, active=true on users/${u}`);
      }
    } else {
      await dm(`[HIGH] @${u} tripped the spray signature\n${why}\nNot banned (auto-ban disarmed). Say the word.`);
    }
  }

  const hi = events.filter(e => classify(e) !== 'LOW');
  const lo = events.filter(e => classify(e) === 'LOW');

  if (hi.length) {
    const worst = hi.some(e => classify(e) === 'HIGH') ? 'HIGH' : 'REVIEW';
    await dm(`[${worst}] Jackson watch\n${hi.map(fmt).join('\n')}`);
  }
  if (lo.length) s.pendingLow.push(...lo.map(fmt));
  if (s.pendingLow.length && now - s.lastDigestAt > LOW_DIGEST_MS) {
    await dm(`Jackson watch digest\n${s.pendingLow.slice(0, 25).join('\n')}`);
    s.pendingLow = [];
    s.lastDigestAt = now;
  }

  s.cursor = new Date().toISOString();
  s.seen = [...seen].slice(-4000);
  saveState(s);
  if (events.length) log(`${events.length} event(s): ${hi.length} escalated, ${lo.length} queued`);
}

log(`watcher start (poll ${POLL_MS / 1000}s, autoban ${ARM_AUTOBAN ? 'ARMED' : 'off'}, watching ${WATCH.join(', ')})`);
await tick();
if (!process.argv.includes('--once')) {
  setInterval(() => tick().catch(e => log('tick error: ' + e.message)), POLL_MS);
}
