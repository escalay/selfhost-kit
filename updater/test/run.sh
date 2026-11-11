#!/usr/bin/env bash
# The updater end to end, against real Docker: a compose project with a stand-in app, a local registry and a folder
# of releases. One update that works, one whose new version never comes up (the old version, compose file and data
# must be back), and the requests that must be refused without touching anything. Only cosign is replaced.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
registry=updater-test-registry
export COMPOSE_PROJECT_NAME=updater-test
cleanup() {
  (cd "$work" && docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  docker rm -f "$registry" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; (cd "$work" && docker compose logs --tail 40 updater app >&2) || true; exit 1; }
pass() { echo "ok: $*"; }

docker build -q -t updater:base "$here/.." >/dev/null
docker build -q -t updater:test --build-arg UPDATER=updater:base "$here" >/dev/null
docker rm -f "$registry" >/dev/null 2>&1 || true
docker run -d --name "$registry" -p 127.0.0.1:5599:5000 registry:2 >/dev/null
for _ in $(seq 1 30); do curl -fsS -o /dev/null http://localhost:5599/v2/ && break; sleep 1; done

cp "$here/docker-compose.yml" "$work/docker-compose.yml"
echo "MARK=kept" > "$work/.env"
mkdir -p "$work/releases"

# release VERSION UPGRADE_FROM [BROKEN]: builds and pushes the app, and writes the release's files
release() {
  local version=$1 from=$2 broken=${3:-} dir="$work/releases/v$1" digest
  docker build -q -t "localhost:5599/app:$version" --build-arg VERSION="$version" --build-arg BROKEN="$broken" "$here/app" >/dev/null
  digest=$(docker push -q "localhost:5599/app:$version" | sed 's/.*@//; s/.*\(sha256:[0-9a-f]*\).*/\1/')
  case "$digest" in sha256:*) ;; *) digest=$(docker image inspect "localhost:5599/app:$version" --format '{{ index .RepoDigests 0 }}' | sed 's/.*@//') ;; esac
  mkdir -p "$dir"
  sed "s|app:1.0.0}|app:$version}|; s|image: updater:test|image: ${4:-updater:test}|; s|sleep 1000000|sleep 1${version//./}|" "$here/docker-compose.yml" > "$dir/docker-compose.yml"
  jq -n --arg v "$version" --arg from "$from" --arg image "localhost:5599/app@$digest" \
    --arg sha "$(shasum -a 256 "$dir/docker-compose.yml" | cut -d' ' -f1)" \
    '{version: $v, upgradeFrom: $from, image: $image, compose: {file: "docker-compose.yml", sha256: $sha}}' > "$dir/release.json"
  echo '{}' > "$dir/app.intoto.jsonl"
  docker rmi -f "localhost:5599/app:$version" >/dev/null 2>&1 || true
}
release 1.0.0 1.0.0
release 1.1.0 1.0.0
release 1.2.0 1.0.0 yes
release 1.3.0 1.0.0
release 2.0.0 1.5.0
release 1.3.5 1.0.0 yes
docker tag updater:test localhost:5599/updater:2 && docker push -q localhost:5599/updater:2 >/dev/null
release 1.5.0 1.0.0 "" localhost:5599/updater:2
mkdir -p "$work/releases/v1.4.0" && cp "$work/releases/v1.3.0/"* "$work/releases/v1.4.0/"
jq '.version = "1.4.0"' "$work/releases/v1.3.0/release.json" > "$work/releases/v1.4.0/release.json"
echo "# changed after signing" >> "$work/releases/v1.4.0/docker-compose.yml"

cd "$work"
in_app() { docker compose exec -T app sh -c "$1"; }
in_updater() { docker compose exec -T updater sh -c "$1"; }
health() { in_updater 'curl -fsS --max-time 3 http://app/api/health 2>/dev/null | jq -r .version' 2>/dev/null || true; }
state() { in_updater 'jq -r .state /state/updates/status.json 2>/dev/null' 2>/dev/null || true; }
detail() { in_updater 'jq -r .detail /state/updates/status.json'; }
# request VERSION: what the app does when its owner clicks Update
request() {
  id="req-$RANDOM"
  in_updater "jq -n --arg id '$id' --arg v '$1' '{id: \$id, version: \$v, at: \"now\"}' > /state/updates/request.json"
}
# finished: waits for the run of the last request to end
finished() {
  for _ in $(seq 1 120); do
    if [ "$(in_updater 'jq -r .id /state/updates/status.json 2>/dev/null' 2>/dev/null)" = "$id" ]; then
      case "$(state)" in done | failed | refused) return 0 ;; esac
    fi
    sleep 1
  done
  fail "the request never finished (status: $(in_updater 'cat /state/updates/status.json' 2>&1))"
}
ask() { request "$1" && finished; }
pinned() { grep -o 'app:[0-9.]*}' docker-compose.yml; }

docker compose --profile side up -d >/dev/null 2>"$work/up.log" || fail "the project did not start: $(cat "$work/up.log")"
for _ in $(seq 1 30); do [ "$(health)" = 1.0.0 ] && break; sleep 1; done
[ "$(health)" = 1.0.0 ] || fail "the app never started"
for _ in $(seq 1 20); do in_updater 'test -f /state/updates/updater.json' 2>/dev/null && break; sleep 1; done
in_updater 'jq -e ".at and .version" /state/updates/updater.json >/dev/null' || fail "the updater doesn't say it is there"
pass "the project is up on 1.0.0 and the updater says it is there"

ask 1.1.0
[ "$(state)" = done ] || fail "1.0.0 → 1.1.0 ended as $(state): $(detail)"
[ "$(health)" = 1.1.0 ] || fail "after the update the app answers $(health)"
[ "$(pinned)" = 'app:1.1.0}' ] || fail "the compose file is pinned to $(pinned)"
[ "$(docker inspect updater-test-side-1 --format '{{ .State.Running }} {{ join .Config.Cmd " " }}')" = "true sleep 1110" ] \
  || fail "the service behind a profile wasn't moved to the new release ($(docker inspect updater-test-side-1 --format '{{ .State.Running }} {{ join .Config.Cmd " " }}' 2>&1))"
[ "$(cat .env)" = "MARK=kept" ] || fail ".env was changed"
[ "$(ls -ln docker-compose.yml | awk '{print $3}')" = "$(id -u)" ] || fail "the compose file no longer belongs to its owner"
[ "$(in_app 'echo $MARK')" = kept ] || fail "the new container lost the .env settings"
in_updater 'grep -q verify-blob-attestation /state/cosign.calls && grep -q "^verify localhost:5599/app@sha256:" /state/cosign.calls' || fail "the release file or the image wasn't verified"
in_updater 'test ! -d /state/updates/rollback' || fail "the rollback copies were left behind"
pass "1.0.0 → 1.1.0: verified, started by its digest, .env and its owner kept, the service behind a profile moved too"

in_app 'echo "written before the bad update" >> /state/state.sqlite'
before=$(in_app 'cat /state/state.sqlite')
ask 1.2.0
[ "$(state)" = failed ] || fail "the broken 1.2.0 ended as $(state): $(detail)"
[ "$(health)" = 1.1.0 ] || fail "after the rollback the app answers $(health)"
[ "$(pinned)" = 'app:1.1.0}' ] || fail "after the rollback the compose file is pinned to $(pinned)"
after=$(in_app 'grep -v "^migrated by 1.1.0$" /state/state.sqlite | cat; true')
in_app '! grep -q "migrated by 1.2.0" /state/state.sqlite' || fail "the data still carries the failed version's migration"
in_app 'grep -q "written before the bad update" /state/state.sqlite' || fail "the data from before the update is gone"
in_app 'test ! -f /state/backups/before-1.2.0.sqlite' || fail "the used backup was left for the next try to restore"
[ "$(docker inspect updater-test-side-1 --format '{{ .State.Running }} {{ join .Config.Cmd " " }}')" = "true sleep 1110" ] || fail "the service behind a profile wasn't put back"
[ "$(in_app 'cat /state/version')" = 1.1.0 ] || fail "the version file says $(in_app 'cat /state/version')"
pass "1.1.0 → broken 1.2.0: rolled back to 1.1.0 with the old compose file and data ($(detail))"

refused() { # VERSION WHY
  ask "$1"
  [ "$(state)" = refused ] || fail "$2: ended as $(state), not refused: $(detail)"
  [ "$(health)" = 1.1.0 ] || fail "$2: the app now answers $(health)"
  [ "$(pinned)" = 'app:1.1.0}' ] || fail "$2: the compose file changed"
  pass "refused, $2: $(detail)"
}
refused 1.0.0 "an older version"
refused '1.9.0; touch /state/pwned' "a version that isn't one"
in_updater 'test ! -f /state/pwned' || fail "a request ran a command"
refused 2.0.0 "a release this version can't reach directly"
refused 1.4.0 "a compose file changed after signing"
refused 1.7.0 "a release that doesn't exist"
in_updater "jq -n '{id: \"old\", version: \"1.3.0\"}' > /state/updates/request.json && touch -d '2020-01-01 00:00:00' /state/updates/request.json"
id=old; finished
[ "$(state)" = refused ] && [ "$(health)" = 1.1.0 ] || fail "a request from long ago ended as $(state): $(detail)"
pass "refused, a request that waited too long: $(detail)"
in_updater 'touch /state/cosign.refuse'
refused 1.3.0 "a bad signature"
in_updater 'rm /state/cosign.refuse'

ask 1.3.0
[ "$(state)" = done ] && [ "$(health)" = 1.3.0 ] || fail "1.1.0 → 1.3.0 ended as $(state): $(detail)"
pass "1.1.0 → 1.3.0 after the refusals"

# The updater stopped in the middle: at its next start it finishes the run one way or the other
request 1.3.5
for _ in $(seq 1 60); do in_updater 'jq -r .step /state/updates/status.json' 2>/dev/null | grep -q '^waiting' && break; sleep 1; done
docker compose kill updater >/dev/null 2>&1
docker compose start updater >/dev/null 2>&1
finished
[ "$(state)" = failed ] || fail "the interrupted update ended as $(state): $(detail)"
[ "$(health)" = 1.3.0 ] || fail "after the interrupted update the app answers $(health)"
[ "$(pinned)" = 'app:1.3.0}' ] || fail "after the interrupted update the compose file is pinned to $(pinned)"
pass "an update interrupted by stopping the updater: rolled back at its next start ($(detail))"

# A release whose compose file names a newer updater: a helper container replaces the running one
ask 1.5.0
[ "$(state)" = done ] && [ "$(health)" = 1.5.0 ] || fail "1.3.0 → 1.5.0 ended as $(state): $(detail)"
for _ in $(seq 1 40); do
  [ "$(docker inspect updater-test-updater-1 --format '{{ .Config.Image }}' 2>/dev/null)" = localhost:5599/updater:2 ] && break
  sleep 1
done
[ "$(docker inspect updater-test-updater-1 --format '{{ .Config.Image }}')" = localhost:5599/updater:2 ] || fail "the updater wasn't replaced by the one the new release names"
sleep 3
in_updater 'jq -e .at /state/updates/updater.json >/dev/null' || fail "the new updater isn't running"
[ "$(in_updater 'wc -l < /state/updates/history.jsonl' | tr -d ' ')" = 12 ] || fail "the history has $(in_updater 'wc -l < /state/updates/history.jsonl') runs, not 12"
pass "1.3.0 → 1.5.0: the updater handed over to the newer one, and all 12 runs are in the history"
echo "updater: all good"
