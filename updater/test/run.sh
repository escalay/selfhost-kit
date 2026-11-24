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
  # What the updater keeps in the project folder belongs to root when a run was cut short
  docker run --rm -v "$work:/project" busybox:1.37 rm -rf /project/.updater /project/linked >/dev/null 2>&1 || true
  docker rm -f "$registry" updater-test-swap updater-test-inside >/dev/null 2>&1 || true
  docker volume rm updater-test-inside >/dev/null 2>&1 || true
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
  docker build -q -t "localhost:5599/app:$version" --build-arg VERSION="$version" --build-arg BROKEN="$broken" "$here/../../example/app" >/dev/null
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
release 1.3.6 1.0.0 yes
release 1.3.7 1.0.0 yes
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
[ ! -e .updater ] || fail "what the updater kept for the run was left in the project folder"
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

side() { docker inspect updater-test-side-1 --format '{{ .State.Running }} {{ join .Config.Cmd " " }}' 2>&1; }
runs() { in_updater 'wc -l < /state/updates/history.jsonl' | tr -d ' '; }
in_volume() { docker run --rm -i -v updater-test_state:/state busybox:1.37 sh -c "$1"; }
in_folder() { docker run --rm -i -v "$work:/project" busybox:1.37 sh -c "$1"; }
reached() { # STEP: waits for the run of the last request to reach that step
  for _ in $(seq 1 60); do in_updater 'jq -r .step /state/updates/status.json' 2>/dev/null | grep -q "^$1" && return 0; sleep 1; done
  fail "the run never reached '$1' (status: $(in_updater 'cat /state/updates/status.json' 2>&1))"
}
# plant: a copy to roll back to in the state volume, as updaters before 1.2.1 kept one, with an older pin and another
# command
plant() {
  sed 's|app:[0-9.]*}|app:1.1.0}|; s|sleep [0-9]*|sleep 666|' docker-compose.yml \
    | in_volume 'mkdir -p /state/updates/rollback && cat > /state/updates/rollback/docker-compose.yml && echo "app side" > /state/updates/rollback/services'
}
untouched() { # WHY: the app, its compose file and the service behind a profile are still 1.3.0's
  [ "$(health)" = 1.3.0 ] || fail "$1: the app answers $(health)"
  [ "$(pinned)" = 'app:1.3.0}' ] || fail "$1: the compose file is pinned to $(pinned)"
  [ "$(side)" = "true sleep 1130" ] || fail "$1: the service behind a profile is now $(side)"
}

# A copy planted in the state volume while an update runs is never what its rollback starts, and links left in the
# state volume to files in the project folder are replaced, never written through, appended to or read
for one in status tmp history version; do echo "the owner's $one" > "link-$one"; done
in_volume 'cd /state/updates && mv history.jsonl history.real && ln -sf /project/link-status status.json \
  && ln -sf /project/link-tmp status.json.tmp && ln -sf /project/link-history history.jsonl \
  && cd /state && ln -sf /project/link-version version'
request 1.3.6
reached waiting
plant
finished
[ "$(state)" = failed ] || fail "the broken 1.3.6 ended as $(state): $(detail)"
untouched "after a rollback with a copy planted in the state volume"
for one in status tmp history version; do
  [ "$(cat "link-$one")" = "the owner's $one" ] || fail "a link in the state volume was written through to link-$one: $(cat "link-$one")"
done
in_volume '[ ! -L /state/updates/status.json ] && [ ! -L /state/version ]' || fail "the links to status.json or version were left in place"
in_volume 'cd /state/updates && rm -rf rollback status.json.tmp history.jsonl && mv history.real history.jsonl'
rm -f link-status link-tmp link-history link-version
pass "a copy planted in the state volume during an update: the rollback used its own copy, and links there were left unwritten ($(detail))"

# A run left as working with a copy in the state volume, as an updater before 1.2.1 would leave it or the app could
# plant it: never rolled back to, removed and reported once
before=$(runs)
docker compose stop updater >/dev/null 2>&1
plant
in_volume 'rm -f /state/updates/updater.json; printf "%s" "{\"id\":\"planted\",\"state\":\"working\",\"step\":\"waiting for 1.9.9 to answer\",\"from\":\"1.3.0\",\"to\":\"1.9.9\",\"startedAt\":\"2026-01-01T00:00:00Z\"}" > /state/updates/status.json'
docker compose start updater >/dev/null 2>&1
for _ in $(seq 1 90); do in_updater 'test -f /state/updates/updater.json' 2>/dev/null && break; sleep 1; done
in_updater 'test -f /state/updates/updater.json' || fail "the updater didn't come back"
untouched "after a start with a copy in the state volume"
in_updater 'test ! -e /state/updates/rollback' || fail "the copy in the state volume was left there"
[ "$(state)" = failed ] && [ "$(runs)" = $((before + 1)) ] || fail "the copy in the state volume wasn't reported: $(state), $(runs) runs"
reported=$(detail)
in_volume 'rm -f /state/updates/updater.json'
docker compose restart updater >/dev/null 2>&1
for _ in $(seq 1 30); do in_updater 'test -f /state/updates/updater.json' 2>/dev/null && break; sleep 1; done
[ "$(runs)" = $((before + 1)) ] || fail "the copy in the state volume was reported again"
pass "a copy left in the state volume at start: not used, removed, reported once ($reported)"

# The updates folder made a link into the project folder: nothing is written or removed there, and the updater runs on
mkdir -p linked/rollback && echo "the owner's" > linked/status.json && echo "the owner's" > linked/rollback/kept
docker compose stop updater >/dev/null 2>&1
in_volume 'mv /state/updates /state/updates.real && ln -s /project/linked /state/updates'
docker compose start updater >/dev/null 2>&1
sleep 6
[ "$(docker inspect updater-test-updater-1 --format '{{ .State.Status }} {{ .RestartCount }}')" = "running 0" ] \
  || fail "the updater didn't keep running with a linked updates folder"
[ "$(find linked | sort | tr '\n' ' ')" = "linked linked/rollback linked/rollback/kept linked/status.json " ] \
  || fail "the updater wrote or removed through a linked updates folder: $(find linked | sort | tr '\n' ' ')"
[ "$(cat linked/status.json)" = "the owner's" ] || fail "status.json was written through a linked updates folder"
logs=$(docker compose logs updater 2>&1)
grep -q 'left /state/updates/updater.json as it was' <<<"$logs" || fail "the refused writes weren't logged"
docker compose stop updater >/dev/null 2>&1
in_volume 'rm /state/updates && mv /state/updates.real /state/updates && rm -f /state/updates/updater.json'
docker compose start updater >/dev/null 2>&1
for _ in $(seq 1 30); do in_updater 'test -f /state/updates/updater.json' 2>/dev/null && break; sleep 1; done
in_updater 'test -f /state/updates/updater.json' || fail "the updater didn't come back with its updates folder"
pass "an updates folder made a link into the project folder: nothing written or removed there, refusals logged"

# A copy left in the state volume by an earlier updater is removed without walking into it: what else is in it is
# moved aside, so a folder in it that turns into a link to the project folder while a walk would be inside it, with
# files named as the owner's are, leaves the owner's files alone
for i in $(seq 1 50); do echo "the owner's" > "owner-$i"; done
before=$(runs)
docker compose stop updater >/dev/null 2>&1
plant
in_volume 'mkdir /state/updates/rollback/sub && cd /state/updates/rollback/sub && i=0 && while [ $i -lt 20000 ]; do : > "f$i"; i=$((i + 1)); done && for i in $(seq 1 50); do : > "owner-$i"; done'
docker run -d --name updater-test-swap -v updater-test_state:/state busybox:1.37 sh -c \
  'cd /state/updates/rollback || exit; while [ "$(ls -A sub | wc -l)" -gt 20040 ]; do usleep 1000; done; mv sub sub.real && ln -s /project sub; sleep 1000' >/dev/null
in_volume 'rm -f /state/updates/updater.json'
docker compose start updater >/dev/null 2>&1
for _ in $(seq 1 30); do in_updater 'test -f /state/updates/updater.json' 2>/dev/null && break; sleep 1; done
docker rm -f updater-test-swap >/dev/null 2>&1
[ "$(cat owner-* 2>/dev/null | grep -c "the owner's")" = 50 ] && [ -d releases ] && [ "$(cat .env)" = "MARK=kept" ] \
  || fail "the owner's files were removed: $(ls -a | tr '\n' ' ')"
untouched "after removing a copy with a folder turning into a link"
in_updater 'test ! -e /state/updates/rollback && test -d /state/updates/rollback.left.*' || fail "the copy wasn't moved aside"
[ "$(state)" = failed ] && [ "$(runs)" = $((before + 1)) ] || fail "the copy wasn't reported: $(state), $(runs) runs"
pass "a copy with more in it, a folder turning into a link: removed without walking it, the rest moved aside ($(detail))"
in_volume 'rm -rf /state/updates/rollback*'
rm -f owner-*

# A request that isn't a plain file, a version over more than one line, an endless health answer: refused, and the
# updater keeps going
next_run() { # RUNS: waits for the history to pass that many runs
  for _ in $(seq 1 60); do [ "$(runs)" -gt "$1" ] && return 0; sleep 1; done
  fail "no run was recorded after $1 (status: $(in_updater 'cat /state/updates/status.json' 2>&1))"
}
echo '{"id":"elsewhere","version":"1.9.9"}' > elsewhere.json
before=$(runs)
in_volume 'ln -sf /project/elsewhere.json /state/updates/request.json'
next_run "$before"
[ "$(state)" = refused ] && [ "$(in_updater 'jq -r .id,.to /state/updates/status.json' | tr '\n' ' ')" = "none invalid " ] \
  || fail "a request that is a link was read through it: $(in_updater 'cat /state/updates/status.json')"
in_volume '[ ! -e /state/updates/request.json ] && [ ! -L /state/updates/request.json ]' || fail "the linked request was left"
[ "$(cat elsewhere.json)" = '{"id":"elsewhere","version":"1.9.9"}' ] || fail "the file the request linked to changed"
rm -f elsewhere.json
pass "refused, a request that is a link: $(detail)"
before=$(runs)
in_volume 'mkfifo /state/updates/request.json'
next_run "$before"
[ "$(state)" = refused ] && in_volume '[ ! -e /state/updates/request.json ]' || fail "a request that is a pipe: $(state), $(detail)"
pass "refused, a request that is a pipe: $(detail)"
before=$(runs)
in_volume 'mkdir -p /state/updates/request.json/inner && : > /state/updates/request.json/inner/x'
next_run "$before"
[ "$(state)" = refused ] && in_volume '[ ! -e /state/updates/request.json ]' || fail "a request that is a folder: $(state), $(detail)"
in_volume 'rm -rf /state/updates/request.left.*'
pass "refused, a request that is a folder: $(detail)"
id=multi
in_updater "jq -n '{id: \"multi\", version: \"1.9.0\\n1.9.0\"}' > /state/updates/request.json"
finished
[ "$(state)" = refused ] && [ "$(detail)" = "The request names no version (three numbers, like 1.2.3)." ] \
  || fail "a version over two lines ended as $(state): $(detail)"
pass "refused, a version over two lines: $(detail)"
in_app 'printf "{\"status\":\"ok\",\"version\":\"%s\"}" "$(yes 1 | tr -d "\n" | head -c 200000)" > /www/api/health'
restarts=$(docker inspect updater-test-updater-1 --format '{{ .RestartCount }}')
ask 1.9.0
[ "$(state)" = refused ] || fail "with an endless health answer the request ended as $(state): $(detail)"
[ "$(docker inspect updater-test-updater-1 --format '{{ .RestartCount }}')" = "$restarts" ] || fail "an endless health answer restarted the updater"
in_app 'printf "{\"status\":\"ok\",\"version\":\"1.3.0\"}" > /www/api/health'
[ "$(health)" = 1.3.0 ] || fail "the health answer wasn't put back"
pass "refused, an endless health answer: $(detail)"

# Settings that would have the updater work in the state volume: it refuses to start
out=$(docker run --rm -e UPDATER_REPO=example/app -e UPDATER_IMAGE=localhost:5599/app -e UPDATER_DATABASE=../outside.sqlite updater:test 2>&1) && code=0 || code=$?
[ "$code" = 78 ] && echo "$out" | grep -q UPDATER_DATABASE || fail "a database outside the state folder was taken ($code): $out"
docker run -d --name updater-test-inside -v updater-test-inside:/state -v "$work:/project" -v /var/run/docker.sock:/var/run/docker.sock \
  --label com.docker.compose.project=updater-inside --label com.docker.compose.service=updater \
  --label com.docker.compose.project.working_dir=/state/inside --label com.docker.compose.project.config_files=/state/inside/docker-compose.yml \
  -e UPDATER_REPO=example/app -e UPDATER_IMAGE=localhost:5599/app updater:test >/dev/null
for _ in $(seq 1 15); do [ "$(docker inspect updater-test-inside --format '{{ .State.Status }}')" = exited ] && break; sleep 1; done
[ "$(docker inspect updater-test-inside --format '{{ .State.Status }} {{ .State.ExitCode }}')" = "exited 78" ] \
  || fail "a project folder inside the state volume was taken: $(docker logs updater-test-inside 2>&1 | tail -n 3)"
docker rm -f updater-test-inside >/dev/null 2>&1; docker volume rm updater-test-inside >/dev/null 2>&1
pass "refused to start: a database outside the state folder, a project folder inside it"

# A kept copy in the project folder that changed after it was taken is refused, and nothing is put back from it
request 1.3.7
reached waiting
in_folder 'test -d /project/.updater && find /project/.updater -type f -exec sed -i "s|app:1.3.0}|app:1.1.0}|; s|sleep 1130|sleep 666|" {} +' \
  || fail "the updater kept nothing in the project folder"
finished
[ "$(state)" = failed ] || fail "the broken 1.3.7 with a changed copy ended as $(state): $(detail)"
[ "$(pinned)" = 'app:1.3.7}' ] || fail "a changed copy was put back: the compose file is pinned to $(pinned)"
[ "$(side)" != "true sleep 666" ] || fail "a changed copy was started"
pass "a kept copy changed during the update: refused ($(detail))"
# What the status says is left to do by hand
cp releases/v1.3.0/docker-compose.yml docker-compose.yml
docker compose --profile side up -d >/dev/null 2>&1 || fail "1.3.0 didn't start again by hand"
for _ in $(seq 1 30); do [ "$(health)" = 1.3.0 ] && break; sleep 1; done
untouched "after putting 1.3.0 back by hand"

# A release whose compose file names a newer updater: a helper container replaces the running one. The app answers its
# health check with more than 4 KiB, which is still a valid answer
in_app 'printf "{\"status\":\"ok\",\"version\":\"1.3.0\",\"note\":\"%s\"}" "$(yes x | tr -d "\n" | head -c 5000)" > /www/api/health'
[ "$(in_updater 'curl -fsS http://app/api/health | wc -c' | tr -d ' ')" -gt 5000 ] || fail "the long health answer wasn't served"
ask 1.5.0
[ "$(state)" = done ] && [ "$(health)" = 1.5.0 ] || fail "1.3.0 → 1.5.0 ended as $(state): $(detail)"
for _ in $(seq 1 40); do
  [ "$(docker inspect updater-test-updater-1 --format '{{ .Config.Image }}' 2>/dev/null)" = localhost:5599/updater:2 ] && break
  sleep 1
done
[ "$(docker inspect updater-test-updater-1 --format '{{ .Config.Image }}')" = localhost:5599/updater:2 ] || fail "the updater wasn't replaced by the one the new release names"
sleep 3
in_updater 'jq -e .at /state/updates/updater.json >/dev/null' || fail "the new updater isn't running"
# One run went unrecorded: its history was a link
[ "$(runs)" = 20 ] || fail "the history has $(runs) runs, not 20"
pass "1.3.0 → 1.5.0 from a 5 KB health answer: the updater handed over to the newer one, and all 20 recorded runs are in the history"
echo "updater: all good"
