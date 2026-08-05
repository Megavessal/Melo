# Melo update server setup

Melo 2.6.0 includes a native, opt-in updater. Until these two values are set in
`Config/Info.plist`, the Updates tab simply reports that the update service is not connected:

- `MeloUpdateFeedURL`: the HTTPS address of your JSON update file
- `MeloUpdatePublicKey`: the Base64-encoded 32-byte Ed25519 public key used to verify releases

The private signing key must never be included in Melo or uploaded beside the app.

## Update file

Host JSON in this form:

```json
{
  "version": "2.6.1",
  "build": 261,
  "minimumSystemVersion": "15.4",
  "downloadURL": "https://updates.example.com/Melo-macOS-2.6.1.zip",
  "sha256": "64-lowercase-hex-characters",
  "signature": "BASE64_ED25519_SIGNATURE",
  "releaseNotes": "Improvements and fixes.",
  "publishedAt": "2026-08-10T18:00:00Z"
}
```

Melo signs and verifies exactly these four lines, including the final checksum but no trailing newline:

```text
2.6.1
261
https://updates.example.com/Melo-macOS-2.6.1.zip
64-lowercase-hex-characters
```

Sign that UTF-8 text with Ed25519, then Base64-encode the signature. Melo rejects HTTP downloads,
an invalid signature, a checksum mismatch, a different bundle identifier, or a build number that
does not match the update file.

## Hosting

Any static HTTPS host works. Upload the app ZIP first, then publish the JSON file last. This avoids
offering an update before its download is available.

For public distribution, sign Melo with a Developer ID certificate and notarize it before publishing.
The local build script uses an ad-hoc signature, which is intended only for development on your Mac.

## Installation behavior

Melo can check and download automatically. Automatic replacement is offered only when the folder
containing the running app is writable. Otherwise, Melo reveals the verified download for manual
installation. The installer keeps the previous app until the new copy is in place and restores it if
the replacement fails.

First-run completion is stored independently of the app version, so installing an update does not
replay onboarding or the guided tour.
