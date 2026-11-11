#!/usr/bin/env bash
# The updater against a real release, with nothing replaced: the example app (example/) starts at a version built
# here, and is updated to a release this repository published. The release file's attestation, the image's digest and
# signature and the compose file's hash are all checked by the real cosign against the real signatures. Then the same
# request with the wrong signer expected, which must be refused. Needs the network.
#
#   updater/test/real.sh                 the latest release, with the updater image that release pins
#   updater/test/real.sh 1.0.2 DIR       version 1.0.2 with its release files served from DIR (before it is published)
# UPDATER_UNDER_TEST names another updater image.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
example="$here/../../example"
to="${1:-$(git ls-remote --tags --refs https://github.com/escalay/selfhost-kit.git 'v*' | sed 's|.*refs/tags/v||' | sort -V | tail -n 1)}"
files="${2:-}"
work="$(mktemp -d)"
export COMPOSE_PROJECT_NAME=updater-real
cleanup() { (cd "$work" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; (cd "$work" && docker compose logs --tail 40 updater app >&2) || true; exit 1; }

# The version to update from exists only on this machine; only what is installed has to be signed
docker buildx build --builder "$(docker context show)" --load -q -t ghcr.io/escalay/updater-example:0.0.1 \
  --build-arg VERSION=0.0.1 "$example/app" >/dev/null

# start SIGNING_WORKFLOW: a fresh project on 0.0.1 whose updater expects releases signed by that workflow
start() {
  (cd "$work" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  sed 's|updater-example:[0-9.]*}|updater-example:0.0.1}|' "$example/docker-compose.yml" > "$work/docker-compose.yml"
  {
    echo "services:"
    echo "  updater:"
    [ -z "${UPDATER_UNDER_TEST:-}" ] || echo "    image: $UPDATER_UNDER_TEST"
    echo "    environment:"
    echo "      UPDATER_POLL: \"2\""
    echo "      UPDATER_TIMEOUT: \"60\""
    echo "      UPDATER_WORKFLOW: $1"
    if [ -n "$files" ]; then
      echo "      UPDATER_RELEASES: http://releases/releases"
      echo "  releases:"
      echo "    image: busybox:1.37"
      echo "    command: httpd -f -p 80 -h /www"
      echo "    volumes: [\"$files:/www/releases/v$to:ro\"]"
    fi
  } > "$work/docker-compose.override.yml"
  (cd "$work" && docker compose up -d >/dev/null 2>"$work/up.log") || fail "the project didn't start: $(cat "$work/up.log")"
  for _ in $(seq 1 30); do [ "$(health)" = 0.0.1 ] && return 0; sleep 1; done
  fail "the example never started"
}
in_updater() { (cd "$work" && docker compose exec -T updater sh -c "$1"); }
health() { in_updater 'curl -fsS --max-time 3 http://app/api/health 2>/dev/null | jq -r .version' 2>/dev/null || true; }
state() { in_updater 'jq -r .state /state/updates/status.json 2>/dev/null' 2>/dev/null || true; }
detail() { in_updater 'jq -r .detail /state/updates/status.json'; }
ask() {
  in_updater "jq -n --arg v '$to' '{id: \"real\", version: \$v, at: \"now\"}' > /state/updates/request.json"
  for _ in $(seq 1 180); do
    case "$(state)" in done | failed | refused) return 0 ;; esac
    sleep 1
  done
  fail "the request never finished: $(in_updater 'cat /state/updates/status.json' 2>&1)"
}

start release.yml
ask
[ "$(state)" = done ] || fail "0.0.1 → $to ended as $(state): $(detail)"
[ "$(health)" = "$to" ] || fail "after the update the example answers $(health)"
grep -q "updater-example:$to}" "$work/docker-compose.yml" || fail "the compose file isn't release $to's"
echo "ok: 0.0.1 → $to, every signature checked for real"

start another.yml
ask
[ "$(state)" = refused ] || fail "with the wrong signer expected it ended as $(state): $(detail)"
[ "$(health)" = 0.0.1 ] || fail "a refused update changed what runs ($(health))"
echo "ok: refused when another workflow should have signed it: $(detail)"
echo "real: all good"
