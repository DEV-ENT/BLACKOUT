# DarkProof privacy policy

Last updated: November 6, 2026

DarkProof is a messaging app that keeps working when there is no internet. It has no servers of ours, no accounts, no analytics, no ads and no tracking. The developer receives no data from the app; only the emails you choose to send us.

## What stays on your phone

- The name and group codes you enter.
- Every message packet your phone receives or sends. This includes encrypted packets from other groups that your phone passes on but cannot read. Your groups' messages stay until you delete the app, the newest 2,000 Everyone messages are kept, and packets your phone can't read are removed after 7 days.
- Your conversation with the AI assistant, and any AI models you download.
- The LoRa radios you paired, if any.
- The people you blocked and the messages you reported or hid.

## Messages between phones (no internet needed)

Messages travel to nearby phones running DarkProof over Bluetooth, Wi-Fi peer-to-peer, Wi-Fi networks and LoRa radios. Every phone passes messages on to the phones it meets, for up to 7 days.

- **Group messages** are encrypted end to end with a key made from your group code. Phones and relays that pass them on cannot read them. Anyone who knows the group code can read them.
- **Everyone messages** (the Public channel) can be read by anyone who has DarkProof. Treat them as public.
- **Places you share** (water, shelter, charging, medical) are Everyone messages: anyone with DarkProof can read them, including the position if you choose to add yours.
- Each message carries the name you entered and a random ID for your phone.
- **Photos you send** are group messages too: shrunk to a few hundred pixels and encrypted for your group.
- **Check-ins** ("I'm safe", "I need help") carry your battery level.
- **Your position, only if you turn on "Share my location in check-ins"** in Settings. Each check-in then carries where you were and how precise the phone was. Like every group message, it is encrypted for your group.
- **Delivery receipts:** your phone tells your group which of their messages it received, so they can see "Delivered". Receipts are encrypted for your group too.

## Internet relays (when you have internet)

With **Internet** on (Connections screen, on unless you turn it off), and while your phone has Wi-Fi or mobile data, messages also travel through free public relays that use the Nostr protocol. This lets the group and Everyone chats work across any distance. Turn Internet off and DarkProof uses no relays.

- **The relays** are run by other people, not by us: nos.lol, relay.damus.io, relay.primal.net, nostr.mom, nostr.oxtr.dev and relay.ditto.pub (with Tor: relay.damus.io, relay.primal.net, nostr.oxtr.dev, relay.ditto.pub, relay.nostr.net and nostr.data.haus). Their own privacy policies apply to what they receive.
- **What your phone sends them:** each message packet once, exactly as it travels between phones. Group messages stay encrypted; the relays cannot read them. Everyone messages and places can be read by anyone with DarkProof, so relays and anyone using them could read them too. Your phone also passes on packets of other groups it is carrying, which it cannot read. That helps a neighbourhood without internet reach the rest of the world.
- **What the relays can see:** your internet (IP) address, unless you use Tor; when each packet was sent; a random key your phone makes new every time the app starts; and a short "mailbox" tag that many groups share, which lets your phone ask only for packets that might be for you.
- **How long they keep it:** each packet is marked to be deleted after 7 days. Relays are asked to delete it then, but we cannot check or force them to.
- **Reports:** when you report an Everyone message, your phone hides it, and sends the relays a standard Nostr report that names that message and its random sender key. It does not include your name.

## Tor (optional, off by default)

With **Connect through Tor** on, DarkProof runs Tor inside the app and sends all its relay traffic through it. The relays then see the address of a Tor exit node instead of yours. Tor nodes see that you use Tor, not what you send. Before linking to any relay, DarkProof asks the Tor Project's check service (check.torproject.org), through Tor, whether the connection really goes through Tor. Nothing goes to the relays until it does.

## Other ways DarkProof uses the internet

Only when you ask for them:

- **AI model downloads**, when you tap Download. Models come from Hugging Face (huggingface.co), which sees your IP address like any website. Your questions to the AI never leave the phone.
- **Street maps**, when you tap Download map, or open the map while you have internet. Map data comes from OpenFreeMap (tiles.openfreemap.org), which sees your IP address and which map area is loaded. The saved map stays on your phone.
- **Send via another app**, when you tap Share "I'm safe" or Share "I need help" (Connections screen). DarkProof hands the app you pick a short plain-text message with your name, battery and, if location is allowed, your position. It is not encrypted: that app, and whoever receives it, can read it.
- **Wi-Fi board (Android only).** When you turn it on, anyone who joins your phone's Wi-Fi network can read Everyone messages and post new ones from a browser. Group messages are never shown there.

## Keeping the Everyone chat safe

- **Filter:** in other people's Everyone messages and places, offensive words are masked with bullets on your phone. Nothing is sent anywhere for this.
- **Report:** hold an Everyone message and tap Report. It is hidden on your phone and reported to the relays (see above).
- **Block:** hold any message and tap Block. That person's messages, places and check-ins are hidden on your phone. Unblock in Settings.
- **Contact us** about abuse or anything else at support@darkproof.app.

## Permissions

- **Bluetooth**: to connect to nearby phones and to LoRa radios.
- **Local network**: for Wi-Fi peer-to-peer connections between iPhones, and to find and link DarkProof phones on the same Wi-Fi network (router, hotspot or community network).
- **Internet (Android)**: for the relays, Tor, AI model downloads and maps described above.
- **Camera (iPhone, optional)**: only when you tap Take photo. Photos you choose from your library are picked by the system: DarkProof sees only the one you choose. On Android, photos come only from the system photo picker, with no camera or photo library permission.
- **Add to Photos (iPhone, optional)**: only if you save a photo from the chat.
- **Notifications (optional)**: alerts for new group messages and check-ins, made on your phone. No push server is involved and nothing is sent to Apple, Google or us.
- **Location (optional)**: only while the app is open: to add your position to check-ins if you turned that on, to add it to a place you share if you choose, to sort shared places by distance, and to point you toward a friend or a place. Never in the background.
- **Android only**:
  - **Location and nearby devices**: Android requires these to search for other phones over Bluetooth and Wi-Fi.
  - **Notifications**: to keep the mesh running in the background, and for the message alerts above.

DarkProof sends your location only where you choose: to your group in check-ins if you turn that on, or to everyone when you share a place with your position.

## Children

DarkProof is not meant for children under 13. The Everyone chat is open to anyone with the app.

## Deleting your data

Delete the app to remove everything it stored on your phone. Copies of your messages on other phones are not deleted, but those phones stop passing them on after 7 days. Copies on internet relays are marked for deletion after 7 days.

## Changes

If this policy changes, the new version will be published at https://darkproof.app/privacy with a new date.

## Contact

Email support@darkproof.app, or open an issue at https://github.com/DEV-ENT/DarkProof/issues.
