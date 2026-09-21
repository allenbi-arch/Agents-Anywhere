# Building an Unsigned iOS IPA

This document explains how to produce an **unsigned** `.ipa` for the iOS client
from a **Windows** machine.

## Why Windows cannot build it locally

An `.ipa` is a ZIP archive whose `Payload/` directory contains an ARM64 Mach-O
application bundle. Producing that binary requires Apple's Darwin toolchain:

| Requirement | Why | Available on Windows? |
|---|---|---|
| `swiftc` with the iPhoneOS SDK | Compiles Swift to ARM64 Mach-O | No |
| `actool` | Compiles `Assets.xcassets` into `Assets.car` | No |
| `ibtool` / `linkd` | Compiles and links UI + frameworks | No |
| Xcode build system | Drives `xcodebuild archive` | No |
| iOS 26.5 SDK | Project sets `IPHONEOS_DEPLOYMENT_TARGET = 26.5` | No |

The last row matters most. `ios/Agents Anywhere/Agents Anywhere.xcodeproj/project.pbxproj`
declares `IPHONEOS_DEPLOYMENT_TARGET = 26.5`, and `ios/Package.swift` declares
`platforms: [.iOS("26.5")]`. Both require **Xcode 26.5 or newer**. There is no
way to satisfy that with the Windows Swift toolchain, and since Xcode 14 the iOS
SDK's `.tbd` stub libraries are in a format that cannot be extracted and
re-linked outside of Xcode.

Note also that `ios/Package.swift` only builds the `ClientCore` *library* — it
explicitly `exclude`s `App`, `Views`, `Stores`, `Services`, `Assets.xcassets`
and `Resources`. **SwiftPM alone cannot produce this app**, on any platform.

### What "unsigned" does *not* save you from

You asked for no signing, and this setup does no signing. But be clear about the
consequence:

> An unsigned `.ipa` **will not install on an iPhone**. iOS refuses to launch
> any binary without a valid signature. An unsigned `.ipa` is useful as a build
> artifact — for verifying the code compiles, for archiving a release, or as the
> input to a signing tool that applies *your own* certificate.

To actually run it on a device you still need one signing step at install time
(see [Installing](#installing-an-unsigned-ipa) below) — Sideloadly, AltStore, or
`zsign` with a free Apple ID. That is a separate, local step and is not part of
this build.

---

## Method 1 — GitHub Actions (recommended, fully automated from Windows)

This compiles on a GitHub-hosted macOS runner and hands you the `.ipa`.

### One-time setup

```powershell
# 1. Install the GitHub CLI
winget install --id GitHub.cli

# 2. Authenticate (choose HTTPS, and grant the "workflow" scope)
gh auth login

# 3. From the repo root: make sure a GitHub remote exists
git remote -v
# If there is none, create a repo on GitHub and add it:
#   git remote add origin https://github.com/<you>/<repo>.git
#   git push -u origin main
```

### Build

```powershell
# From the repo root
.\ios\scripts\build-ipa-from-windows.ps1
```

The script commits and pushes your working tree, triggers the
`iOS Unsigned IPA` workflow on a `macos-26` runner, streams progress, waits for
completion, and downloads the `.ipa` into `.\build\ios\`.

With options:

```powershell
# Override the marketing version and build number
.\ios\scripts\build-ipa-from-windows.ps1 -Version 2.0.1 -BuildNumber 8

# Debug configuration
.\ios\scripts\build-ipa-from-windows.ps1 -Configuration Debug

# Build the current remote HEAD without pushing anything
.\ios\scripts\build-ipa-from-windows.ps1 -SkipPush
```

### Manual alternative

Push the repo, then use the GitHub web UI:

1. Open the **Actions** tab.
2. Select **iOS Unsigned IPA** in the left sidebar.
3. Click **Run workflow**, choose the branch, set `configuration`, click
   **Run workflow**.
4. When the run finishes, download the **ios-unsigned-ipa** artifact.

### Cost

| Repo type | macOS runner billing |
|---|---|
| Public | Free |
| Private | 10× minutes (a ~10 min build consumes ~100 of your 2,000 monthly minutes) |

---

## Method 2 — A Mac (local, fastest iteration)

If you have access to any Mac with Xcode 26.5+:

```bash
# From the repository root
chmod +x ios/scripts/build-unsigned-ipa.sh
./ios/scripts/build-unsigned-ipa.sh

# Output: ./build/ios/AgentsAnywhere-<version>-<build>-unsigned.ipa
```

Options:

```bash
./ios/scripts/build-unsigned-ipa.sh \
  -o ./dist \
  -c Release \
  -v 2.0.1 \
  -b 8
```

### The raw commands it runs

If you prefer to drive Xcode yourself:

```bash
cd "ios/Agents Anywhere"

xcodebuild \
  -project "Agents Anywhere.xcodeproj" \
  -scheme "Agents Anywhere" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -sdk iphoneos \
  -archivePath /tmp/AgentsAnywhere.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  EXPANDED_CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  archive

# Package the .ipa
mkdir -p /tmp/ipa/Payload
cp -R /tmp/AgentsAnywhere.xcarchive/Products/Applications/"Agents Anywhere.app" /tmp/ipa/Payload/
cd /tmp/ipa && zip -qry ~/AgentsAnywhere-unsigned.ipa Payload
```

### Why each signing flag is set

The project hardcodes `DEVELOPMENT_TEAM = UM3Z9G5DNH` and
`CODE_SIGN_STYLE = Automatic`. Left alone, Xcode would try to contact Apple and
fail on a machine without that team's credentials. These overrides neutralise
that:

| Flag | Effect |
|---|---|
| `CODE_SIGNING_ALLOWED=NO` | Never invoke `codesign` |
| `CODE_SIGNING_REQUIRED=NO` | Don't fail when the output is unsigned |
| `CODE_SIGN_IDENTITY=""` | No identity to sign with |
| `EXPANDED_CODE_SIGN_IDENTITY=""` | Clears the resolved identity |
| `CODE_SIGN_ENTITLEMENTS=""` | Drops entitlements (they require a signature) |
| `CODE_SIGN_STYLE=Manual` | Suppresses automatic signing/provisioning |
| `DEVELOPMENT_TEAM=""` | Detaches the hardcoded team ID |

The build script also strips any leftover `_CodeSignature/` directories and
`CodeResources` files from the payload, because stale signature material breaks
later re-signing with Sideloadly / AltStore / `zsign`.

---

## Installing an unsigned IPA

The `.ipa` this produces cannot be installed as-is. Pick one:

| Tool | Platform | Notes |
|---|---|---|
| **Sideloadly** | Windows / macOS | Easiest on Windows. Free Apple ID works; app expires after 7 days. |
| **AltStore / SideStore** | Windows + iPhone | Needs a pairing file; auto-refreshes. |
| **zsign** | Windows / macOS / Linux | Command-line re-signing: `zsign -k cert.p12 -m profile.mobileprovision -o out.ipa in.ipa` |
| **TrollStore** | iOS 14–17.0 | Only for supported versions; permanently signs without a computer. |

`zsign` is the closest thing to a pure-Windows path: it can re-sign the
unsigned `.ipa` entirely on Windows, given a certificate and provisioning
profile. It still cannot *build* the app.

---

## Expected build output

```
==> Xcode 26.5 detected
==> iPhoneOS SDK: 26.5
==> Archiving (Release)...
==> Bundle ID: com.agentsanywhere.app
==> Version:   2.0.0 (7)
==> Packaging unsigned .ipa...
==> Binary arch: arm64

======================================================================
 Unsigned IPA built successfully
======================================================================
 Path:    /path/to/build/ios/AgentsAnywhere-2.0.0-7-unsigned.ipa
 Size:    18M
 SHA-256: <hash>
======================================================================
```

---

## Troubleshooting

**`requires a provisioning profile` / `No signing certificate found`**
A signing flag did not take effect. Verify `CODE_SIGNING_ALLOWED=NO` and
`CODE_SIGNING_REQUIRED=NO` are both on the `xcodebuild` command line, and that
`CODE_SIGN_STYLE=Manual` is set (otherwise Automatic signing re-enables
provisioning).

**`iOS 26.5 SDK not found` / `deployment target is greater than SDK`**
Your Xcode is too old. The project needs Xcode 26.5+. On CI, confirm the runner
is `macos-26`; the workflow also auto-selects the newest Xcode on the image.

**`cannot find 'Textual' in scope`**
The local Swift package at `ios/Packages/Textual` was not resolved. Run:
```bash
cd "ios/Agents Anywhere"
xcodebuild -resolvePackageDependencies -project "Agents Anywhere.xcodeproj" -scheme "Agents Anywhere"
```

**Archive succeeds but no `.app` in `Products/Applications`**
Check the archive with:
```bash
xcodebuild -exportArchive -archivePath <archive> ...   # or inspect in Xcode Organizer
```
Usually caused by a resource/asset compile failure that was downgraded to a
warning. Look for `actool` or `AssetCatalog` errors earlier in the log.

**The `.ipa` won't install on the device**
Expected — it is unsigned. Use one of the tools in
[Installing an unsigned IPA](#installing-an-unsigned-ipa).

---

## Files added by this setup

| File | Purpose |
|---|---|
| `ios/scripts/build-unsigned-ipa.sh` | macOS build + package script (also used by CI) |
| `ios/scripts/build-ipa-from-windows.ps1` | Windows helper: push, trigger CI, download `.ipa` |
| `.github/workflows/ios-unsigned-ipa.yml` | GitHub Actions workflow on `macos-26` |
| `ios/BUILD_IPA.md` | This document |
