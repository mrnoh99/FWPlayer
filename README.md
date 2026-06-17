# FWPlayer

A lossless **FLAC / WAV** audio player for **iPhone, iPad, and Mac desktop**
(Apple Silicon & Intel, via Mac Catalyst). Play tracks from a local file folder
on the device or stream them from an **SMB network share** (NAS, PC share)
over Wi‑Fi.

## Features

- 🎵 Plays **FLAC** and **WAV / WAVE** using the system audio stack
  (`AVAudioPlayer`), which supports FLAC natively on iOS 16+ / macOS 13+.
- 📂 **Local folders** — browse the app's on‑device folder (files added via
  Finder file sharing, AirDrop, or *Save to Files*) and any folder you pick
  through the Files app, including network shares you've connected there.
- 🌐 **SMB network share** — connect directly to an SMB server by host/IP,
  share name, and credentials (or as Guest). Folders are browsed remotely and
  files are downloaded on demand for gapless local playback.
- ⏯️ Full transport: play/pause, next/previous, scrub/seek, auto‑advance
  through a folder queue.
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

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
so it isn't committed (see `.gitignore`).

```bash
brew install xcodegen          # one-time
xcodegen generate              # creates FWPlayer.xcodeproj
open FWPlayer.xcodeproj
```

Then select the **FWPlayer** scheme and run on an iPhone/iPad simulator or
device, or choose **My Mac (Mac Catalyst)** for the desktop app. Set your
signing team in Xcode (or `DEVELOPMENT_TEAM` in `project.yml`) before running
on a device.

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
