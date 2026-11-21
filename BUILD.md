# Building FWPlayer

The generated Xcode project is committed, so a fresh clone (or a `git pull`)
builds with **no extra tooling** — just Xcode 15 or later.

```bash
git clone https://github.com/mrnoh99/FWPlayer.git     # or: git pull
cd FWPlayer
open FWPlayer.xcodeproj
```

## One-time: your signing team

Signing needs your Apple Developer team. Keep it in a git-ignored file instead of
the project, so pulling never conflicts with it:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# edit Config/Local.xcconfig → DEVELOPMENT_TEAM = <your team ID>
```

(You can also pick the team in Xcode → target → Signing & Capabilities, but that
edits the project file and will conflict on pulls.) Without any team the app still
builds and runs in the **iOS Simulator**; the Mac build can run unsigned with
`CODE_SIGN_IDENTITY[sdk=macosx*] = -` (see the example file).

## Build and run

1. Pick a destination: an iPhone/iPad, a Simulator, or **My Mac (Mac Catalyst)**.
2. **Run** (⌘R). On first open Xcode fetches the SMBClient package (pinned to
   0.3.1 in `Package.resolved`).

That's all — the DSD/DST decoder is plain C compiled into the app, so nothing else
needs to be installed.

## Tests

```bash
swift test        # DSD / DoP / SACD image unit tests, no simulator needed
```

---

## One-time: commit the Xcode project (do this on a Mac that has xcodegen)

The project is generated from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen). It only needs to be generated
**once** and committed; after that nobody needs xcodegen to build.

```bash
brew install xcodegen        # if you don't have it
cd FWPlayer
xcodegen generate            # creates FWPlayer.xcodeproj
git add -A
git commit -m "Commit generated Xcode project (clone-and-build)"
git push origin main
```

`.gitignore` is already set up to track `FWPlayer.xcodeproj` while ignoring
user-specific state inside it.

---

## When do I need xcodegen again?

Only when the **project structure** changes:

- you add or remove a source file, or
- you change Info.plist keys, entitlements, or build settings in `project.yml`.

Then re-run `xcodegen generate` and commit the updated `FWPlayer.xcodeproj`.
Everyday code edits to existing files need **no** regeneration.

## Version / build number

`scripts/bump-build.sh` bumps the build number in `project.yml` **and** the
committed Xcode project in one step (no xcodegen needed): `scripts/bump-build.sh`
for +1, or `scripts/bump-build.sh 12` to set it. The details below are what it
edits.

Set in `project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0"        # CFBundleShortVersionString
    CURRENT_PROJECT_VERSION: "2"    # CFBundleVersion (build)
```

The Info.plist references these via `$(MARKETING_VERSION)` /
`$(CURRENT_PROJECT_VERSION)`, so bump the value here, regenerate, and rebuild.
