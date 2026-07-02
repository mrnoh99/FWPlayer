# FWPlayer — App Store submission guide

This is the checklist for shipping **FWPlayer** (iPhone / iPad / Mac Catalyst)
to the App Store. Everything that can live in the repo is already in place; the
rest is account/portal work that must be done in Apple's web consoles and Xcode.

---

## 1. What the repo already configures ✅

| Item | Where | Value |
|---|---|---|
| Bundle identifier | `project.yml` | `com.fwplayer.app` (Mac Catalyst derives its own) |
| Marketing version | `project.yml` / `Support/Info.plist` | `1.0` (`CFBundleShortVersionString`) |
| Build number | `project.yml` / `Support/Info.plist` | `1` (`CFBundleVersion`) |
| App Store category | Info.plist | `LSApplicationCategoryType = public.app-category.music` |
| Export compliance | Info.plist | `ITSAppUsesNonExemptEncryption = false` (HTTPS only → exempt) |
| Privacy manifest | `Sources/Resources/PrivacyInfo.xcprivacy` | no tracking, no data collected, UserDefaults + file-timestamp reasons declared |
| Usage strings | Info.plist | `NSLocalNetworkUsageDescription`, `NSAppleMusicUsageDescription` |
| Background audio | Info.plist | `UIBackgroundModes = [audio]` |
| App icon | `Sources/Resources/Assets.xcassets/AppIcon.appiconset` | 1024×1024 marketing icon present |
| Deployment targets | `project.yml` | iOS 17.0, macOS 14.0 (Catalyst) |
| Device family | `project.yml` | `1,2` (iPhone + iPad) + Mac Catalyst |

> **Regenerate after pulling these changes:** `xcodegen generate`. The new
> `PrivacyInfo.xcprivacy` and the added Info.plist keys only enter the Xcode
> project on the next generate. Confirm afterward that **PrivacyInfo.xcprivacy
> appears in the target's _Copy Bundle Resources_ build phase** — it must ship
> at the bundle root.

---

## 2. Apple Developer prerequisites (one-time)

1. **Apple Developer Program membership** ($99/yr) on the team that will own
   the apps (Team ID `9AWEB9NYHH`). A free Personal Team cannot ship to the
   store.
2. **App ID** `com.fwplayer.app` registered at
   [developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   with these capabilities enabled:
   - **MusicKit** (primary album-metadata source). *If MusicKit stays
     unavailable, the app still works — it falls back to the free iTunes
     Search API automatically, so MusicKit is not a hard blocker for shipping.*
3. **Signing**: in Xcode → target → Signing & Capabilities, pick the paid team
   and let Automatic signing manage profiles. (`CODE_SIGN_STYLE = Automatic` is
   already set.)

---

## 3. Create the App Store Connect record

In [App Store Connect → Apps → +](https://appstoreconnect.apple.com):

- **Platforms**: iOS *and* macOS (one record can host both because Catalyst
  shares the bundle ID lineage).
- **Name**: `FWPlayer` (must be globally unique — have a backup like
  "FWPlayer – Lossless" ready).
- **Primary language**, **Bundle ID** `com.fwplayer.app`, **SKU** (any string,
  e.g. `fwplayer-001`).
- **Category**: Music (matches `LSApplicationCategoryType`).

---

## 4. Privacy "nutrition label" (App Store Connect → App Privacy)

Answer to match the shipped `PrivacyInfo.xcprivacy`:

- **Data collection**: **No, we do not collect data from this app.** FWPlayer
  sends only the track's existing artist/title to Apple's public catalog
  endpoints; nothing is linked to identity or stored off-device.
- **Tracking**: No.

---

## 5. Build & upload

```bash
xcodegen generate            # picks up the privacy manifest + new plist keys
open FWPlayer.xcodeproj
```

In Xcode:

1. Bump `CURRENT_PROJECT_VERSION` / `CFBundleVersion` for every new upload
   (the marketing version `1.0` can stay until features warrant `1.1`).
2. **iOS build**: select *Any iOS Device (arm64)* → Product ▸ Archive ▸
   Distribute App ▸ App Store Connect.
3. **Mac Catalyst build**: select *My Mac (Mac Catalyst)* → Product ▸ Archive ▸
   Distribute App. Catalyst app-store builds are signed with a **Mac App
   Distribution** profile (Automatic signing handles it).

### Mac Catalyst review note
The entitlements include two temporary exceptions (`Support/FWPlayer.entitlements`):
- a mach-lookup exception for `com.apple.audioanalyticsd` — without it,
  AVFoundation crashes the sandboxed Catalyst process the moment audio starts;
- a read-only file exception for `/Volumes/` — so an inserted **audio CD**
  (mounted by macOS under `/Volumes` as `cddafs` AIFF tracks) can be
  auto-detected and its tracks ripped to a temp file for playback, without
  making the user pick the disc by hand each time.

Keep both; if a reviewer questions them, explain they're required for audio
playback under the App Sandbox and for the audio-CD feature respectively. (If
the audio-CD feature is dropped, remove the `/Volumes/` exception.) (`get-task-allow` is **not** in the entitlements file, so
release archives are correctly signed for distribution.)

---

## 6. Screenshots (required, per device class)

Capture from the real UI (light + a couple of representative screens: browser,
two-pane player, now-playing details):

- **iPhone 6.9"** (e.g. iPhone 16 Pro Max) — required.
- **iPhone 6.5"** — recommended fallback.
- **iPad 13"** (e.g. iPad Pro 13") — required because the app supports iPad.
- **Mac** — 1280×800 (or larger 16:10) screenshots of the Catalyst app.

---

## 7. Review information

- **Sign-in**: none required (no account system).
- **Notes for reviewer**: "FWPlayer plays lossless audio the user adds via
  Files/SMB. Album art and year/genre are fetched from Apple's catalog
  (MusicKit, falling back to the public iTunes Search API). The optional
  FWPlayer Remote companion app controls playback over the local network —
  not required to review core playback. To test playback, add any FLAC/WAV/ALAC
  file through the in-app file picker. The app uses the `audio` background mode
  so playback continues with the screen off. It also offers an optional,
  user-toggleable 'Stay on in background' setting (Sidebar ▸ Remote, on by
  default) that keeps the app reachable by the FWPlayer Remote while paused so
  the user can resume playback from the companion app without unlocking this
  device; the user can turn it off to save battery."

---

## 8. Pre-submit sanity checklist

- [ ] `xcodegen generate` run; `PrivacyInfo.xcprivacy` in Copy Bundle Resources.
- [ ] Archive validates clean (Xcode Organizer ▸ Validate App).
- [ ] App icon shows no alpha channel / rounded corners (square 1024², opaque).
- [ ] Version/build incremented vs. any prior TestFlight upload.
- [ ] Privacy answers in App Store Connect = "no data collected".
- [ ] Both iOS and Mac Catalyst archives uploaded (if shipping both).
