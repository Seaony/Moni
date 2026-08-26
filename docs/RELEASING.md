# Moni release process

Moni uses Sparkle for in-app updates and GitHub Releases for update hosting. Pushing a stable semantic-version tag such as `v1.2.3` starts the complete release workflow:

1. Archive a universal Developer ID build.
2. Export and verify the signed application.
3. Submit the application to Apple notarization and staple its ticket.
4. Create ZIP and DMG packages.
5. Notarize and staple the DMG.
6. Generate an EdDSA-signed Sparkle appcast.
7. Publish the ZIP, DMG, and `appcast.xml` to the matching GitHub Release.

The application checks this stable feed URL:

`https://github.com/Seaony/Moni/releases/latest/download/appcast.xml`

## One-time signing setup

### Sparkle update key

Resolve the Swift package once, then use Sparkle's bundled key tool:

```bash
xcodebuild -resolvePackageDependencies -project Moni.xcodeproj -scheme Moni
SPARKLE_TOOLS="$(find ~/Library/Developer/Xcode/DerivedData/Moni-*/SourcePackages/artifacts/sparkle/Sparkle -type d -path '*/Sparkle/bin' | head -1)"
"$SPARKLE_TOOLS/generate_keys" --account com.seaony.Moni
"$SPARKLE_TOOLS/generate_keys" --account com.seaony.Moni -x sparkle-private-key
```

Save the printed public key as the GitHub Actions repository variable `SPARKLE_PUBLIC_ED_KEY`.

Save the contents of `sparkle-private-key` as the encrypted repository secret `SPARKLE_PRIVATE_KEY`, then securely back it up and delete the exported file. Never commit the private key. Existing installations depend on retaining this key for future updates.

### Developer ID certificate

Export the `Developer ID Application` certificate and private key from Keychain Access as a password-protected `.p12`. Configure these encrypted repository secrets:

- `DEVELOPER_ID_APPLICATION_P12`: Base64 representation of the `.p12` file.
- `DEVELOPER_ID_APPLICATION_PASSWORD`: Password used when exporting the `.p12`.
- `KEYCHAIN_PASSWORD`: A new random password used only for the temporary CI keychain.

Generate the first value with:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

### Apple notarization API key

Create an App Store Connect API key with access to notarization and configure:

- `APPLE_API_KEY_P8`: Complete contents of the `AuthKey_….p8` file.
- `APPLE_API_KEY_ID`: API key identifier.
- `APPLE_API_ISSUER_ID`: API issuer identifier.

The workflow removes the temporary certificate, API key, and keychain even when a release fails.

## Publishing a release

Before tagging, ensure the intended release commit is on `master` and the Build workflow succeeds. Create and push an annotated tag:

```bash
git tag -a v1.2.3 -m "Moni 1.2.3"
git push origin v1.2.3
```

Only tags matching `vMAJOR.MINOR.PATCH` pass release validation. `MARKETING_VERSION` is derived from the tag and `CFBundleVersion` uses the monotonically increasing GitHub Actions run number.

If the same workflow run is retried, existing GitHub Release assets are replaced. A different commit must use a new version tag; published version tags must not be moved.

## Verification

The workflow verifies all of the following before publishing:

- Sparkle public key and HTTPS feed configuration.
- Sparkle framework embedding.
- Strict nested code signatures.
- Universal `arm64` and `x86_64` application binary.
- Apple notarization and stapled tickets for the app and DMG.
- Gatekeeper assessment.
- Well-formed appcast XML with an EdDSA archive signature and GitHub asset URL.

For an already exported release build, run:

```bash
scripts/validate-release.sh /path/to/Moni.app /path/to/appcast.xml
```

Do not hand-edit a generated appcast. Regenerate it so signed-feed and release-note signatures remain valid.
