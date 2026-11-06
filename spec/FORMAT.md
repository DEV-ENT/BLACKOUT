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
- **Reading:** a device tries its own group's key first, then the public key. A packet that opens with neither is relayed but not shown.

## Invites

An invite link carries a group's name and code so nobody has to type the code:

```
darkproof://join?name=<group name>&code=<group code>
```

- Both values are URL-encoded query items. `code` has at least 8 characters. `name` is only a label shown on screen; it is not used for encryption, and a missing name means "Group".
- Apps show the link as a QR code and can send it any way the phone can share a link, such as AirDrop.
- New groups get a random code of 16 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, in four groups of four joined by `-` (80 bits of entropy).
- Anyone with the link can read the group, exactly like anyone who knows the code.

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
  at most once, when it first arrives; messages arriving within about 2 seconds share one receipt.
- Receipts are not sent over LoRa radios, where airtime is scarce.
- Apps that don't know receipts can't open them with the group or public key, so they store and relay them like any
  other packet and never show them.

## Forwarding rules

- **Flooding:** each packet goes to every connected peer except the one it came from.
- **Deduplication:** a packet whose id has already been seen is ignored.
- **TTL:** forwarded copies carry `ttl - 1`, and only if the received ttl is greater than 1. New messages start at ttl 16.
- **Storage:** up to 500 packets, kept for at most 7 days. All stored packets are sent to every newly connected peer.

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
- **Subscribe:** `["REQ", <id>, {"kinds": [3871], "#t": ["dp1-<own group>", "dp1-0794"], "since": now - 604800,
  "limit": 500}]` on every relay.
- **Publish:** at most one event every 1.5 s, to every connected relay, newest packet first. Packets written on this
  phone (still at full TTL) in the last 2 minutes go first. All others (bridging, and older own packets, which may
  have gone up before the app was killed) are first looked up with
  `["REQ", <id>, {"kinds": [3871], "#x": [<up to 50 packet ids>], "limit": <count>}]`; only those no relay returns
  within 6 s are posted, at most one every 4.5 s. Each packet goes up once from each phone; packets that came from
  relays never go back up. Delivery receipts are sent too.
- **Throttling:** a relay that refuses an event with a reason starting `rate` (`rate-limited:`, `rate limited`),
  `blocked` or `banned` gets no more events from this phone for 10 minutes (it keeps the subscription).
- **Reports:** a reported Public message is hidden on the phone, and a NIP-56 report (kind 1984, tags
  `["e", <event id>, "other"]` and `["p", <author>]`) goes to the relays.

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
- **Restarts and duplicate links:** a new link from a node id that already has one replaces it, and the old link is
  closed (after a restart the old one may be dead without either side knowing). Each link is its own peer for
  forwarding, so all stored packets go to the new link.
- **Limits:** at most 32 links. A frame longer than the limit closes the link.

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
  and sends the link all stored packets again (the receiver drops the ones it has). A HELLO with a different node id
  means: disconnect.
- A central whose peer republishes the DarkProof service (the service is invalidated) disconnects and connects again.

### Duplicate links

Two devices may connect to each other twice, once in each direction. When a device sees a second link to a node id it already has a link with, it keeps only one:
- Keep the link whose central has the smaller node id, comparing bytes.
- If both links have the same central, keep the newer one.

Both sides reach the same decision. Either side may close the other link.

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
