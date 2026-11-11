#!/usr/bin/env bash
# The updater's own cosign, with the flags updater.sh passes, against signatures that are really published: a signed
# image and a signed release file must verify, and another signer or a changed file must not. run.sh replaces cosign,
# so this is what catches a cosign too old (or too new) for the signatures release workflows make. Needs the network.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
image="${UPDATER_UNDER_TEST:-updater:signatures}"
[ -n "${UPDATER_UNDER_TEST:-}" ] || docker build -q -t "$image" "$here/.." >/dev/null
issuer=https://token.actions.githubusercontent.com
signer() { echo "https://github.com/$1/.github/workflows/release.yml@refs/heads/main"; }
cosign() { docker run --rm -v "$work:/work" -w /work --entrypoint cosign "$image" "$@" >/dev/null 2>&1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# An image signed by a release workflow, as `verify` checks one
signed=ghcr.io/escalay/updater:1.0.0
cosign verify "$signed" --certificate-identity "$(signer escalay/selfhost-kit)" --certificate-oidc-issuer "$issuer" \
  || fail "a signed image didn't verify"
cosign verify "$signed" --certificate-identity "$(signer escalay/yardhand)" --certificate-oidc-issuer "$issuer" \
  && fail "an image verified against another repository's workflow"
echo "ok: a signed image verifies, and only for its own release workflow"

# A release file with its attestation, as `verify-blob-attestation` checks one
release=https://github.com/escalay/yardhand/releases/download/v0.2.0
curl -fsSL -o "$work/file" "$release/docker-compose.yml"
curl -fsSL "$release/yardhand.intoto.jsonl" | head -n 1 > "$work/bundle.json"
attested() {
  cosign verify-blob-attestation --bundle bundle.json --new-bundle-format --type slsaprovenance1 \
    --certificate-identity "$(signer "$1")" --certificate-oidc-issuer "$issuer" file
}
attested escalay/yardhand || fail "a signed release file didn't verify"
attested escalay/selfhost-kit && fail "a release file verified against another repository's workflow"
echo "changed" >> "$work/file"
attested escalay/yardhand && fail "a changed release file still verified"
echo "ok: a signed release file verifies, and not once it is changed"
echo "signatures: all good"
