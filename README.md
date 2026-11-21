# FWPlayer

A lossless **FLAC / WAV** audio player for **iPhone, iPad, and Mac desktop**
(Apple Silicon & Intel, via Mac Catalyst). Play tracks from a local file folder
on the device or stream them from an **SMB network share** (NAS, PC share)
over Wi‑Fi.

## Features

- 🎵 Plays the common audio formats the system audio stack (`AVAudioPlayer` /
  Core Audio) decodes — **FLAC, WAV/WAVE, AIFF, Apple Lossless, CAF, AU, MP3,
  AAC / M4A** — plus **Ogg Vorbis / Opus** through a pluggable decoder
  (`Sources/Audio/OggAudioDecoder.swift`, compiled in when the Xiph C libraries
  are linked — see `project.yml`).
- 🎚️ **Bit-perfect output for a USB DAC** — matches the audio hardware to each
  track's native sample rate (no resampling), unity gain, no time-stretch.
  Turn on **Bit-Perfect Mode** (sidebar → Output) to lock the app volume at
  100% and see whether the DAC is actually running at the track's rate.
- 🔊 **DSD (DSF / DFF)** — DSD64 / DSD128 are sent **bit-exact over DoP** to a
  USB DAC (volume locked at 100%; the system volume must be at maximum, and the
  output must be a USB DAC). On any other output — or for DSD256 — the file is
  filtered and converted to 24-bit PCM instead, so it's always safe to play.
  Embedded ID3 tags are read. DST-compressed and multichannel files aren't
  supported.
- 🧭 **Output awareness** — the Output section shows where audio is going (e.g.
  *iPad Speaker*, a USB DAC), warns when that route can't be bit-perfect
  (speaker, Bluetooth, AirPlay) or when the system volume isn't at maximum, and
  verifies that the hardware followed the track's sample rate. On **Mac** the
  output device's sample rate is switched to each track's automatically
  (*Match DAC Sample Rate*).
- 📡 **Remote control** — advertises a Bonjour `_fwplayer._tcp` service so the
  FWPlayer Remote app can discover and control playback on the local network.
- 📂 **Local folders** — browse the app's on‑device folder (files added via
  Finder file sharing, AirDrop, or *Save to Files*) and any folder you pick
  through the Files app, including network shares you've connected there.
- 🌐 **SMB network share** — connect directly to an SMB server by host/IP,
  share name, and credentials (or as Guest); **edit** a saved server, browse
  with cached listings, and time-limited connects (no endless “Loading…”).
- ⏯️ Full transport: play/pause, next/previous, scrub/seek, auto‑advance
  through a folder queue.
- 📝 **Playlists** — create named playlists, add tracks from any folder or SMB
  share, reorder and remove entries, rename or delete the playlist, and play it
  as a queue. Playlists persist across launches.
- 🔒 Lock‑screen / Control Center **Now Playing** integration and remote
  commands; background audio on iOS.
- 🗂️ Sidebar library with multiple sources; SMB passwords stored in the
  **Keychain**, folder access persisted via **security‑scoped bookmarks**.

## Platforms

| Target            | Minimum OS |
|-------------------|------------|
| iPhone / iPad     | iOS 17.0   |
| Mac (Catalyst)    | macOS 14.0 |

A single application target ships to all three via Mac Catalyst.

## Project layout

```
Package.swift              Test-only SwiftPM package (`swift test`) over the pure-logic sources
Tests/                     Unit tests (DSD / DoP conversion, tags)
scripts/bump-build.sh      Bumps the build number in project.yml and the Xcode project
project.yml                 XcodeGen project definition (single Catalyst target)
Support/
  Info.plist                Generated from project.yml `info.properties`
  FWPlayer.entitlements      Network client + Catalyst sandbox entitlements
Sources/
  App/                      App entry point
  Models/                   FileItem, Track, SMBServerConfig
  Sources/                  FileSource protocol + Local/SMB implementations + registry
  Storage/                  Keychain, bookmark & SMB-server persistence
  Audio/                    AudioPlayer (AVAudioPlayer + Now Playing/remote commands)
  Views/                    SwiftUI UI (browser, player, SMB form, …)
  Resources/                Assets.xcassets (app icon + accent color)
```

## Building

The generated Xcode project (`FWPlayer.xcodeproj`) is committed, so you can clone
and build with no extra tooling (see [BUILD.md](BUILD.md)):

```bash
open FWPlayer.xcodeproj
```

`project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen)) remains the
source of truth. Only when you add/remove source files or change Info.plist,
entitlements, or build settings, regenerate and commit the project:

```bash
brew install xcodegen          # one-time
xcodegen generate
```

Then select the **FWPlayer** scheme and run on an iPhone/iPad simulator or
device, or choose **My Mac (Mac Catalyst)** for the desktop app. Set your
signing team in Xcode (or `DEVELOPMENT_TEAM` in `project.yml`) before running
on a device.

## Tests

```bash
swift test        # on a Mac; no simulator needed
```

CI runs the unit tests and builds the app for the iOS Simulator and Mac Catalyst.

## SMB support

Direct in‑app SMB connections are implemented with the pure‑Swift
[`SMBClient`](https://github.com/kishikawakatsumi/SMBClient) package, declared
in `project.yml`. The integration lives entirely in
`Sources/Sources/SMBFileSource.swift` and is guarded by
`#if canImport(SMBClient)`, so the app still builds (with SMB reporting as
unavailable) if the dependency is removed.

You can also reach SMB shares **without** the package: connect the share in the
**Files** app first, then *Add Folder…* in FWPlayer and pick it — access is
preserved through a security‑scoped bookmark.

> The SMB layer targets `SMBClient`'s public API (`SMBClient(host:port:)`,
> `login(username:password:)`, `connectShare(_:)`, `listDirectory(path:)`,
> `download(path:)`). If you pin a different version whose API differs, adjust
> the small `SMBConnection` actor in `SMBFileSource.swift`.

## Adding audio files

- **iPhone/iPad:** the *On This Device* source maps to the app's Documents
  folder. Drop files there via Finder (USB) file sharing, AirDrop → FWPlayer,
  or *Save to Files → On My iPhone → FWPlayer*.
- **Any folder / network drive:** tap **＋ → Add Folder…** and select it.
- **SMB server:** tap **＋ → Add SMB Server…**, enter host/share/credentials,
  optionally *Test Connection*, then *Save*.

## Playlists

Two playlists are built in and can't be deleted: **Favorites** (star a track) and
**Played** — every track you've played, oldest first (most recent last), kept
across launches (up to 1000).

- Create one with **＋ → New Playlist…** (or *New Playlist…* from the *Add to
  Playlist* sheet).
- While browsing a folder/share, swipe a track or long‑press it and choose
  **Add to Playlist**; tap a playlist to toggle the track in or out.
- Open a playlist from the sidebar to play it, tap **Edit** to reorder/remove
  entries, or use the ••• menu to *Play*, *Rename*, or *Delete Playlist*.
