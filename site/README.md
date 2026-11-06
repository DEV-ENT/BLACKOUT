# darkproof.app

The website: what DarkProof is, the privacy policy, and the page behind invite links
(`https://darkproof.app/join#name=…&code=…`, see spec/FORMAT.md "Invites"). Plain static files: no build step, no
cookies, no analytics, no outside fonts or scripts.

| File | What it is |
|---|---|
| `index.html` | Home page: what DarkProof does, downloads, link to the privacy policy. |
| `privacy.html` | The privacy policy. Generated from `../PRIVACY.md`; don't edit it by hand. |
| `join.html`, `join.js` | Invite page. Reads the invite from the `#fragment` in the browser only and offers "Open in DarkProof" (the `darkproof://` link, which every app version understands), "Copy invite" and the downloads. Its Content-Security-Policy (`connect-src 'none'`) stops scripts from sending anything anywhere. |
| `style.css`, `logo.png`, `favicon.png` | Shared style and icons (from `../brand/darkproof-logo.png`). |
| `.well-known/apple-app-site-association` | Lets the iPhone app open `https://darkproof.app/join…` links (Universal Links). |
| `.well-known/assetlinks.json` | The same for Android (App Links). |
| `_headers` | Content type and privacy headers for Netlify and Cloudflare Pages. |
| `.nojekyll` | Makes GitHub Pages publish `.well-known/`. |
| `make-privacy.py`, `README.md` | Tools and notes; no need to upload them. |

## Before going live

1. **Store links**: in `index.html` and `join.html`, replace `APP_STORE_ID` with the App Store id. The Google Play link
   already uses the package name `it.darkproof.mesh`.
2. **iPhone**: in `.well-known/apple-app-site-association`, replace `TEAMID` with the Apple Developer Team ID (the Xcode
   project currently signs with team `MT94WQCB6S`). The app needs the Associated Domains entitlement
   `applinks:darkproof.app`.
3. **Android**: in `.well-known/assetlinks.json`, replace `RELEASE_KEY_SHA256` with the SHA-256 of the release signing
   certificate (with Play App Signing: Play Console → Test and release → App integrity → App signing key certificate).
   The other entry is the debug key of the development Mac (`keytool -list -v -keystore ~/.android/debug.keystore
   -alias androiddebugkey -storepass android`), so debug builds can be tested; remove it for the public release. The
   app needs an intent filter with `android:autoVerify="true"` for `https://darkproof.app` with path prefix `/join`.
4. **Privacy policy**: after any change to `PRIVACY.md`, run `python3 site/make-privacy.py` from the repo root.

## Hosting

Any static host with HTTPS works (Cloudflare Pages, Netlify, GitHub Pages, a plain web server). Requirements:

- `https://darkproof.app/join` (no `.html`) must show `join.html`. Cloudflare Pages, Netlify and GitHub Pages do this on
  their own; on nginx use `try_files $uri $uri.html $uri/ =404;`.
- `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json` must be served over HTTPS **without
  redirects**, as `application/json`. `_headers` sets this on Netlify and Cloudflare Pages; GitHub Pages can't set
  headers, so prefer one of the others.
- If `www.darkproof.app` is used too, redirect it to `darkproof.app` for normal pages (the apps accept both in links,
  but the app-link files are only checked on `darkproof.app`).
- Keep access logs short or off if the host allows it. Browsers never send the `#fragment`, so logs don't contain
  invites, but they do contain visitors' IP addresses. Consider adding a line about the website to `PRIVACY.md`.

Steps on Cloudflare Pages (free): create a project, upload the contents of `site/` (or connect the repo with build
output directory `site`), add the custom domain `darkproof.app`, done. Netlify: drag the `site` folder onto
app.netlify.com/drop, then add the domain.

Check after deploying:

```
curl -sI https://darkproof.app/.well-known/apple-app-site-association   # 200, application/json, no redirect
curl -s  https://app-site-association.cdn-apple.com/a/v1/darkproof.app   # what iPhones will see (Apple caches it)
curl -s 'https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://darkproof.app&relation=delegate_permission/common.handle_all_urls'
adb shell pm verify-app-links --re-verify it.darkproof.mesh && adb shell pm get-app-links it.darkproof.mesh
```

## support@darkproof.app

The address is on every page and in the privacy policy. Set it up before the site goes live:

1. At the domain's DNS provider, turn on mail forwarding to the team's inbox (Cloudflare Email Routing and ImprovMX
   are free; a mail host such as Fastmail or Proton also works). This adds the MX and SPF (TXT) records.
2. To answer from the same address, set it up as a sending identity in the mail host and add its DKIM record.
3. Send a test message from an outside account and check that it arrives and that replies are not marked as spam.
