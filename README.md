# Rogue Pocket

Pokémon Emerald Rogue on iPhone and iPad, with a live Rogue Dex.

- mGBA emulation, full screen in portrait or landscape
- Multi-touch controls and game controller support
- Plays offline; syncs the ROM and save with a home server
- Built on GitHub Actions and installed through TestFlight

## Building

Every push to `main` builds the app on GitHub Actions and uploads it to TestFlight.

Repository variables: `BUNDLE_ID`, `TEAM_ID`
Repository secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (App Store Connect API key)

## License

Uses [mGBA](https://mgba.io) (MPL-2.0). See [THIRD_PARTY.md](THIRD_PARTY.md).
No game files are included.
