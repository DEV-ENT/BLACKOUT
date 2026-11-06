# DarkProof wire format (v0.4, marker byte 0xB2)

The Android and iPhone apps must produce and accept exactly these bytes.
`test-vectors.txt` holds byte-exact examples; both apps' unit tests check against it.
The app was called Blackout before. Protocol constants such as `blackout-mesh-v1`, `blackout-public`, `blackout-mesh` and `it.blackout.mesh.v1` keep that name on purpose: changing them would break every existing group and device.

## Packet

All integers are big-endian.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | marker | `0xB2`. Anything else is dropped. |
| 1 | 8 | id | Random. Written as 16 lowercase hex chars wherever it is used as text. |
| 9 | 8 | ts | Sender's clock, milliseconds since 1970-01-01 UTC, signed 64-bit. |
| 17 | 1 | ttl | Hops left, 0–64. Packets with ttl > 64 are dropped. |
| 18 | n | cipher | 1–16000 bytes. See below. |

Relays read only id, ts and ttl.

## Encryption

- **Key:** PBKDF2-HMAC-SHA256, 120000 iterations, 32-byte output.
  - Password: the group code, NFC-normalized, as UTF-8 bytes.
  - Salt: the ASCII bytes of `blackout-mesh-v1`.
- **Cipher:** AES-256-GCM with a 12-byte random IV and a 16-byte tag.
  - Associated data: the UTF-8 bytes of `<id hex>|<ts decimal>`, for example `0123456789abcdef|1793807238631`.
  - `cipher` = IV (12) ‖ ciphertext ‖ tag (16).
- **Plaintext:** three text fields in this order:
  1. `sender`: the device id.
  2. `name`: the display name.
  3. `text`: the message.
- **Text field:** a 2-byte length followed by that many bytes of standard UTF-8. Do not use Java's modified UTF-8.
- Readers ignore bytes after the third field, which leaves room for future fields.

A packet that fails to decrypt is still stored and forwarded. It just isn't shown.

## Groups and the Public channel

- **Every DarkProof device relays for every other.** Devices connect to any DarkProof device they find, whatever its group, and forward all packets. A group exists only through its code: only members can decrypt its messages.
- **Public channel:** messages sealed with the code `blackout-public`, which everyone knows. Anyone can read and post them, including people without the app through the Wi-Fi board (Android). Apps show them marked as public.
- **Reading:** a device tries its own group's key first, then the public key, then the keys of the other groups saved
  on it (each derived once, in the background). A packet that opens with none is relayed but not shown. Messages of
  every saved group are kept, confirmed (with that group's receipt key) and alerted, not only the group on screen.

## Invites

An invite link carries a group's name and code so nobody has to type the code:

```
darkproof://join?name=<group name>&code=<group code>
```

- Both values are URL-encoded query items. `code` has at least 8 characters. `name` is only a label shown on screen; it is not used for encryption, and a missing name means "Group".
- Apps show the link as a QR code and can send it any way the phone can share a link, such as AirDrop.
- New groups get a random code of 16 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, in four groups of four joined by `-` (80 bits of entropy).
- Anyone with the link can read the group, exactly like anyone who knows the code.

### Web links

The same invite as a web address, so it also works for people who don't have the app yet:

```
https://darkproof.app/join#name=<group name>&code=<group code>
```

- After `#` come the same items as in the `darkproof://` link, encoded the same way: every byte that is not a letter,
  digit, `-`, `.`, `_` or `~` is written `%XX` (so a space is `%20` and `+` is `%2B`). Both apps write exactly these
  bytes; see `kind: invite` in `test-vectors.txt`.
- The code is in the fragment (after `#`), which browsers never send to a server: darkproof.app never sees it.
- Apps read both forms. They also accept `http://`, `www.darkproof.app`, any case in the scheme, host and path, the
  paths `/join/` and `/join.html`, and a query (such as `?utm_source=…`) before the `#`. A link with the code in the
  query instead of the fragment is not an invite.
- When `name` or `code` appears twice, the first one counts.
- Where DarkProof is installed and the phone has verified darkproof.app (Universal Links on the iPhone, App Links on
  Android), the link opens the app. Elsewhere it opens darkproof.app/join, which reads the fragment in the browser only
  and offers "Open in DarkProof" (the `darkproof://` link, so older apps work too) and the downloads.

### Typed codes

When someone types or pastes a group code to join, apps clean it up first, so a code read aloud or copied by hand still
reaches the same group:

1. If the input (trimmed) is an invite link of either form, its code is used exactly as the link carries it.
2. Otherwise apps remove spaces, tabs, line breaks, `-`, `_`, the no-break space and the dashes U+2010–U+2015 and
   U+2212, and turn ASCII `a`–`z` into upper case. If that leaves exactly 16 characters, all from the generated-code
   alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, the code is those 16 in four groups of four joined by `-`, for example
   `k7qf 2m9x pa4t w8rj` → `K7QF-2M9X-PA4T-W8RJ`.
3. Anything else is a custom code: only leading and trailing white space is removed, and everything else is kept as
   typed (case, spaces, dashes).

- Only new input is cleaned. Saved groups keep the code they were created with, because a custom code that happens to
  look like a generated one would otherwise change group.
- A code is in the generated form when it matches `^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$` (80 bits). Apps warn
  that other codes, especially short ones, can be guessed.
- Vectors: `kind: code-normalize`.

## Group fingerprint

Five emoji that two people read out to each other to check that their phones are in the same group. A fake invite QR
code, or a code typed with a mistake, gives different emoji.

- Take HMAC-SHA256 with the group key (see "Encryption") as the key and the ASCII bytes of `darkproof-fingerprint-v1`
  as the message. Read its first 4 bytes as a big-endian 32-bit number; its 30 highest bits, 6 bits at a time from the
  top, are five indices from 0 to 63.
- Index → emoji and English name, from Matrix's SAS emoji list (matrix-org/matrix-spec,
  `data-definitions/sas-emoji.json`, Apache License 2.0), in its order: 🐶 Dog, 🐱 Cat, 🦁 Lion, 🐎 Horse, 🦄 Unicorn,
  🐷 Pig, 🐘 Elephant, 🐰 Rabbit, 🐼 Panda, 🐓 Rooster, 🐧 Penguin, 🐢 Turtle, 🐟 Fish, 🐙 Octopus, 🦋 Butterfly,
  🌷 Flower, 🌳 Tree, 🌵 Cactus, 🍄 Mushroom, 🌏 Globe, 🌙 Moon, ☁️ Cloud, 🔥 Fire, 🍌 Banana, 🍎 Apple, 🍓 Strawberry,
  🌽 Corn, 🍕 Pizza, 🎂 Cake, ❤️ Heart, 😀 Smiley, 🤖 Robot, 🎩 Hat, 👓 Glasses, 🔧 Spanner, 🎅 Santa, 👍 Thumbs Up,
  ☂️ Umbrella, ⌛ Hourglass, ⏰ Clock, 🎁 Gift, 💡 Light Bulb, 📕 Book, ✏️ Pencil, 📎 Paperclip, ✂️ Scissors, 🔒 Lock,
  🔑 Key, 🔨 Hammer, ☎️ Telephone, 🏁 Flag, 🚂 Train, 🚲 Bicycle, ✈️ Aeroplane, 🚀 Rocket, 🏆 Trophy, ⚽ Ball, 🎸 Guitar,
  🎺 Trumpet, 🔔 Bell, ⚓ Anchor, 🎧 Headphones, 📁 Folder, 📌 Pin. The exact code points (some with U+FE0F) are in
  `kind: fingerprint-list`.
- Apps show the emoji separated by spaces and the names separated by `, `.
- Test values: `test-group-1` → HMAC `01e2302862d37bb6…`, indices 0 30 8 48 10, 🐶 😀 🐼 🔨 🐧 (Dog, Smiley, Panda,
  Hammer, Penguin). The Public channel → 49 59 19 20 36, ☎️ 🔔 🌏 🌙 👍.
- 30 bits are enough for comparing by voice: someone who wants a fake group with the same emoji has to try about
  a billion codes, each costing a PBKDF2 run. They don't protect a short custom code, which can be guessed directly.
- Nothing is sent: each phone computes the fingerprint from its own key.

## Check-ins

A check-in is an ordinary group message, so apps that don't know check-ins still show it as text:

- `✅ I'm safe` means safe. Any message whose text starts with `✅` counts as "safe".
- `🆘 I need help` means needs help. Any message whose text starts with `🆘` counts as "needs help".

A check-in may end with ` · 🔋 NN%`: the sender's battery level (0 to 100) when they sent it, for example
`✅ I'm safe · 🔋 23%`. Apps read the last `🔋 ` in a check-in, followed by 1 to 3 ASCII digits and `%`; anything
else means no battery level. Apps that don't know it just show the text.

A check-in may also end with ` · 📍 LAT,LON` and optionally ` ±Nm`: where the sender was, in decimal degrees (WGS 84,
5 decimals, `.` as the decimal point, `-` for south and west), and the radius in meters their phone was sure of, for
example `✅ I'm safe · 🔋 23% · 📍 45.46420,9.19000 ±12m`. Apps read the last `📍 ` in a check-in; a latitude outside
-90..90 or a longitude outside -180..180 means no position. A phone adds it only if its user turned on location
sharing.

A person's status is their most recent check-in, and so is their battery level. Their position is the one in their
most recent check-in that carried a position.

### Needs and head count

A "needs help" check-in may say what is needed, and a check-in of either kind how many people it speaks for:

```
🆘 I need help: injured, water · 👥 3 · 🔋 23% · 📍 45.46420,9.19000 ±12m
✅ I'm safe · 👥 4
```

- **Needs:** `🆘 I need help: ` followed by words from this list, in this order, separated by `, `: `injured`,
  `trapped`, `water`, `food`, `medicine`, `shelter`. Apps show them as Injured, Trapped, Need water, Need food,
  Need medicine, Need shelter. Readers take the part up to the first ` · `, compare words without regard to case and
  skip words they don't know, so newer apps can add needs.
- **Head count:** ` · 👥 N`, N from 1 to 99, after the needs and before the battery level. Readers take the last `👥 `
  followed by 1 or 2 ASCII digits and then a space or the end; anything else means no count.
- A person's needs and head count come from their most recent check-in, like the battery level.
- Apps that don't know them still read the status, battery and position (vectors: `kind: checkin`).
- Size: on MeshCore (packets ≤ 163 bytes) the name and the text together have 99 bytes (with a 12-character device
  id); on Meshtastic (≤ 233 bytes), 169. The first example above is 85 bytes of text, so it fits MeshCore with a name
  of up to 14 bytes. The longest possible check-in (all six needs, 👥 99, battery, position and accuracy) is 128 bytes:
  it still fits Meshtastic, but not MeshCore, and then travels on the other links only.

## Reports about others

Anyone can check in for someone who has no phone or no signal, for example a grandmother they found at the shelter:

```
👤 Grandma is safe
👤 Grandma Rosa needs help: injured, medicine · 👥 2 · 📍 45.46420,9.19000
```

- `👤 `, the person's name, then ` is safe` or ` needs help`. A "needs help" report may list needs like a check-in
  (`: injured, medicine`); either kind may add ` · 👥 N` and ` · 📍 …` (where that person is). There is no battery level.
- The name is one line, at most 24 characters, without `·`. Readers take the part up to the first ` · `; it ends with
  ` is safe`, or contains a last ` needs help` followed by nothing or `: ` and needs. Anything else is not a report.
- The reporter is the message's sender. The text does not repeat it.
- A report does not start with `✅` or `🆘`, so no app, old or new, takes it for the sender's own check-in. Older apps show
  it as text.
- **People list:** reports are kept by name: the name with runs of white space made one space, trimmed and in lower
  case. The latest report for a name wins (its status, needs and count); its position stays until a newer report has
  one. Reports sent by this phone count too. Apps show such an entry as that person's status "reported by" the sender,
  never as the person's own check-in. When a group member whose current name has the same key has their own check-in
  at least as new as the latest report, the report is not shown.
- Vectors: `kind: vouch`.

## "Are you safe?"

A group message that asks everyone, or one person, to check in:

```
❓ Is everyone safe?
❓ Marco, are you safe?
```

- The name is one line, at most 24 characters, without `·`. A message is a request only if it is exactly one of these
  two forms.
- It is for everyone, or for the members whose name has the same key as in "Reports about others". Apps offer them
  one-tap answers, which are ordinary check-ins (`✅ I'm safe`, `🆘 I need help`).
- Vectors: `kind: ask`.

## Photos

A group message can carry one small photo in a **4th plaintext field**, which older readers skip (see "Encryption":
readers ignore bytes after the third field):

- The field has the same 2-byte length prefix. Its first byte is the type, `0x01` = JPEG, followed by the JPEG bytes.
- At most 14000 JPEG bytes, so the packet stays under the 16000-byte cipher limit. Apps shrink photos to fit
  (a few hundred pixels wide) before sending.
- The 3rd field (`text`) is `📷 Photo`, or `📷 ` followed by a caption, so apps that don't know photos show that.
- Readers ignore a 4th field with another type byte, and anything after the 4th field.
- Photos go only to the group, never to the Public channel, and are too big for LoRa radios.

## Places

A place is an ordinary **Public channel** message that tells everyone nearby where to find help, so apps that don't
know places (and the Wi-Fi board) still show it as text:

```
💧 Water: tap at the school gym, bring bottles · 📍 45.46420,9.19000 ±12m
```

- It starts with one of `💧 Water`, `🏠 Shelter`, `🔌 Charging` or `🏥 Medical`, followed by nothing, `:` and a note
  (at most 200 characters), or ` · 📍 …`.
- The position, if any, is written and read exactly like a check-in's (see "Check-ins"). It is where the place is:
  apps add it only when the user says they are at the place.
- Anyone can read places, from any group. Apps sort them by distance and show their age.

### Freshness

Both apps judge a place by the time it was sent (the packet's `ts`): up to 24 hours old it is current; older than
24 hours (86,400,000 ms) it is old and shown greyed; older than 7 days (604,800,000 ms) it is expired and hidden. A
place from a clock that is ahead counts as current. Vectors: `kind: place-freshness`.

## Plus Codes

Positions can also be written as Plus Codes (Open Location Code, github.com/google/open-location-code, Apache License
2.0), which map apps understand and people can read out: 10 digits, for example `8FQFF57R+M2` for 45.46420,9.19000,
an area of about 14 × 14 m.

- Encoding follows the reference: latitude × 25,000,000 and longitude × 8,192,000, each rounded down, then clipped
  (latitude) or wrapped (longitude). Decoding gives the area's corners; its center is the position. Both apps pass rows
  of the reference's `encoding.csv` and `decoding.csv` (`PlusCodeTest`, `PlusCodeTests`) and `kind: pluscode`.
- Plus Codes are not part of messages: check-ins and places keep `📍 LAT,LON`.

### Status text for other apps

"Send via another app" hands another app a plain-text check-in (not encrypted), at most 160 characters, the limit of
satellite messengers:

```
🆘 I need help — Anna. Battery 64%. 45.46420, 9.19000 ±12 m (8FQFF57R+M2) https://osm.org/?mlat=45.46420&mlon=9.19000
```

The status, ` — ` and the name (at most 24 characters) if any, `.`, ` Battery N%.` if known, then, if there is a
position: the coordinates, ` ±N m` if known, the Plus Code in parentheses, and an OpenStreetMap link. Vectors:
`kind: status-share`.

## Delivery receipts

When a phone gets a new group message from someone else, it confirms it with a receipt, so the sender sees
"Delivered to …".

- A receipt is an ordinary packet: marker `0xB2`, a new random id, the reader's clock as `ts`, ttl 16.
- It is sealed exactly like a message, but with the group's **receipt key**: HKDF-SHA256 (RFC 5869) with the group
  key as input key material, no salt, info = the ASCII bytes of `darkproof-receipt-v1`, 32-byte output.
  - Example: for the code `test-group-1` the group key is
    `5b3b419c3127c6562d34f9357179690746274ea9f6088385901e83d1d4055a9a` and the receipt key is
    `496bfa142c33041abecd0fdb71763051e81c2fed0a55cbc1c0a7af8311d4a225`.
- Plaintext fields: `sender` = the reader's device id, `name` = the reader's display name, `text` = the ids of the
  confirmed messages (16 lowercase hex chars each), separated by single spaces, at most 200 per receipt.
- Phones confirm only group messages: not Public channel messages, and not their own. Each message is confirmed
  at most once, when it first arrives. A receipt goes out 2 s after the last message to confirm arrived, or 10 s after
  the first, whichever comes first, so a burst of messages (a phone catching up) shares one receipt per group.
- Receipts are not sent over LoRa radios, where airtime is scarce.
- Apps that don't know receipts can't open them with the group or public key, so they store and relay them like any
  other packet and never show them.

## Forwarding rules

- **Flooding:** each packet goes to every connected peer except the one it came from.
- **Deduplication:** a packet whose id has already been seen is ignored.
- **TTL:** forwarded copies carry `ttl - 1`, and only if the received ttl is greater than 1. New messages start at ttl 16.
  A received packet with ttl above 16 (decoding accepts up to 64) is stored and forwarded as if it had ttl 16.
- **Time:** a packet whose `ts` is more than 7 days old, or more than 10 minutes ahead of the receiver's clock, is
  dropped: not stored, shown or forwarded (it is not marked as seen, so it can come again later). Packets saved on the
  phone that are more than 10 minutes in the future are removed when the app reads its store.
- **Passing on:** up to 500 packets, the newest of the last 7 days. All of them are sent to every newly connected peer.
- **Storage on the phone:** every packet seen is saved, so messages are still there after a restart. The store is
  trimmed when the app starts, and whenever it grows 10% past its cap: packets older than 7 days that no saved group
  can read, Public messages beyond the newest 2,000, and then, while the store holds more than 40 MB (encoded packet
  sizes) or 20,000 packets: first packets no saved group can read, oldest first, then the oldest Public messages, and
  only then the oldest messages and receipts of the saved groups.
- **Sent:** a phone remembers (up to 2,000) which of its own messages it has handed to another phone, a radio or a
  relay, so "Sent" survives a restart.

## Transports

| Transport | Framing |
|---|---|
| Nearby Connections (Android only) | Service id `it.blackout.mesh.v1`, strategy `P2P_CLUSTER`. One `BYTES` payload per packet. |
| Wi-Fi networks (Android and iPhone) | TCP. 4-byte length, then the frame. See below. |
| LoRa via Meshtastic | The packet is `Data.payload` on port 256 (`PRIVATE_APP`), broadcast on channel 0 with hop limit 3. The whole packet must be ≤ 233 bytes. |
| LoRa via MeshCore | Channel data on the `#darkproof` channel, flooded. The whole packet must be ≤ 163 bytes. See below. |
| Bluetooth LE (Android and iPhone) | See below. |
| Internet relays (Android and iPhone) | Nostr events over WebSocket. See below. |
| Apple peer-to-peer (iPhone only) | MultipeerConnectivity. Each packet is one `.reliable` message. See below. |

## Internet relays

While there is internet (Wi-Fi, 4G, satellite), phones also exchange packets through free public **Nostr** relays
(NIP-01), optionally through Tor. DarkProof runs no server. The relays are one more peer for forwarding: a phone sends
them every packet it has and gets the packets of its mailboxes, so a phone that still has internet during a blackout
bridges its neighbourhood to the rest of the network.

### Mailboxes

The first 2 bytes of a new packet id are its **mailbox**; the other 6 bytes are random. The mailbox of a group is the
first 2 bytes of HMAC-SHA256(group key, `darkproof-relay-mailbox-v1`). Group messages and their delivery receipts use
the group's mailbox; Public messages use the mailbox of the Public channel key. Anyone can read the mailbox from the id
of any packet, so a phone can bridge packets it cannot open. Packets from older apps have random ids.

- Test values: group `test-group-1` → mailbox `a8d0`; the Public channel → `0794`.
- Someone who sees packets can tell which ones share a mailbox, not what they say. Many groups share each of the
  65,536 mailboxes. Ids keep 48 random bits, so duplicates stay negligible.

### Events

- **Kind:** `3871`, a regular (stored) kind. It is not in the NIPs list or the registry of kinds, and no events of
  nearby kinds were found on 11 public relays (2026-11).
- **Relays:** `wss://nos.lol`, `wss://relay.damus.io`, `wss://relay.primal.net`, `wss://nostr.mom`,
  `wss://nostr.oxtr.dev`, `wss://relay.ditto.pub`. All free, with no sign-up, payment or proof of work; all keep events
  at least 7 days, and all stored a 22 KB event of this kind from a new key (tested 2026-11-06). Phones use all of them
  at once, so one being down doesn't matter. Relays with a "web of trust" rule refuse large events from new keys.
- **Tags:** `["t", "dp1-<mailbox as 4 hex digits>"]`, `["x", "<packet id>"]` and
  `["expiration", "<created_at + 604800>"]` (NIP-40: relays may delete it after 7 days).
- **Content:** the packet (0xB2 encoding) in standard base64.
- **Key:** a new random secp256k1 key every time the app starts, so relays can't link one session to the next.
  The signature (BIP-340) only satisfies the relays: who wrote a message is inside the encrypted packet.
- **Mailboxes of a phone:** its group's, every other saved group's, and the Public channel's (`0794`), in that order.
- **Subscribe:** on each relay link, one live subscription for all of them,
  `["REQ", <id>, {"kinds": [3871], "#t": ["dp1-<mailbox>", …, "dp1-0794"], "since": now - 604800, "limit": 1}]`
  (`since` a week back so events from phones with a slow clock still match; stored events come from the catch-up).
- **Catch-up:** then, one mailbox at a time (groups first), `["REQ", <id>, {"kinds": [3871], "#t": ["dp1-<mailbox>"],
  "since": S, "limit": 500}]`, closed after its `EOSE`. When it returns 500 events, an older page follows with
  `"until"` = the oldest `created_at` received (that value minus 1 if it equals the previous `until`), up to 4 pages
  for a group mailbox and 1 for `0794`. S = the time this phone last caught up that mailbox on that relay minus 10
  minutes (clocks differ), but at most 7 days back. That time, saved on the phone per relay and mailbox, becomes the
  time a catch-up that ended with `EOSE` was started, and then follows the `created_at` of live events (never past
  the phone's clock). A catch-up refused with `CLOSED`, or without `EOSE` within 20 s, moves on and is tried on the
  next link.
- **Publish:** at most one event every 1.5 s, newest packet first, to every connected relay that isn't resting.
  Packets written on this phone (messages and its receipts, known by their ids) in the last 2 minutes go first. All
  others (bridging, and older own packets, which may have gone up before the app was killed) wait a random 0–30 s, so
  phones that got the same packet at the same moment don't all find it missing, and are then looked up with
  `["REQ", <id>, {"kinds": [3871], "#x": [<up to 50 packet ids>], "limit": <count>}]`; a packet counts as there only if
  a relay returns an event whose packet has the same `ts` and cipher (the ttl may differ). The others are posted, at
  most one every 4.5 s. A packet older than 7 days is never posted (checked again right before posting). Packets that
  came from relays never go back up. Delivery receipts are sent too.
- **Sent:** a packet counts as on the relays (and, for an own message, as "Sent") only when a relay answers
  `["OK", <event id>, true, …]` (or `false` with a reason starting `duplicate`), or the lookup found it. If every relay
  it went to refuses it, or none accepts it within 30 s, it is queued again, up to 3 tries; after that it waits until
  the relays link again. Each phone remembers up to 3,000 packets it saw accepted.
- **Queues:** at most 500 own packets, 5,000 to look up and 2,000 to post; when a queue is full, a newer packet
  replaces the oldest one.
- **Throttling:** a relay that refuses an event with a reason starting `rate` (`rate-limited:`, `rate limited`),
  `blocked` or `banned` gets no more events from this phone for 10 minutes (it keeps the subscription). With every
  relay resting, packets wait in the queue.
- **Reports:** a reported Public message is hidden on the phone, and a NIP-56 report (kind 1984, tags
  `["e", <event id>, "other"]` and `["p", <author>]`) goes to the relays.

### Tor

"Connect through Tor" (off by default) hides the phone's internet address from the relays. Phones are Tor clients
only, never relays.

- **Android:** Tor runs inside the app (tor-android 0.4.9.14, the Tor that Orbot uses) while the switch is on. Every
  relay link and the check below go through its SOCKS port; host names are resolved by Tor. Until it has a circuit,
  nothing goes to the relays.
- **iPhone:** Tor runs inside the app (iCepa's Tor.framework 409.15.3) from the first time it is needed until the app
  quits (Tor can start only once per launch). Relay links and the check use a URL session whose only route is Tor's
  SOCKS port on `localhost`, a free port picked at start.
- **Check:** before linking to any relay, the app fetches `https://check.torproject.org/api/ip` through Tor and goes
  on only if the answer has `"IsTor": true`; otherwise it asks again (every 15 s on Android, 5 s on the iPhone, while
  Tor starts). It asks again whenever all relays are lost.
- Tested 2026-11-06: no connection from either app to a relay or to the check went around Tor.
- **Relays through Tor:** `wss://relay.damus.io`, `wss://relay.primal.net`, `wss://nostr.oxtr.dev`,
  `wss://relay.ditto.pub`, `wss://relay.nostr.net`, `wss://nostr.data.haus`. nos.lol and nostr.mom don't answer Tor
  exits (tested 2026-11-06); the four relays in both lists carry messages between phones with and without Tor.

### Everyone filter

In other people's Public messages and places, each app masks offensive words with bullets (`•`, one per letter)
before showing them. Whole messages are never hidden, so an emergency message with a swear word still gets through.
Your own messages are shown as written. Both apps use the same list (`WordFilter.LIST` / `WordFilter.list`; the tests
pin its SHA-256) and the same rules:

- A word is a run of letters, digits, `@` and `$`; only words with a letter are checked.
- It is compared after removing accents, lowercasing, reading `0 1 3 4 5 7 @ $` as `o i e a s t a s` and dropping
  anything that is not `a`–`z`. Stretched words (a letter 3+ times in a row) are also tried with those runs cut to two
  letters and to one.
- It matches a list entry exactly, or starts with an entry that ends in `*`. Only whole words match, so "Scunthorpe"
  and "puttanesca" stay as written.

## Wi-Fi networks

Phones on the same Wi-Fi network connect over TCP: a router with no internet, a phone hotspot, a community network or a
long-range rooftop link. Nothing leaves that network.

- **Discovery:** DNS-SD (Bonjour/mDNS), service type `_darkproof._tcp`, instance name = the node id, port = the TCP
  port the device listens on (7777 when it is free). The iPhone lists `_darkproof._tcp` in `NSBonjourServices`.
- **Who connects:** for a discovered device, only the device with the smaller node id connects (comparing bytes), and it
  tries again every 10 s while there is no link. An address the user typed is always connected, and redialed every 5 s.
- **Frames:** a 4-byte big-endian length (1–16,064), then the frame. The first frame in each direction is HELLO: the
  ASCII bytes `DPW1`, then the node id in UTF-8 (1–64 bytes). Every later frame is one packet. A link whose first frame
  is not a HELLO, or whose HELLO carries the receiver's own node id, is closed.
- **Restarts and duplicate links:** when a node id that already has a link opens another, the phones keep one:
  - if the two links were dialed by different phones and the older one is less than 10 s old (both dialed at about
    the same time), the link dialed by the smaller node id (comparing bytes) stays, so both phones keep the same one;
  - otherwise the new link replaces the old one, which is closed (after a restart the old one may be dead without
    either side knowing).

  Each link is its own peer for forwarding, so all stored packets go to the new link. A phone doesn't redial a typed
  address while the phone that answered there is linked another way.
- **Limits:** at most 32 links. A frame longer than the limit closes the link, and so does a missing HELLO 10 s after
  connecting.
- **iPhone:** the listener and the Bonjour browser start again after any failure (after 2 s, doubling up to 30 s),
  and when the app comes back to the foreground.

## LoRa via MeshCore

MeshCore radios ("companion radio" firmware 1.15 or newer, `FIRMWARE_VER_CODE` ≥ 11) pair with the phone over Bluetooth
LE: Nordic UART service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, the phone writes (with response) to `6E400002-…` and
gets notifications from `6E400003-…`. One write or notification is one frame of at most 176 bytes; integers are
little-endian. Source: github.com/meshcore-dev/MeshCore, `examples/companion_radio/MyMesh.cpp` (v1.18).

- **Setup:** `16 03` (device query, protocol 3; the reply `0D` carries the firmware version code in byte 1 and the
  number of channel slots in byte 3), then `01` + 7 zero bytes + `DarkProof` (app start; reply `05`).
- **Channel:** DarkProof uses the hashtag channel `#darkproof`, key = the first 16 bytes of SHA-256(`#darkproof`) =
  `835a8265454a846068f204bf5ea81bd3`. The phone reads the slots with `1F <idx>` (reply `12 <idx> <name[32]> <key[16]>`)
  and, if none holds that key, writes it to the first empty slot with `20 <idx> <name[32]> <key[16]>`.
- **Sending:** `3E <idx> FF <type:u16> <packet>`: channel data, flooded (`FF`), data type `0xFF44` (MeshCore's range
  for development; to be registered before release). The packet is ≤ 163 bytes. Reply `00`.
- **Receiving:** the radio pushes `83` when something is queued; the phone sends `0A` until the reply is `0A`. Channel
  data arrives as `1B <snr> 00 00 <idx> <path_len> <type:u16> <len> <packet>`; only `type` `0xFF44` on the DarkProof
  slot is read. Other frames are skipped.
- **Pacing:** as for Meshtastic: only packets from the last 30 minutes, one every 20 s, no delivery receipts.

## Bluetooth LE

This is the only radio link both platforms share without a router. Android phones also keep Nearby. Duplicate packets arriving over both are dropped by the forwarding rules.

### Roles

Every device is a **peripheral**: it advertises and runs a GATT server. It is also a **central**: it scans and connects.

An iPhone in the background advertises in a way Android cannot see. It can still scan and connect out to Android phones, which always advertise.

### Service UUID

`bec33cd5-a64e-4e1a-b8c1-868db67d0df3`, the same for every DarkProof device (see "Groups and the Public channel").

- **Advertisement:** connectable. It contains only this 128-bit service UUID, with no device name.

### Characteristics

| Name | UUID | Properties | Direction |
|---|---|---|---|
| RX | `33826aba-0bb0-4dfe-9c1a-86e48726ed62` | write (with response) | central → peripheral |
| TX | `94eb2c34-0e66-4bea-864c-d02a7694a3d5` | notify, with a CCCD descriptor | peripheral → central |

### Connection setup

1. The central connects.
2. It requests the largest ATT MTU and discovers the service.
3. It enables notifications on TX by writing `01 00` to its CCCD.
4. The link is then open in both directions.

### Frames

Each direction carries a stream of frames:

`type` (1 byte) ‖ `length` (2 bytes, big-endian) ‖ `payload` (`length` bytes).

**Chunking:**
- The stream is cut into chunks of at most min(ATT_MTU − 3, 512) bytes. 512 is the longest attribute value BLE allows; Android throws an error above it.
- Each chunk is one write (central → peripheral) or one notification (peripheral → central). Long or prepared writes are not used.
- A side sends its next chunk only after the previous one completes. For the central, that is the write response. For the peripheral, that is the notification-sent callback.

**Frame types:**

| Type | Name | Payload |
|---|---|---|
| 1 | HELLO | Version byte `1`, then the node id: printable ASCII, 1–64 bytes. |
| 2 | PACKET | One packet (see above), up to 18 + 16000 bytes. |

- Each side sends HELLO as its first frame, as soon as it can send. For the central, that is after its CCCD write completes. For the peripheral, that is when notifications get enabled.
- PACKET frames received before the other side's HELLO are ignored.
- An unknown type, a version other than 1, or a bad length means: disconnect.
- After both HELLOs, each side treats the link as a neighbor in the forwarding rules. That includes sending it all stored packets.

### Restarts

An app can restart while the Bluetooth connection stays up: iOS keeps an app's connections when it closes the app to
free memory, and relaunches the app in the background when Bluetooth activity arrives. The restarted app starts the
link over and sends HELLO again.
- A device that gets a HELLO on a link that already has one **from the same node id** answers with its own HELLO again,
  and sends the link all stored packets again (the receiver drops the ones it has), each at most once a minute per
  link, and the stored packets only when the link's send queue is empty. The first repeat is always answered. This
  avoids HELLO ping-pong and endless re-sending. A HELLO with a different node id means: disconnect.
- A central whose peer republishes the DarkProof service (the service is invalidated) disconnects and connects again.

### Duplicate links

Two devices may connect to each other twice, once in each direction. When a device sees a second link to a node id it already has a link with, it keeps only one:
- Keep the link whose central has the smaller node id, comparing bytes.
- If both links have the same central, keep the newer one.

Both sides reach the same decision. Either side may close the other link.

### Limits

- At most 6 links per device. At the limit, a new link takes the place of the oldest link whose other side hasn't sent
  HELLO after 5 s, if there is one; otherwise it is refused.
- A link whose other side sends no HELLO within 10 s of the link opening (central: notifications enabled; peripheral:
  the central subscribed) is closed, and so is a central link still being set up 30 s after dialing. An iPhone cannot
  disconnect a central: it stops serving it, and the link no longer counts toward the limit.
- Each link's send queue holds at most 1 MiB and 1,000 frames. Beyond that, the oldest PACKET frames not yet started
  are dropped (the neighbour gets stored packets again on its next link); HELLO frames are never dropped.

## History

- `0xB1`, v0.2: text fields used Java's modified UTF-8, and the code was not normalized.
- `0xB2`, v0.3: standard UTF-8, NFC-normalized group code.
- `0xB2`, v0.4: same packets. Discovery no longer depends on the group code (one Bluetooth LE service UUID, one Nearby service id, no Multipeer group filter), and the Public channel was added. v0.3 and v0.4 devices do not find each other.

## Apple peer-to-peer (iPhone to iPhone)

iPhones also connect to each other with MultipeerConnectivity, which uses Bluetooth and Apple's peer-to-peer Wi-Fi. Android cannot join these connections.

- **Service type:** `blackout-mesh`. It is listed in the app's `NSBonjourServices`.
- **Peer display name:** the node id.
- **Discovery info:** `v` = `1`. Peers without it are ignored.
- **Who invites:** the device with the smaller node id. The invitation context is the UTF-8 bytes of `blackout-mesh-v1`, and invitations with a different context are declined.
- **Messages:** each packet is sent as one `.reliable` message.
