# Rogue Pocket

Pokémon Emerald Rogue for iPhone and iPad: the mGBA emulator core with a Rogue Dex overlay, built and signed
entirely on GitHub Actions and delivered through TestFlight.

No game is included in this repository or the app. The app plays a ROM that the user supplies.

## Features

- **Game Boy Advance emulation** with mGBA, linked in as a static library.
- **Full-screen play** in portrait or landscape. Multi-touch controls (slide across the D-pad, hold two buttons),
  game controllers through the GameController framework, and a menu on the picture for Home, Sync, Mute, Reset,
  Files and Debug.
- **Sync with a home server.** The app keeps its own copy of the ROM and save, so it plays offline. When it can
  reach the server it brings both up to date: it uploads a newer save from the phone, downloads a newer one from the
  server, and asks which to keep when both changed. No save is replaced without a backup. Pairing is a one-time QR
  code scan; the server address and key are stored on the device (Keychain), never in this repository.

## How it builds

On every push to `main` (and on demand from the Actions tab), `.github/workflows/testflight.yml`:

1. runs on a `macos-26` runner (Xcode 26, iOS 26 SDK),
2. installs XcodeGen and builds libmgba for iOS from a pinned mGBA commit (`ci/build_mgba.sh`),
3. generates the Xcode project from `project.yml`,
4. archives the app, signed by Apple's cloud-managed certificates through an App Store Connect API key,
5. exports with `destination=upload`, which sends the build straight to TestFlight.

`.github/workflows/mgba-check.yml` builds libmgba and compiles the app unsigned. It needs no secrets.

The build number is the workflow run number, so every upload is unique and increasing.

## Configuration

The workflow reads these repository settings:

| Kind | Name | What it is |
|------|------|------------|
| Variable | `BUNDLE_ID` | The bundle ID registered with Apple |
| Variable | `TEAM_ID` | The 10-character Apple Developer Team ID |
| Secret | `ASC_KEY_ID` | App Store Connect API key ID |
| Secret | `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| Secret | `ASC_KEY_P8` | Contents of the API key's `.p8` file |

Set them under Settings, Secrets and variables, Actions. The first step checks they are present and well-formed.

## Safety

- Only pushes to `main` and manual runs trigger the signed build. Pull requests, including from forks, never run it
  and never see secrets.
- The API key is written to a temporary file for the job and deleted at the end. Scripts never print it.
- `.gitignore` blocks ROMs, save files, `.p8`, `.p12` and provisioning profiles.

## Files on the device

The app's folder appears in the Files app (On My iPhone, Rogue Pocket). ROMs live in `ROMs/`, saves in
`Saves/<rom name>.sav`, and every replaced save is kept in `Saves/Backups`. A `.gba` dropped into the folder can be
opened from the menu (Files, Load ROM).

## Third-party code

mGBA (MPL-2.0) is fetched at build time and linked in. See `THIRD_PARTY.md`.

## Layout

```
project.yml            XcodeGen project definition (the .xcodeproj is generated, never committed)
Config/Info.plist      app Info.plist
RoguePocket/           SwiftUI sources and asset catalog
RoguePocket/Core/      rp_core.c/.h: plain-C shim over libmgba, and MGBACore.swift (the Swift face of it)
RoguePocket/Emulator/  Emulator.swift (clock, input, files, stats) and AudioOutput.swift
RoguePocket/Sync/      SyncManager.swift (ROM and save sync, pairing) and its views
RoguePocket/UI/        home screen, game screen, touch controls, Files pickers
ci/                    the scripts the workflows run
.github/workflows/     testflight.yml (build and upload), mgba-check.yml (unsigned compile check)
```
