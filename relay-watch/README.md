# Relay guard

Watches `@jack` and `@izzy_jackson_13` and DMs `@tobywankenobi` from `@claude` the
moment either does anything. Writing the DM doc fires `onMessageCreated`, so it
lands as a real push.

## Claude usage: none

Neither version puts a model in the loop. `guardWatch.js` is plain Node on
Firebase; `watch.mjs` is plain Node hitting the Firestore REST API. No Opus, no
Haiku, no tokens, no API key. Running this costs Firestore reads and function
invocations, which at two watched users is effectively nothing.

The only thing that would burn Claude usage is waking a Claude session on a
schedule, which this deliberately does not do.

## Two versions

**`guardWatch.js`** - the one to run. Cloud Function triggers: instant, permanent,
survives everything. Needs one deploy from your Mac.

**`watch.mjs`** - polling fallback, no credentials needed. Runs anywhere with Node.
**Dies when its host process dies**, so it is only useful on a machine you keep up.

```
node watch.mjs          # poll every 45s
node watch.mjs --once   # single pass, for cron
```

State lives in `state.json`, activity in `watch.log`. Delete `state.json` to
re-baseline without re-alerting on history.

## Deploy

Copy `guardWatch.js` into `firebase/functions/`, then add to `functions/index.js`:

```js
const guard = require('./guardWatch');
exports.guardOnMessage = guard.guardOnMessage;
exports.guardOnFriendRequest = guard.guardOnFriendRequest;
exports.guardOnSnap = guard.guardOnSnap;
```

Snapshot first, then deploy just the three new functions:

```
cp firebase/functions/index.js firebase/functions/.backups/index.$(date -u +%Y-%m-%dT%H%M%SZ).js
cd /Users/Toby/Desktop/Relay/firebase
firebase deploy --only functions:guardOnMessage,functions:guardOnFriendRequest,functions:guardOnSnap --project relaybytss
```

## Control: config/guard

Every knob lives in the Firestore doc `config/guard`, read fresh on each trigger
and cached 60s. **Nothing here needs a redeploy.**

| Field | Meaning |
|---|---|
| `enabled` | master switch. `false` and every trigger no-ops on the first line |
| `until` | ISO date. Past it the guard stops on its own |
| `watch` | usernames under observation |
| `family` | usernames that may talk to each other without a ping |
| `autoBan` | act on the velocity signatures, or alert only |
| `notify` | who gets the DM |

Create it (also sets a 30 day auto-expiry, so it winds itself down):

```
curl -X PATCH "https://firestore.googleapis.com/v1/projects/relaybytss/databases/(default)/documents/config/guard" \
  -H "Content-Type: application/json" -d '{"fields":{
    "enabled":{"booleanValue":true},
    "autoBan":{"booleanValue":true},
    "until":{"stringValue":"2026-09-27T00:00:00.000Z"},
    "notify":{"stringValue":"tobywankenobi"},
    "watch":{"arrayValue":{"values":[{"stringValue":"jack"},{"stringValue":"izzy_jackson_13"}]}},
    "family":{"arrayValue":{"values":[{"stringValue":"jack"},{"stringValue":"izzy_jackson_13"}]}}
  }}'
```

**Turn it off:** set `enabled` to `false`. One field, takes effect within a minute.

**Wind it down instead of off:** set `autoBan` to `false` to keep the alerts but
stop it acting, or push `until` out to extend. Watching a new account is just
appending a username to `watch`.

## What it does

| Level | Trigger | Action |
|---|---|---|
| BAN | 6+ friend requests to non-family in 15 min | ban + DM (if `autoBan`) |
| BAN | DMs to 5+ distinct non-family users in 15 min | ban + DM (if `autoBan`) |
| HIGH | DM to/from a non-family user matching a solicitation or age-probe pattern, or any DM with a minor | DM you |
| REVIEW | any friend request or DM outside the sibling pair | DM you |
| FYI | posted snap | DM you |
| - | sibling-to-sibling chat, app opens, own posts | ignored |

Sibling traffic is deliberately silent. These two are each other's only connection,
so alerting on it would be noise you would learn to ignore.

### Why the ban triggers are velocity, not keywords

Both auto-ban signatures count behaviour over time. Neither reads content. A
keyword rule is not safe grounds for an unattended ban - a teenager typing "add me
on snap" would trip one, and the account is a minor's. The velocity signatures
cannot happen innocently: normal users add one to three people they know, and
`mary_` sent 17 friend requests in nine minutes, 14 of them inside a single
31-second window, straight down the user directory in alphabetical order.

Content matches still reach you immediately as HIGH. They just do not ban on their
own.

### Ban mechanics

A ban sets `banned=true, active=false, bannedAt, bannedReason` on `users/{username}`.
Undo is the same fields inverted. Note that this stops the client but not a
determined user, since the doc is world-writable - a rules question, not a guard
question.
