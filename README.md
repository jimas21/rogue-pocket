# Rogue Pocket

A small iPhone and iPad app, built entirely in the cloud. There is no Mac in this project: GitHub Actions builds,
signs and uploads each build to TestFlight.

The home screen is still the pipeline check: it shows the version, the build number and "Pipeline OK".
From there, "Emulator test" opens a Game Boy Advance emulator (mGBA, built into the app) that runs a ROM you
load from the Files app on the phone. No game is included in this repository or the app.

## How it builds

On every push to `main` (and on demand from the Actions tab), `.github/workflows/testflight.yml`:

1. runs on a `macos-26` runner (Xcode 26, iOS 26 SDK),
2. installs XcodeGen and builds libmgba for iOS from a pinned mGBA commit (`ci/build_mgba.sh`),
3. generates the Xcode project from `project.yml`,
4. archives the app, signed by Apple's cloud-managed certificates through an App Store Connect API key,
5. exports with `destination=upload`, which sends the build straight to TestFlight.

A second workflow, `.github/workflows/mgba-check.yml`, builds libmgba and compiles the app unsigned. It uses no
secrets and no Apple account, so it works before the developer account is ready.

The build number is the workflow run number, so every upload is unique and increasing.

## Configuration

Nothing personal is in this repository. The workflow reads:

| Kind | Name | What it is |
|------|------|------------|
| Variable | `BUNDLE_ID` | The bundle ID registered with Apple |
| Variable | `TEAM_ID` | The 10-character Apple Developer Team ID (not a secret) |
| Secret | `ASC_KEY_ID` | App Store Connect API key ID |
| Secret | `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| Secret | `ASC_KEY_P8` | Contents of the API key's `.p8` file |

Set them under Settings, Secrets and variables, Actions. The workflow's first step checks they are present
and well-formed, and stops with a plain message if not.

## Safety

- Only `push` to `main` and manual runs trigger the workflow. Pull requests, including from forks, never run it
  and never see secrets.
- The API key is written to a temporary file for the job and deleted at the end. Scripts never print it.
- `.gitignore` blocks ROMs, save files, `.p8`, `.p12` and provisioning profiles. Do not commit game files or
  signing material to this repository. The ROM and the save only ever live on the phone.

## Using the emulator test

Put a `.gba` in the app's folder in the Files app (On My iPhone, Rogue Pocket), or use the menu at the top right of
the emulator screen: Load ROM, Import save, Export save, Reset, Benchmark, Mute, mGBA log. The save lives in
`Saves/<rom name>.sav`; importing one keeps the old one in `Saves/Backups`. The line under the picture shows
frames per second, the time `runFrame` takes, audio buffer health, and the save type.

## Third-party code

mGBA (MPL-2.0) is fetched at build time and linked in. See `THIRD_PARTY.md`.

## Layout

```
project.yml            XcodeGen project definition (the .xcodeproj is generated, never committed)
Config/Info.plist      app Info.plist (declares no non-exempt encryption)
RoguePocket/           SwiftUI sources and asset catalog
RoguePocket/Core/      rp_core.c/.h: plain-C shim over libmgba, and MGBACore.swift (the Swift face of it)
RoguePocket/Emulator/  Emulator.swift (clock, input, files, stats) and AudioOutput.swift
RoguePocket/UI/        the emulator screen, touch controls, Files pickers
ci/                    the scripts the workflows run (also readable as documentation)
.github/workflows/     testflight.yml (build and upload), mgba-check.yml (unsigned compile check)
```
