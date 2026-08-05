# Hosting Melo's updates on GitHub

Free, and the same repo satisfies GPL-3.0.

## Layout

| What | Where | Why |
|---|---|---|
| `appcast.xml` | GitHub Pages, from `docs/` on `main` | Permanent HTTPS URL, correct content type, a few KB |
| App `.zip` | GitHub Releases | Up to 2 GB per file, separate from the Pages bandwidth allowance |
| `index.html` | GitHub Pages, from `docs/` | The page you send people |

The split is deliberate. Keeping the feed on Pages means **the feed URL never changes**, no matter how releases are tagged or retagged — and `SUFeedURL` is compiled into every copy already in the wild, so it can never change.

## One-time setup

```bash
./scripts/publish-setup.sh
```

That is the whole thing. It installs the GitHub CLI if needed, signs you in,
creates the repository, pushes, enables Pages over the API, generates your
signing key, writes both settings into `Config/Info.plist`, and publishes the
first release.

You are asked for exactly two things, because neither can be automated on your
behalf: signing in to GitHub in the browser, and allowing the Keychain to store
your new signing key.

If you would rather do it in pieces, the individual scripts still work:

```bash
scripts/setup-github-updates.sh <owner>/Melo   # writes SUFeedURL, builds docs/
scripts/sparkle-setup.sh                       # creates your EdDSA signing key
```

…then create the repo, push, and set Settings → Pages → Deploy from a branch,
`main`, `/docs`. The Updates tab reports whichever piece is still missing.

## Every release after that

```bash
# bump VERSION and BUILD_NUMBER in scripts/build-app.sh, then:
./scripts/release.sh
```

Which builds with `--release`, signs and regenerates the appcast, creates the GitHub release with the archive attached, refreshes the download page, and pushes. Installed copies pick it up on their next check.

## Things that will bite you

**Keep `outputs/sparkle-releases/`.** `generate_appcast` builds the feed from the archives it finds there. Delete the folder and older versions silently drop out of the appcast.

**Never lose the private key.** It lives in your login Keychain as "Private key for signing Sparkle updates". Without it, no existing install will accept another update from you — ever. There is no recovery. Back it up.

**Bump the build number before releasing.** `release.sh` refuses to overwrite an existing tag, and Sparkle compares `CFBundleVersion`.

**`--release`, not `--dev`.** A `--dev` build carries the developer-update machinery, which has no business on someone else's Mac. `release.sh` enforces this.

## What this does not solve

Melo is ad-hoc signed and not notarized, so a first launch still needs
System Settings → Privacy & Security → **Open Anyway**. The download page walks
people through it. Removing that step means an Apple Developer ID
($99/year), hardened runtime, and notarization — worth it when strangers start
asking for the app, not before.
