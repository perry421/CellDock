# CellDock release blocker

CellDock v0.3.1 Build 105 is built, tested, and available as a validated Universal community archive. Formal Apple distribution is blocked only by missing release credentials on this Mac.

## Missing requirements

- A valid `Developer ID Application` certificate with its private key in the login Keychain.
- A working `notarytool` Keychain profile for the same Apple Developer team.

The current Keychain contains only an `Apple Development` identity. The community package therefore cannot receive an Apple notarization ticket and is rejected by `spctl` as expected.

## Manual action required

1. Install the Developer ID Application certificate and private key in Keychain Access.
2. Create a `notarytool` Keychain profile using an app-specific Apple ID password or an App Store Connect API key.
3. Re-run the release packaging in `release` signing mode, submit the ZIP with `notarytool`, staple the resulting app, rebuild the ZIP, and verify it with `stapler validate` and `spctl`.

Do not commit certificates, private keys, passwords, provisioning profiles, or notarization credentials to this repository.
