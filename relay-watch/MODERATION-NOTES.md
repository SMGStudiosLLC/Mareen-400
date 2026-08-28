# Relay moderation notes

Written 2026-08-28 while assessing the first cohort of users nobody at TSS knows
personally. Read this before flagging a new account.

No user identities, ages, locations or contact details are recorded here on
purpose. Everything below is reproducible from Firestore when you actually need
it; a roster of minors does not belong in a git remote.

## The vouching rule

**An account connected by real-world phone contacts to an account already
verified authentic is presumptively authentic too.**

Nobody discovers an app, joins, and then invites a scammer into it. Abuse arrives
alone, because abuse has no real social graph to arrive with. Once one member of a
cluster is verified, the burden of proof flips for everyone reachable from them
through mutual contacts.

This is not a shortcut. It is the strongest signal available, and it is what
separated a benign cluster from a real attack on this platform.

## The two worked cases

**The false positive.** An account stating 25 friend-requested a 13 year old two
and a half minutes after she created her account. On its face, the worst-looking
row a platform with minors can produce. It was a brother and a family friend.

Only the contact graph could show that: dozens of shared numbers with matching
family semantics on both sides, each saved in the other's phone under a family
nickname, the younger user's line saved in his phone under her mother's name,
separate physical devices, no shared idfv, no reinstalls. His avatar was a high
school formal photo and he read about 17. The stated 25 was teenage age-gate
fiction, not a predator's cover.

**The true positive.** 17 friend requests in 9 minutes, 14 of them inside a single
31 second window, fired in alphabetical order down the user directory and hitting
eight minors. Scripted opener, repeated age probing, steering toward a benefits
scam. And **no contact upload at all.** No social graph. Nobody held her number.
Nobody vouched for her because there was nobody to.

That last line is the tell. Every genuine cluster member so far arrives already
embedded in somebody's address book.

## Applying it

Presumptively fine when any of these hold:

1. The account's number appears in an already-verified user's contacts.
2. The account's own contact upload contains a verified user's number.
3. It shares meaningful contact overlap with a verified cluster.

Real scrutiny is earned by having none of the above **and** showing behavioural
signals: outbound request or DM spray, age probing, solicitation keywords,
payment app mentions, external links.

Absence of connection alone is never grounds for action. Two verified users so far
signed up with an empty `knownBy`. Empty `knownBy` only means nobody already on
Relay held their number, which is automatic for whoever arrives first in a
cluster. It is not evidence of anything.

## Standing gotchas

- Self-declared birthdays are unreliable **in both directions**. Teenagers inflate
  them to clear age gates. A stated age is never evidence on its own.
- The contact graph is the safety instrument, not a liability. Removing it would
  remove the only means of resolving the false-positive case above.
- Many minors register on a parent's phone line, so phone-based identity points at
  the parent, not the child. Do not assume the number reaches the user.
- Signups arrive in clusters, not independently (measured variance-to-mean ratio
  around 3). Assess the cluster, not the account.
- Image review happens only on the owner's instruction, under the moderation
  clause of the privacy policy, and reports flags only. Do not describe minors,
  and do not fetch a user's photos to satisfy curiosity.
