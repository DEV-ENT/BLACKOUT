# BLACKOUT

Blackout is a messaging app for when there is no internet and no mobile network. Phones talk to each other directly and pass messages along, so a message can reach someone who is out of range of the sender. An on-device AI helps with practical questions, and an optional LoRa radio extends the range to kilometres.

There are two apps that work together: one for **Android** and one for **iPhone**. They use the same message format and encryption.

## Features

- **Group chat with end-to-end encryption.** Everyone in a group shares a group code. Messages are encrypted with AES-256-GCM, using a key derived from that code (PBKDF2, 120,000 rounds). Phones that relay a message can't read it.
- **Mesh forwarding.** Every phone stores messages and passes them on to the phones it meets:
  - Duplicates are dropped.
  - Each message can be relayed up to 16 times.
  - Each phone passes on up to 500 messages, for 7 days. Messages stay readable on the phone until the app is deleted.
- **Ways phones connect:**

  | Connection | Android | iPhone |
  |---|---|---|
  | Google Nearby Connections (Bluetooth and Wi-Fi Direct) | ✓ | |
  | Bluetooth LE, so Android and iPhone can talk to each other | ✓ | ✓ |
  | Apple peer-to-peer (MultipeerConnectivity) | | ✓ |
  | LoRa through a Meshtastic radio (EU 868 MHz), over Bluetooth | ✓ | ✓ |

- **AI that runs on the phone.** It needs no internet once its model is downloaded.
  - **iPhone:** runs on llama.cpp. You pick the model in the app, and it keeps the conversation as context.
  - **Android:** runs Qwen 2.5 1.5B on MediaPipe.
- **Groups and people (iPhone):**
  - "Create a group" makes a strong random code. Friends join by pointing the iPhone Camera at the invite QR, or by an invite sent over AirDrop.
  - The People tab shows who is in your group, who is in range now, and when you last heard from everyone else.
  - **I'm safe** and **Need help** check-in buttons.
  - Groups you leave are kept, so you can switch back.
- **Public channel.** Anyone with Blackout can read and post on it, whatever their group. Every phone relays every message, including messages from other groups that it cannot read.
- **Android extras:**
  - **Share app:** sends the app itself to another Android phone over Quick Share or Bluetooth, with no internet.
  - **Wi-Fi board:** the phone opens its own Wi-Fi network and a web page, so people without the app can read and post Public messages from a browser.
- **LAN test mode (debug builds only).** Emulators and simulators can exchange real app traffic over TCP. This tests chat, relaying and encryption, but not Bluetooth.

## Repository layout

| Path | Contents |
|---|---|
| `app/` | Android app (Kotlin, minSdk 26) |
| `ios/Blackout/` | iPhone app (SwiftUI, iOS 16.4+) |
| `ios/BlackoutCore/` | Swift package: packet format, encryption, forwarding, Bluetooth LE and Meshtastic protocol logic |
| `ios/Vendor/fetch-llama.sh` | Downloads the pinned llama.cpp build for iPhone |
| `spec/FORMAT.md` | Wire format and Bluetooth LE protocol, shared by both apps |
| `spec/test-vectors.txt` | Byte-exact examples that both apps' tests check |
| `tools/` | Test tools: a Mac Bluetooth LE test peer, an AI check, and the test-vector generator |

## Build

### Android

1. You need Android Studio, or the Android SDK with platform 35 and JDK 17 or newer.
2. Create `local.properties` containing `sdk.dir=<path to your Android SDK>`.
3. Build:
   ```bash
   ./gradlew assembleDebug
   ```
4. Install. You need a phone with Google Play Services; uninstall older Blackout versions first.
   ```bash
   adb install -r app/build/outputs/apk/debug/app-debug.apk
   ```

### iPhone

1. You need Xcode 27 or newer.
2. Run this once to download llama.cpp (pinned release, checked against its SHA-256):
   ```bash
   ios/Vendor/fetch-llama.sh
   ```
3. Open `ios/Blackout.xcodeproj`.
4. Under Signing & Capabilities, pick your Team. A free Apple ID works, but the app then has to be reinstalled every 7 days.
5. Select your iPhone and press Run.

Simulator builds work too. They don't include the AI, and the Simulator has no Bluetooth.

### Tests

```bash
./gradlew testDebugUnitTest          # Android
cd ios/BlackoutCore && swift test    # Swift core
```

## AI models (iPhone)

The app downloads a model once, while internet is available, and checks its SHA-256.

| Model | Size | License |
|---|---|---|
| Qwen 2.5 1.5B Instruct | 1.1 GB | Apache 2.0 |
| Llama 3.2 3B Instruct | 2.0 GB | Llama 3.2 Community License (Built with Llama) |
| Qwen 2.5 3B Instruct | 2.1 GB | Qwen Research License (non-commercial only), so debug builds only |

Small models can be wrong. In a real medical emergency, use the AI's answers carefully.

## Status

**Verified:**
- All unit tests pass.
- Chat, relaying and encryption between two Android emulators, both over the LAN test mode and over the emulators' simulated Bluetooth LE.
- An iPhone Simulator chatting with an Android emulator over the LAN test mode.
- Two iPhone Simulators connecting over Apple peer-to-peer.
- A real iPhone 15 exchanging messages with a Mac over real Bluetooth LE.
- The AI running on a real iPhone 15.
- On a real iPhone 15, over real Bluetooth LE: messages arrive while the phone is locked, and the link comes back after the other side restarts.
- Relaying across groups, and the Public channel, between a real iPhone and a Mac.
- On an Android emulator: the Wi-Fi board (its own Wi-Fi network, the page in a browser, posting in both directions), and the share sheet for sharing the app.

**Not verified yet:**
- Android on real phones, including sending the app to another phone and a real phone joining the Wi-Fi board.
- iPhone and Android over real Bluetooth.
- iPhone to iPhone on real devices.
- LoRa with real Meshtastic radios.
- Battery use and range.

## Privacy and TestFlight

- Privacy policy: [PRIVACY.md](PRIVACY.md). Blackout has no servers and collects no data.
- How to put the iPhone app on TestFlight: [docs/TESTFLIGHT.md](docs/TESTFLIGHT.md).

## Known limits

- Android needs Google Play Services.
- iOS restricts background work. The iPhone AI only runs while the app is on screen.
- LoRa carries only short messages (about 160 characters), one every 20 seconds, and only messages from the last 30 minutes.

## License

Third-party code: llama.cpp is MIT-licensed (see `ios/Vendor/LICENSE-llama.cpp.txt`). AI models have their own licenses, listed above.

This project doesn't have a license of its own yet.
