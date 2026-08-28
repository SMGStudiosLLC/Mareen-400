/**
 * Relay guard - Cloud Function version.
 *
 * Truly instant (fires on the write itself, no polling) and permanent, because
 * it runs in your project rather than in a session container. Add to
 * firebase/functions/ and re-export from index.js:
 *
 *   const guard = require('./guardWatch');
 *   exports.guardOnMessage = guard.guardOnMessage;
 *   exports.guardOnFriendRequest = guard.guardOnFriendRequest;
 *   exports.guardOnSnap = guard.guardOnSnap;
 *
 * Snapshot index.js first, then:
 *   cd /Users/Toby/Desktop/Relay/firebase
 *   firebase deploy --only functions --project relaybytss
 */
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const admin = require('firebase-admin');

if (!admin.apps.length) admin.initializeApp();
const db = admin.firestore();

// Accounts under observation, and who each is allowed to talk to without a ping.
const WATCH = new Set(['jack', 'izzy_jackson_13']);
const FAMILY = new Set(['jack', 'izzy_jackson_13']);
const OWNER = 'tobywankenobi';
const BOT = 'claude';

// Spray signature: this many friend requests to non-family inside the window.
const SPRAY_COUNT = 6;
const SPRAY_WINDOW_MS = 15 * 60 * 1000;
const ARM_AUTOBAN = false; // flip to true to ban automatically on the signature

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
  /\b(snap(chat)?|insta(gram)?|telegram|whatsapp|kik|discord)\b/i,
  /https?:\/\//i,
];

async function dmOwner(text) {
  await db.collection('messages').add({
    sender: BOT,
    recipient: OWNER,
    message: text,
    type: 'text',
    participants: [BOT, OWNER],
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

async function isMinor(username) {
  const snap = await db.collection('users').doc(username).get();
  const bday = snap.exists ? snap.get('birthday') : null;
  if (!bday || !/^\d{4}-\d{2}-\d{2}$/.test(bday)) return null; // unknown
  const age = (Date.now() - Date.parse(bday)) / (365.25 * 24 * 3600 * 1000);
  return age < 18;
}

exports.guardOnMessage = onDocumentCreated('messages/{id}', async (event) => {
  const m = event.data?.data();
  if (!m) return;
  const who = WATCH.has(m.sender) ? m.sender : WATCH.has(m.recipient) ? m.recipient : null;
  if (!who) return;

  const other = m.sender === who ? m.recipient : m.sender;
  if (FAMILY.has(other)) return; // sibling chatter, expected

  const body = String(m.message || (m.imageUrl ? '[photo]' : ''));
  const flagged = SUSPICIOUS.some((re) => re.test(body));
  const minor = await isMinor(other);
  const level = flagged || minor ? 'HIGH' : 'REVIEW';

  await dmOwner(
    `[${level}] @${who} ${m.sender === who ? 'messaged' : 'was messaged by'} @${other}` +
    `${minor === true ? ' (a minor)' : ''}\n` +
    `${flagged ? 'Matched a solicitation/age-probe pattern.\n' : ''}` +
    `"${body.slice(0, 300)}"`
  );
});

exports.guardOnFriendRequest = onDocumentCreated('friendRequests/{id}', async (event) => {
  const fr = event.data?.data();
  if (!fr) return;
  const who = WATCH.has(fr.from) ? fr.from : WATCH.has(fr.to) ? fr.to : null;
  if (!who || FAMILY.has(fr.from === who ? fr.to : fr.from)) return;

  const other = fr.from === who ? fr.to : fr.from;
  const minor = await isMinor(other);
  await dmOwner(
    `[REVIEW] friend request ${fr.from === who ? `@${who} -> @${other}` : `@${other} -> @${who}`}` +
    `${minor === true ? ' (a minor)' : ''} | ${fr.status || 'pending'}`
  );

  if (fr.from !== who) return;

  // spray check: outbound requests to non-family in the recent window
  const cutoff = new Date(Date.now() - SPRAY_WINDOW_MS).toISOString();
  const recent = await db.collection('friendRequests')
    .where('from', '==', who).where('created', '>', cutoff).get();
  const n = recent.docs.filter((d) => !FAMILY.has(d.get('to'))).length;
  if (n < SPRAY_COUNT) return;

  const why = `${n} friend requests to non-family inside ${SPRAY_WINDOW_MS / 60000}m (spray signature)`;
  if (ARM_AUTOBAN) {
    await banUser(who, 'auto: ' + why);
    await dmOwner(`AUTO-BAN @${who}\n${why}\nUndo: set banned=false, active=true on users/${who}`);
  } else {
    await dmOwner(`[HIGH] @${who} tripped the spray signature\n${why}\nNot banned - auto-ban is disarmed.`);
  }
});

exports.guardOnSnap = onDocumentCreated('snaps/{id}', async (event) => {
  const s = event.data?.data();
  if (!s || !WATCH.has(s.username) || s.status !== 'posted') return;
  await dmOwner(
    `[FYI] @${s.username} posted a snap` +
    `${s.story ? ' to their journal' : ''}` +
    `${s.caption ? ` | "${String(s.caption).slice(0, 200)}"` : ''}`
  );
});
