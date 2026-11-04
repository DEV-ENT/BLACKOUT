# Putting Blackout on TestFlight

TestFlight lets up to 10,000 people install Blackout from a link before it is on the App Store. Testers need the free TestFlight app, and each build expires after 90 days.

The project is ready: version 0.4 (build 4), app icon, privacy manifest, iPhone only. Release builds leave out the debug tools and the Qwen 2.5 3B model, whose license forbids commercial use.

## 1. One-time setup (you)

1. **Join the Apple Developer Program** at https://developer.apple.com/programs/. It costs 99 USD a year. Approval can take a day or two.
2. **Sign in in Xcode** with that Apple ID: Xcode → Settings → Accounts.
3. **Pick the new team.** Open `ios/Blackout.xcodeproj` → target Blackout → Signing & Capabilities → Team. The project still has the free Personal Team (MT94WQCB6S), which cannot upload.
4. **Create the app** in App Store Connect (https://appstoreconnect.apple.com) → Apps → + → New App:
   - Platform: iOS
   - Name: Blackout. If that name is taken, try something like "Blackout Mesh".
   - Bundle ID: `it.blackout.mesh`
   - SKU: anything, e.g. `blackout`

## 2. Upload a build

1. Once per checkout, download llama.cpp:
   ```bash
   ios/Vendor/fetch-llama.sh
   ```
2. In Xcode, choose **Any iOS Device** as the destination.
3. Choose Product → Archive.
4. In the Organizer window, choose Distribute App → TestFlight & App Store.

Every upload needs a higher build number: raise `CURRENT_PROJECT_VERSION` (now 4).

## 3. What App Store Connect asks

- **Encryption (export compliance).** Blackout encrypts messages end to end with standard algorithms: AES-256-GCM and PBKDF2, through Apple's CryptoKit. It uses nothing proprietary. Answer Apple's questions with that; they tell you whether any document is needed.
- **App Privacy.** Choose "Data Not Collected".
- **Privacy policy URL:** https://github.com/DEV-ENT/BLACKOUT/blob/main/PRIVACY.md
- **Beta App Review notes** (needed for external testers). Paste something like:
  > Blackout sends messages between nearby phones without internet, over Bluetooth and Wi-Fi peer-to-peer. With one device: enter any name and a group code of 8 or more characters; the top bar shows SEARCHING until another phone with Blackout is nearby. With two devices: use the same group code and keep them within about 10 m. The AI tab downloads an on-device model (1.1 GB) once, over the internet.

## 4. Invite testers

- **Internal testers.** Up to 100 people you add as users in App Store Connect. They can install as soon as the build finishes processing, with no review.
- **External testers.** Up to 10,000 people:
  1. Create a group and add the build.
  2. Submit it for Beta App Review, which usually takes about a day.
  3. Turn on **Public Link** and share the link.

## Tell testers

- Download an AI model while you still have internet. It does not work offline until it is downloaded.
- Keep Blackout open, or at least running, near other phones. Phones connect on their own.
- Blackout cannot reach anyone over long distances without LoRa radios. It hops from phone to phone.
