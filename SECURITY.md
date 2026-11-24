# Security

The updater holds the Docker socket of every host it runs on, so a flaw in it is a flaw in each of those hosts.
[updater/README.md](updater/README.md#security-model) says who is trusted with what.

## Reporting a vulnerability

Report it privately on GitHub: this repository's Security tab, then "Report a vulnerability". Please don't open an
issue or a pull request for it. If the Security tab has no such button, open an issue that asks for a private way to
report a flaw and leaves out what it is; the reply gives you one. The fix ships as a release, and its advisory says
which versions to leave.

## Supported versions

The latest release. An app's updater moves to a fixed one when the app's next release names it in its compose file,
or when its owner changes the pin.

## Checking the image

Every image is signed with cosign, keyless, by this repository's release workflow on `main`: the identity a running
updater asks of the image that replaces it. Check one before you run it:

<!-- x-release-please-start-version -->
```sh
cosign verify ghcr.io/escalay/updater:1.2.0 \
  --certificate-identity https://github.com/escalay/selfhost-kit/.github/workflows/release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify oci://ghcr.io/escalay/updater:1.2.0 --repo escalay/selfhost-kit
```
<!-- x-release-please-end -->

The second checks the build provenance GitHub stored for it.
