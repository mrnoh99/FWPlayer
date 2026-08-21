# Building FWPlayer

Once the Xcode project has been committed (see the one-time step below), you can
clone and build with **no extra tooling**:

```bash
git clone https://github.com/mrnoh99/FWPlayer.git
cd FWPlayer
open FWPlayer.xcodeproj
```

In Xcode: pick a destination (an iPhone/iPad, a Simulator, or **My Mac (Mac
Catalyst)**), set your signing team on the target if prompted, and **Run**.
Xcode fetches the Swift package dependency (SMBClient) automatically on first
open.

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

Set in `project.yml`:

```yaml
settings:
  base:
    MARKETING_VERSION: "1.0"        # CFBundleShortVersionString
    CURRENT_PROJECT_VERSION: "2"    # CFBundleVersion (build)
```

The Info.plist references these via `$(MARKETING_VERSION)` /
`$(CURRENT_PROJECT_VERSION)`, so bump the value here, regenerate, and rebuild.
