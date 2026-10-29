# Releasing

A release is one GitHub release with three files:

| File | What it's for |
|---|---|
| `VoiceNote-Translator-<version>.dmg` | The drag-and-drop installer. Signed with a Developer ID and notarized. |
| `appcast.xml` | The update feed. Installed apps read it from `releases/latest/download/appcast.xml`. |
| `SHA256SUMS.txt` | Checksum of the disk image. |

## One-time setup

1. **Developer ID certificate.** Xcode → Settings → Accounts → your team → Manage Certificates → **+** → *Developer ID Application*. Needs a paid Apple Developer Program membership.
2. **Notary credentials**, saved in your Keychain as the profile `vnt-notary`:

   ```bash
   xcrun notarytool store-credentials vnt-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

   The team ID is the 10-character code in brackets after "Developer ID Application: Your Name".
3. **Update key.** Every entry in the update feed is signed with an EdDSA key, and apps only install updates signed with it. Its public half is in `Resources/update-public-key.txt` (built into the app); the private half lives in your login Keychain under the account `voicenote-translator`. To create one (only for a fork, never for this project once released):

   ```bash
   swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account voicenote-translator
   ```

   Put the printed public key into `Resources/update-public-key.txt`.

   **Back up the private key.** Without it you can't ship updates to anyone who already has the app:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account voicenote-translator -x update-key-backup.txt
   ```

   Keep that file somewhere safe and offline (a password manager works), never in the repo. Restore on another Mac with `generate_keys --account voicenote-translator -f update-key-backup.txt`.

## Each release

1. Bump `VERSION` and `"version"` in `extension/manifest.json` (they must match).
2. Add a `CHANGELOG.md` entry and write `docs/releases/v<version>.md`. This file becomes the GitHub release notes *and* the "What's new" text in the app's update window.
3. Commit, then:

   ```bash
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=vnt-notary make release
   ```

   This builds a universal app, notarizes and staples the app and the disk image, writes and signs `appcast.xml`, tags the commit and publishes the release.

Once the release is published, installed apps see it within a day, or immediately with **Check for Updates…**.

## How the update feed is found

`scripts/build-app.sh` writes `SUFeedURL` into the app's Info.plist from the git remote: `https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`. Set `FEED_URL` to override it (for example, to test against a local server). The repository must be public, since apps download the feed and disk image without logging in.

## Testing an update locally

1. Build version N with `FEED_URL=http://127.0.0.1:8899/appcast.xml scripts/build-app.sh --native --install`.
2. Bump to N+1, build into `build/`, make a disk image with `scripts/make-dmg.sh <folder>/VoiceNote-Translator-<N+1>.dmg`, then run `generate_appcast --account voicenote-translator --download-url-prefix http://127.0.0.1:8899/ <folder>` and serve the folder with `python3 -m http.server 8899 --bind 127.0.0.1`.
3. In the app choose **Check for Updates…**, or turn on automatic installs and post the `io.github.voicenote-translator.checkForUpdates` distributed notification for a silent check.
