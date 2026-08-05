# Melo 2.7.0 — Sparkle and Developer Updates

## Regular user updates

Melo now embeds Sparkle 2.9.5. Sparkle remains inactive until both values are configured in `Config/Info.plist`:

- `SUFeedURL`: the HTTPS URL to your `appcast.xml`
- `SUPublicEDKey`: the public EdDSA key printed by Sparkle's `generate_keys` tool

Before publishing:

1. Build and sign Melo with a Developer ID certificate.
2. Resolve the Sparkle package and locate its tools under Xcode's SourcePackages artifacts.
3. Run `generate_keys` once and store the private key safely in Keychain.
4. Put the public key in `SUPublicEDKey`.
5. Put the final feed URL in `SUFeedURL`.
6. Build the release ZIP.
7. Run `scripts/prepare-sparkle-release.sh` to generate or refresh the appcast.
8. Upload the appcast, update archive, release notes, and generated deltas to HTTPS hosting.

The local `Build Melo.command` uses ad-hoc signing for testing. Public Sparkle updates should use Developer ID signing and notarization.

## Developer Update Center

Settings → Updates now accepts developer updates from three sources:

- **Choose Update File…** — select a trusted ZIP anywhere in Finder.
- **Install from Link…** — download a trusted source ZIP over HTTPS.
- **Choose Folder to Check…** — remember a folder using a security-scoped bookmark and select the highest valid build in it.

A developer update ZIP must contain `manifest.json` and either source code or a built `Melo.app`.

```json
{
  "schemaVersion": 1,
  "version": "2.8.3",
  "build": 283,
  "bundleIdentifier": "dev.local.Melo",
  "packageType": "source",
  "minimumMacOS": "15.4",
  "sourceSubdirectory": "Melo-macOS-2.8.3",
  "releaseNotes": "Summary of this build"
}
```

For source updates, Melo runs `Build Melo.command`, `scripts/build-app.sh`, or the Melo Xcode project in a separate process. It validates the resulting app, backs up the current app, installs the new one, and waits for a startup marker. If startup is not confirmed within 60 seconds, the installer restores the prior app.

Create a future developer update with:

```bash
./scripts/make-developer-update.sh 2.8.3 283 /path/to/Melo-macOS-2.8.3 "Release notes"
```

Developer updates intentionally require a second **Build and Install** click. Melo never executes code merely because a folder or link was scanned.

## Onboarding after an update

Regular and developer updates replace only the app bundle. They preserve preferences and do not replay onboarding. The tutorial runs again only when the user explicitly chooses Replay Tutorial or erases Melo data.
