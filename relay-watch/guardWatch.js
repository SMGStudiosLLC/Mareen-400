/**
 * Relay guard - Cloud Function version.
 *
 * Instant (fires on the write, no polling), permanent (runs in your project, not
 * in a session container), and free of any Claude usage - this is plain Node on
 * Firebase, there is no model in the loop.
 *
 * Install: copy into firebase/functions/, then in functions/index.js add
 *
 *   const guard = require('./guardWatch');
 *   exports.guardOnMessage = guard.guardOnMessage;
 *   exports.guardOnFriendRequest = guard.guardOnFriendRequest;
 *   exports.guardOnSnap = guard.guardOnSnap;
 *
 * Snapshot index.js first, then:
 *   cd /Users/Toby/Desktop/Relay/firebase
 *   firebase deploy --only functions:guardOnMessage,functions:guardOnFriendRequest,functions:guardOnSnap --project relaybytss
 *
 * ALL behaviour is driven by the Firestore doc config/guard, so you never need to
 * redeploy to change or kill it:
 *
 *   enabled  bool     master switch. false = every trigger no-ops immediately.
 *   until    string   ISO date. Past it, the guard no-ops. Auto-expiry.
 *   watch    string[] usernames under observation.
 *   family   string[] usernames that may talk to each other without a ping.
 *   autoBan  bool     act on the velocity signatures, or alert only.
 *   notify   string   who gets the DM.
 *
 * To turn the whole thing off: set config/guard.enabled = false. One field.
 */
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const admin = require('firebase-admin');

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

const BOT = 'claude';

// Velocity signatures. Both are volume based, not keyword based, because a
// keyword match is not safe grounds to ban somebody automatically - a teenager
// saying "add me on snap" would trip it. These two cannot happen innocently.
const SPRAY_REQUESTS = 6;  // friend requests to non-family ...
const SPRAY_DMS = 5;       // distinct non-family users DMed ...
const WINDOW_MS = 15 * 60 * 1000; // ... inside this window

const DEFAULTS = {
  enabled: true,
  until: null,
  watch: ['jack', 'izzy_jackson_13'],
  family: ['jack', 'izzy_jackson_13'],
  autoBan: true,
  notify: 'tobywankenobi',
};

// Content patterns escalate to a HIGH alert. They never auto-ban on their own.
const SUSPICIOUS = [
  /\bhow old (are|r) (you|u)\b/i,
  /\bwhat('?s| is) your age\b/i,
  /\bwhere (do|r) (you|u) live\b/i,
  /\byour address\b/i,
  /\bsend (me )?(a )?(pic|photo|nude|selfie)/i,
  /\bare (you|u) (real|alone|home)\b/i,
  /\bdon'?t tell\b/i,
  /\bour secret\b/i,
  /\b(cash ?app|venmo|zelle|paypal|bitcoin|btc|crypto|gift ?card|western union)\b/i,
  /\b(telegram|whatsapp|kik|discord)\b/i,
  /https?:\/\//i,
];

let cached = null;
let cachedAt = 0;

async function config() {
  if (cached && Date.now() - cachedAt < 60_000) return cached;
  let doc = {};
  try {
    const snap = await db.collection('config').doc('guard').get();
    if (snap.exists) doc = snap.data();
  } catch (e) {
    console.error('guard: config read failed, using defaults', e.message);
  }
  cached = { ...DEFAULTS, ...doc };
  cachedAt = Date.now();
  return cached;
}

// Returns the live config, or null when the guard should not run at all.
async function active() {
  const c = await config();
  if (!c.enabled) return null;
  if (c.until && Date.now() > Date.parse(c.until)) return null;
  return c;
}

async function dmOwner(cfg, text) {
  await db.collection('messages').add({
    sender: BOT,
    recipient: cfg.notify,
    message: text,
    type: 'text',
    participants: [BOT, cfg.notify],
    created: new Date().toISOString(),
    read: false,
  });
}

async function banUser(username, why) {
  await db.collection('users').doc(username).set({
    banned: true,
    active: false,
    bannedAt: new Date().toISOString(),
    bannedReason: why,
  }, { merge: true });
}

async function alreadyBanned(username) {
  const snap = await db.collection('users').doc(username).get();
  return snap.exists && snap.get('banned') === true;
}

// true / false / null when the birthday is missing or malformed
async function isMinor(username) {
  const snap = await db.collection('users').doc(username).get();
  const bday = snap.exists ? snap.get('birthday') : null;
  if (!bday || !/^\d{4}-\d{2}-\d{2}$/.test(bday)) return null;
  const years = (Date.now() - Date.parse(bday)) / (365.25 * 24 * 3600 * 1000);
  return years < 18;
}

async function enforce(cfg, who, why) {
  if (await alreadyBanned(who)) return;
  if (cfg.autoBan) {
    await banUser(who, 'auto: ' + why);
    await dmOwner(cfg, `AUTO-BAN @${who}\n${why}\n\nUndo: users/${who} banned=false active=true\nDisable the guard: config/guard enabled=false`);
  } else {
    await dmOwner(cfg, `[HIGH] @${who} tripped a ban signature\n${why}\nNot banned, autoBan is off in config/guard.`);
  }
}

exports.guardOnMessage = onDocumentCreated('messages/{id}', async (event) => {
  const cfg = await active();
  if (!cfg) return;
  const m = event.data && event.data.data();
  if (!m) return;

  const watch = new Set(cfg.watch);
  const family = new Set(cfg.family);
  const who = watch.has(m.sender) ? m.sender : watch.has(m.recipient) ? m.recipient : null;
  if (!who) return;

  const other = m.sender === who ? m.recipient : m.sender;
  if (family.has(other)) return; // sibling chatter, expected

  const body = String(m.message || (m.imageUrl ? '[photo]' : ''));
  const flagged = SUSPICIOUS.some((re) => re.test(body));
  const minor = await isMinor(other);

  await dmOwner(cfg,
    `[${flagged || minor ? 'HIGH' : 'REVIEW'}] @${who} ${m.sender === who ? 'messaged' : 'was messaged by'} @${other}` +
    `${minor === true ? ' (a minor)' : ''}\n` +
    `${flagged ? 'Matched a solicitation or age-probe pattern.\n' : ''}` +
    `"${body.slice(0, 300)}"`
  );

  if (m.sender !== who) return;

  // outbound DM fan-out: distinct non-family recipients in the window
  const cutoff = new Date(Date.now() - WINDOW_MS).toISOString();
  const recent = await db.collection('messages')
    .where('sender', '==', who).where('created', '>', cutoff).get();
  const targets = new Set(
    recent.docs.map((d) => d.get('recipient')).filter((r) => r && !family.has(r))
  );
  if (targets.size >= SPRAY_DMS) {
    await enforce(cfg, who, `DMed ${targets.size} different non-family users inside ${WINDOW_MS / 60000}m (fan-out signature)`);
  }
});

exports.guardOnFriendRequest = onDocumentCreated('friendRequests/{id}', async (event) => {
  const cfg = await active();
  if (!cfg) return;
  const fr = event.data && event.data.data();
  if (!fr) return;

  const watch = new Set(cfg.watch);
  const family = new Set(cfg.family);
  const who = watch.has(fr.from) ? fr.from : watch.has(fr.to) ? fr.to : null;
  if (!who) return;

  const other = fr.from === who ? fr.to : fr.from;
  if (family.has(other)) return;

  const minor = await isMinor(other);
  await dmOwner(cfg,
    `[REVIEW] friend request ${fr.from === who ? `@${who} -> @${other}` : `@${other} -> @${who}`}` +
    `${minor === true ? ' (a minor)' : ''} | ${fr.status || 'pending'}`
  );

  if (fr.from !== who) return;

  const cutoff = new Date(Date.now() - WINDOW_MS).toISOString();
  const recent = await db.collection('friendRequests')
    .where('from', '==', who).where('created', '>', cutoff).get();
  const n = recent.docs.filter((d) => !family.has(d.get('to'))).length;
  if (n >= SPRAY_REQUESTS) {
    await enforce(cfg, who, `${n} friend requests to non-family inside ${WINDOW_MS / 60000}m (spray signature)`);
  }
});

exports.guardOnSnap = onDocumentCreated('snaps/{id}', async (event) => {
  const cfg = await active();
  if (!cfg) return;
  const s = event.data && event.data.data();
  if (!s || !cfg.watch.includes(s.username) || s.status !== 'posted') return;

  await dmOwner(cfg,
    `[FYI] @${s.username} posted a snap` +
    `${s.story ? ' to their journal' : ''}` +
    `${s.caption ? ` | "${String(s.caption).slice(0, 200)}"` : ''}`
  );
});
