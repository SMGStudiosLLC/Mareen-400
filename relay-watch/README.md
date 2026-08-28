# Relay guard

Watches `@jack` and `@izzy_jackson_13` and DMs `@tobywankenobi` from `@claude` when
either does anything. Writing the DM doc fires `onMessageCreated`, so it lands as a
real push.

## Two versions

**`guardWatch.js`** - the one you actually want. Cloud Function triggers, so it is
instant (fires on the write, no polling) and permanent. Drop into `firebase/functions/`,
re-export from `index.js`, deploy. See the header comment for the exact lines.

**`watch.mjs`** - polling fallback, runs anywhere with Node and no credentials.
Useful for a laptop or a box you control. Dies when its host does.

```
node watch.mjs          # poll every 45s
node watch.mjs --once   # single pass, for cron
```

State lives in `state.json`, activity in `watch.log`. Delete `state.json` to
re-baseline (it will not re-alert on history).

## What it escalates

| Level | Trigger | Delivery |
|---|---|---|
| HIGH | message to/from a non-family user matching a solicitation or age-probe pattern, or any DM with a minor | immediate |
| REVIEW | any friend request or DM with someone outside the sibling pair | immediate |
| FYI | posted snap | immediate (function) / digest (poller) |
| LOW | sibling-to-sibling chat, app opens, own posts | 30-minute digest |

Sibling-to-sibling traffic is deliberately quiet. These two are each other's only
connection, so alerting on it would be pure noise.

## Auto-ban

`ARM_AUTOBAN` is **false** in both files. The bright line, when armed, is the
signature `mary_` used on 2026-08-14: six or more friend requests to non-family
inside fifteen minutes. That pattern is essentially impossible for a normal user
(they add one to three people they know) and was the exact shape of the only real
attack this app has seen.

It is disarmed by default on purpose. Both accounts are near-certainly minors, an
unsupervised script banning a teenager on a regex is a bad failure mode, and an
alert gets you there within seconds anyway. Flip it to `true` in either file if you
want it to act without you.

Manual ban, any time:

```
PATCH users/{username}?updateMask.fieldPaths=banned&updateMask.fieldPaths=active
{ "fields": { "banned": {"booleanValue": true}, "active": {"booleanValue": false} } }
```

Note that a ban is only a field on a world-writable document, so it stops the
client but not a determined user. That is a rules problem, not a guard problem.

## Tuning

Edit the constants at the top of either file: `WATCH`, `FAMILY`, `SPRAY_COUNT`,
`SPRAY_WINDOW_MS`, `SUSPICIOUS`, `POLL_MS`, `LOW_DIGEST_MS`. Adding an account to
`WATCH` is enough to start watching it.
