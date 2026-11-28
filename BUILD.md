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

## Adding or removing files

`FWPlayer.xcodeproj` is the project the app is built from, and it is edited
directly. Add a new file in Xcode (**File → Add Files to "FWPlayer"…**, target
**FWPlayer** ticked) and commit the changed `project.pbxproj` with it. CI builds
the committed project, so a file that was left out shows up as a red build.

`project.yml` is kept only as a readable summary of the settings. **Don't run
`xcodegen generate`**: the committed project has changes that aren't in
`project.yml` (e.g. the Korean localization region), and regenerating would drop
them.

`.gitignore` already tracks `FWPlayer.xcodeproj` while ignoring user-specific
state inside it.

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
`$(CURRENT_PROJECT_VERSION)`, so `scripts/bump-build.sh` (which edits both) is all a new build number needs.
