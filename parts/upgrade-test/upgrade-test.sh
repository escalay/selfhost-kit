#!/usr/bin/env bash
# Updates end to end, as an owner gets them, from escalay/selfhost-kit (part "upgrade-test"). A published release
# runs from the compose file with data in it and is updated by the updater to the image under test, so its
# migrations meet data an older version wrote. Then a newer version is asked for; then one that dies after migrating,
# and the old version, compose file and data must be back. The newer versions are the image under test under another
# number, pushed to a registry on this machine; only the signature check is replaced, since nobody signed them.
#
#   APP_IMAGE       the image to test (required)
#   UPGRADE_FROM    start from this release only (default: every release from the oldest that updates in one step,
#                   a first leg each, then the full run from the last)
#   UPGRADE_LEGS    `first` stops after the update from the published release
#   UPGRADE_OLDER   `skip` leaves the older releases to someone else (CI runs each as its own job)
#   HOOKS           what only your product knows (default: scripts/upgrade-test.hooks.sh): where it is published,
#                   how to make it another version, how to put data in and find it again
set -euo pipefail
: "${APP_IMAGE:?set APP_IMAGE to the image to test}"
root="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# shellcheck source=/dev/null
. "${HOOKS:-$root/scripts/upgrade-test.hooks.sh}"
: "${PUBLISHED:?the hooks name the image releases are published as}" "${COMPOSE_FILE:?}" "${TAGS:?}"
service="${SERVICE:-app}"
work="$(mktemp -d)"
registry=upgrade-test-registry
repo=localhost:5598/app
export COMPOSE_PROJECT_NAME=upgrade-test
under_test="$APP_IMAGE"
unset APP_IMAGE
updater_image=$(sed -n 's/^ *image: \(ghcr.io\/escalay\/updater:[^ ]*\).*$/\1/p' "$COMPOSE_FILE")

# The releases that are out, oldest first: asked of the tags, since on a release's own pull request the version in
# this tree is one that isn't published yet
published=$(git ls-remote --tags --refs "$TAGS" 'v*' | sed 's|.*refs/tags/v||' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)
least="${OLDEST:-$(jq -r .upgradeFrom "$(dirname "$COMPOSE_FILE")/../release.json" 2>/dev/null || echo 0.0.0)}"
published=$(echo "$published" | awk -v least="$least" '
  function key(v, p) { split(v, p, "."); return p[1] * 1000000 + p[2] * 1000 + p[3] }
  key($0) >= key(least)')
last=$(echo "$published" | tail -n 1)
[ -n "$last" ] || { echo "upgrade: no published release to start from" >&2; exit 1; }
if [ -z "${UPGRADE_FROM:-}" ] && [ "${UPGRADE_OLDER:-run}" = run ]; then
  for older in $(echo "$published" | sed '$d'); do
    APP_IMAGE="$under_test" UPGRADE_FROM="$older" UPGRADE_LEGS=first bash "$0"
  done
fi
from="${UPGRADE_FROM:-$last}"

cleanup() {
  (cd "$work" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  docker rm -f "$registry" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "upgrade: $*" >&2; (cd "$work" && docker compose logs --tail 60 "$service" updater >&2) || true; exit 1; }

docker rm -f "$registry" >/dev/null 2>&1 || true
docker run -d --name "$registry" -p 127.0.0.1:5598:5000 registry:2 >/dev/null
for _ in $(seq 1 30); do curl -fsS -o /dev/null http://localhost:5598/v2/ && break; sleep 1; done

# Docker's own builder, named after the context: one in a container (CI's) sees no local image
build() { docker buildx build --builder "$(docker context show)" --load -q "$@" >/dev/null; }
# The updater as released, with cosign saying yes
mkdir "$work/updater" "$work/releases"
printf '#!/bin/sh\nexit 0\n' > "$work/updater/cosign"
printf 'FROM %s\nCOPY --chmod=755 cosign /usr/local/bin/cosign\n' "${UPDATER_BASE:-$updater_image}" > "$work/updater/Dockerfile"
build -t upgrade-test-updater "$work/updater"

published_escaped=$(printf '%s' "$PUBLISHED" | sed 's/[.[\*^$/]/\\&/g')
compose_for() { sed "s|$published_escaped:[0-9.]*|$repo:$1|" "$COMPOSE_FILE"; }
# release VERSION [BROKEN]: the image under test as VERSION, and its release files
release() {
  local version=$1 dir="$work/releases/v$1" digest
  dockerfile_for "$under_test" "$version" "${2:-}" | build -t "$repo:$version" -
  docker push -q "$repo:$version" >/dev/null
  digest=$(docker image inspect "$repo:$version" --format '{{ index .RepoDigests 0 }}' | sed 's/.*@//')
  mkdir -p "$dir"
  compose_for "$version" > "$dir/$(basename "$COMPOSE_FILE")"
  jq -n --arg v "$version" --arg from "$least" --arg image "$repo@$digest" --arg file "$(basename "$COMPOSE_FILE")" \
    --arg sha "$(shasum -a 256 "$dir/$(basename "$COMPOSE_FILE")" | cut -d' ' -f1)" \
    '{version: $v, upgradeFrom: $from, image: $image, compose: {file: $file, sha256: $sha}}' > "$dir/release.json"
  echo '{}' > "$dir/${PROVENANCE:-app.intoto.jsonl}"
  docker rmi -f "$repo:$version" >/dev/null 2>&1 || true
}
docker pull -q "$PUBLISHED:$from" >/dev/null || fail "release $from, the one to update from, couldn't be pulled"
docker tag "$PUBLISHED:$from" "$repo:$from" && docker push -q "$repo:$from" >/dev/null
release 98.0.0
if [ "${UPGRADE_LEGS:-all}" = all ]; then
  release 98.1.0
  release 98.2.0 broken
fi

compose_for "$from" > "$work/$(basename "$COMPOSE_FILE")"
# Every setting is in .env: the updater starts the new version from this folder, not from this shell
printf '%s\n' "${ENV_LINES:-}" > "$work/.env"
# The owner's own compose file beside the release's: the updater keeps it through an update
cat > "$work/docker-compose.override.yml" <<YAML
services:
  updater:
    image: upgrade-test-updater
    environment:
      UPDATER_IMAGE: $repo
      UPDATER_RELEASES: http://releases/releases
      UPDATER_TIMEOUT: "60"
      UPDATER_POLL: "2"
  releases:
    image: busybox:1.37
    command: httpd -f -p 80 -h /www
    volumes:
      - ./releases:/www/releases:ro
YAML
cd "$work"
compose() { docker compose -f "$(basename "$COMPOSE_FILE")" -f docker-compose.override.yml "$@"; }
compose up -d >/dev/null 2>"$work/up.log" || fail "the project didn't start: $(cat "$work/up.log")"
in_updater() { compose exec -T updater sh -c "$1"; }
version() { in_updater "curl -fsS --max-time 3 ${HEALTH_URL:-http://$service/api/health} 2>/dev/null | jq -r .version" 2>/dev/null || true; }
for _ in $(seq 1 60); do [ "$(version)" = "$from" ] && break; sleep 1; done
[ "$(version)" = "$from" ] || fail "release $from never answered as healthy"
seed "$from"

# ask VERSION: a request left the way the app leaves one; waits for the run to end
ask() {
  # The updater keeps only letters, digits and dashes of a request's id
  local id="to-${1//./-}-$RANDOM"
  in_updater "jq -n '{id: \"$id\", version: \"$1\", at: \"now\"}' > /state/updates/request.json"
  for _ in $(seq 1 180); do
    if [ "$(in_updater 'jq -r .id /state/updates/status.json 2>/dev/null' 2>/dev/null)" = "$id" ]; then
      case "$(state)" in 'done' | failed | refused) return 0 ;; esac
    fi
    sleep 1
  done
  fail "the update to $1 never finished: $(in_updater 'cat /state/updates/status.json' 2>&1)"
}
state() { in_updater 'jq -r .state /state/updates/status.json 2>/dev/null' 2>/dev/null || true; }
detail() { in_updater 'jq -r .detail /state/updates/status.json'; }
pinned() { grep -q "$repo:$1" "$(basename "$COMPOSE_FILE")"; }
# shellcheck disable=SC2012
mine() { [ "$(ls -ln "$(basename "$COMPOSE_FILE")" | awk '{print $3}')" = "$(id -u)" ] || fail "the compose file no longer belongs to its owner"; }

ask 98.0.0
[ "$(state)" = 'done' ] || fail "release $from → this build ended as $(state): $(detail)"
[ "$(version)" = 98.0.0 ] || fail "after the update from $from it answers $(version)"
pinned 98.0.0 || fail "the compose file isn't the new release's"
mine
kept "$from" || fail "the data written on $from is gone"
echo "upgrade: release $from → this build: its data is there"
[ "${UPGRADE_LEGS:-all}" = all ] || exit 0

ask 98.1.0
[ "$(state)" = 'done' ] && [ "$(version)" = 98.1.0 ] || fail "98.0.0 → 98.1.0 ended as $(state): $(detail)"
echo "upgrade: 98.0.0 → 98.1.0"

seed 98.1.0
ask 98.2.0
[ "$(state)" = failed ] || fail "the broken 98.2.0 ended as $(state): $(detail)"
[ "$(version)" = 98.1.0 ] || fail "after the rollback it answers $(version)"
pinned 98.1.0 || fail "after the rollback the compose file isn't the old one"
mine
untouched_by 98.2.0 || fail "the data still carries what the failed version wrote"
kept 98.1.0 || fail "the data from before the failed update is gone"
echo "upgrade: 98.1.0 → a 98.2.0 that dies after migrating: rolled back ($(detail))"
