# DarkProof privacy policy

Last updated: November 4, 2026

DarkProof is a messaging app for when there is no internet. It has no servers, no accounts, no analytics, no ads and no tracking. The developer receives no data from the app.

## What stays on your phone

- The name and group code you enter.
- Every message packet your phone receives or sends. This includes encrypted packets from other groups that your phone passes on but cannot read. They stay on the phone until you delete the app.
- Your conversation with the AI assistant, and any AI models you download.
- The LoRa radio you paired, if any.

## What leaves your phone

- **Messages, to nearby phones running DarkProof.** They travel over Bluetooth, Wi-Fi peer-to-peer and LoRa radios, with no internet. Every phone passes messages on to the phones it meets, for up to 7 days.
  - **Group messages** are encrypted end to end with a key made from your group code. Phones that relay them cannot read them. Anyone who knows the group code can read them.
  - **Public channel messages** can be read by anyone who has DarkProof.
  - **Places you share** (water, shelter, charging, medical) are Public channel messages: anyone nearby can read them, including the position if you choose to add yours.
  - Each message carries the name you entered and a random ID for your phone.
  - **Photos you send** are group messages too: shrunk to a few hundred pixels and encrypted for your group.
  - **Check-ins** ("I'm safe", "I need help") carry your battery level.
  - **Your position, only if you turn on "Share my location in check-ins"** in Settings. Each check-in then carries where you were and how precise the phone was. Like every group message, it is encrypted for your group.
  - **Delivery receipts:** your phone tells your group which of their messages it received, so they can see "Delivered". Receipts are encrypted for your group too.
- **Wi-Fi board (Android only).** When you turn it on, anyone who joins your phone's Wi-Fi network can read Public channel messages and post new ones from a browser. Group messages are never shown there.
DarkProof uses the internet only in these two cases, and never needs it to work:

- **AI model downloads**, only when you tap Download. Models come from Hugging Face (huggingface.co), which sees your IP address like any other website. Your questions to the AI never leave the phone.
- **Street maps**, when you tap Download map, or open the map while you have internet. Map data comes from OpenFreeMap (tiles.openfreemap.org), which sees your IP address and which map area is loaded, like any website. Nothing else is sent. The saved map stays on your phone.

## Permissions

- **Bluetooth**: to connect to nearby phones and to LoRa radios.
- **Local network**: for Wi-Fi peer-to-peer connections between iPhones.
- **Camera (iPhone, optional)**: only when you tap Take photo. Photos you choose from your library are picked by the system: DarkProof sees only the one you choose. On Android, photos come only from the system photo picker, with no camera or photo library permission.
- **Add to Photos (iPhone, optional)**: only if you save a photo from the chat.
- **Notifications (optional)**: alerts for new group messages and check-ins, made on your phone. No push server is involved and nothing is sent to Apple, Google or us.
- **Location (optional)**: only while the app is open: to add your position to check-ins if you turned that on, to add it to a place you share if you choose, to sort shared places by distance, and to point you toward a friend or a place. Never in the background.
- **Android only**:
  - **Location and nearby devices**: Android requires these to search for other phones over Bluetooth and Wi-Fi.
  - **Notifications**: to keep the mesh running in the background, and for the message alerts above.

DarkProof sends your location only where you choose: to your group in check-ins if you turn that on, or to everyone nearby when you share a place with your position. It never reads your location in the background.

## Deleting your data

Delete the app to remove everything it stored on your phone. Copies of your messages on other phones are not deleted, but those phones stop passing them on after 7 days.

## Contact

Open an issue at https://github.com/DEV-ENT/DarkProof/issues.
