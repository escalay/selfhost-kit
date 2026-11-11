#!/bin/sh
# The updater: carries out an update the app asked for, and puts the old version back when the new one doesn't come up.
# It runs beside the app in the same compose project with the Docker socket, so the app itself needs no access to
# Docker. The app writes a request beside its data; this verifies the release, starts it, waits for it to answer with
# the new version, and otherwise restores the old compose file, image and data. README.md has the whole contract.
#
# The request is a hint from a less trusted place: only a version number is read from it. Where releases and images
# come from, and who must have signed them, are this container's own settings.
set -eu

: "${UPDATER_REPO:?the GitHub repository whose releases are installed, as owner/name}"
: "${UPDATER_IMAGE:?the image the releases are published as, without a tag}"
SERVICE="${UPDATER_SERVICE:-app}"
HEALTH_URL="${UPDATER_HEALTH_URL:-http://$SERVICE/api/health}"
STATE="${UPDATER_STATE:-/state}"
DATABASE="${UPDATER_DATABASE:-state.sqlite}"
RELEASES="${UPDATER_RELEASES:-https://github.com/$UPDATER_REPO/releases/download}"
PROVENANCE="${UPDATER_PROVENANCE:-${UPDATER_REPO##*/}.intoto.jsonl}"
SIGNER="https://github.com/$UPDATER_REPO/.github/workflows/${UPDATER_WORKFLOW:-release.yml}@refs/heads/main"
OWN_SIGNER="https://github.com/${UPDATER_OWN_REPO:-escalay/selfhost-kit}/.github/workflows/release.yml@refs/heads/main"
ISSUER=https://token.actions.githubusercontent.com
TIMEOUT="${UPDATER_TIMEOUT:-180}"
POLL="${UPDATER_POLL:-10}"
# Minutes a request stays good: an updater that comes back days later doesn't install what was asked for then
FRESH="${UPDATER_FRESH:-60}"
VERSION="${UPDATER_VERSION:-dev}"
PROJECT_MOUNT=/project
DIR="$STATE/updates"
KEPT="$DIR/rollback"
WORK=/tmp/update

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { echo "updater: $*"; }
semver() { echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; }
# newer A B: A is a later version than B
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }
# put FILE: stdin becomes FILE in one step, so a reader never sees half of it
put() { cat > "$1.tmp" && mv "$1.tmp" "$1"; }

# status STATE STEP DETAIL: what the app shows its owner
status() {
  jq -n --arg id "$id" --arg state "$1" --arg step "$2" --arg from "$from" --arg to "$to" \
    --arg startedAt "$started" --arg at "$(now)" --arg detail "${3:-}" \
    '{id: $id, state: $state, step: $step, from: $from, to: $to, startedAt: $startedAt, at: $at,
      detail: (if $detail == "" then null else $detail end)}' | put "$DIR/status.json"
  say "$1: $2${3:+ ($3)}"
}
# finish STATE STEP DETAIL: the last status of a run, kept in the history
finish() {
  status "$@"
  jq -c . "$DIR/status.json" >> "$DIR/history.jsonl"
  rm -rf "$WORK" "$KEPT"
}

# The compose project this container belongs to, and its folder on the host. Compose reads files here and sends
# paths to Docker on the host, so the folder must have the same path in both places: a link gives it one.
project() {
  self=$(docker inspect "$(hostname)" --format '{{ json .Config.Labels }}')
  NAME=$(echo "$self" | jq -r '."com.docker.compose.project" // empty')
  HOST_DIR=$(echo "$self" | jq -r '."com.docker.compose.project.working_dir" // empty')
  OWN_SERVICE=$(echo "$self" | jq -r '."com.docker.compose.service" // empty')
  FILES=$(echo "$self" | jq -r '."com.docker.compose.project.config_files" // empty' | tr ',' '\n')
  [ -n "$NAME" ] && [ -n "$HOST_DIR" ] && [ -n "$FILES" ] || { say "this container isn't part of a compose project; it can't update anything"; exit 78; }
  # The first file is the release's and is replaced by each update; any after it are the owner's and are kept
  FILE=$(basename "$(echo "$FILES" | head -n 1)")
  [ -f "$PROJECT_MOUNT/$FILE" ] || { say "the project folder isn't mounted at $PROJECT_MOUNT (no $FILE there)"; exit 78; }
  if [ "$HOST_DIR" != "$PROJECT_MOUNT" ] && [ ! -e "$HOST_DIR" ]; then
    mkdir -p "$(dirname "$HOST_DIR")" && ln -s "$PROJECT_MOUNT" "$HOST_DIR"
  fi
}
# compose_with FIRST ARGS: compose over FIRST in the release file's place, then the owner's own files
compose_with() {
  first=$1; shift
  count=$(echo "$FILES" | wc -l)
  while [ "$count" -gt 1 ]; do
    set -- -f "$(echo "$FILES" | sed -n "${count}p")" "$@"
    count=$((count - 1))
  done
  docker compose --project-name "$NAME" --project-directory "$HOST_DIR" -f "$first" "$@"
}
compose() { compose_with "$HOST_DIR/$FILE" "$@"; }

running_version() { curl -fsS --max-time 5 "$HEALTH_URL" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true; }
# answers VERSION SECONDS: the app answers as healthy with that version before the time is up
answers() {
  waited=0
  while [ "$waited" -lt "$2" ]; do
    [ "$(running_version)" = "$1" ] && return 0
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}
# The services to start again: the ones running now that the compose file still has, never this one. Asked of Docker
# and with every profile on, so a part behind a profile (a proxy for HTTPS) moves to the new release too.
services() {
  docker ps --filter "label=com.docker.compose.project=$NAME" --format '{{ .Label "com.docker.compose.service" }}' \
    | sort -u | grep -vx "$OWN_SERVICE" | while read -r one; do
    compose --profile '*' config --services | grep -qx "$one" && echo "$one"
  done
}

fetch() { curl -fsSL --max-time 60 --retry 2 -o "$WORK/$1" "$RELEASES/v$to/$1"; }

# Everything that can be checked before the running app is touched. Says why not on stdout and fails.
verify() {
  mkdir -p "$WORK"
  if ! fetch release.json || ! fetch "$PROVENANCE"; then echo "Release $to has no release.json or $PROVENANCE at $RELEASES/v$to: it can't be installed from the app. Update by hand (the release notes say how)."; return 1; fi
  head -n 1 "$WORK/$PROVENANCE" > "$WORK/bundle.json"
  cosign verify-blob-attestation --bundle "$WORK/bundle.json" --new-bundle-format --type slsaprovenance1 \
    --certificate-identity "$SIGNER" --certificate-oidc-issuer "$ISSUER" "$WORK/release.json" > /dev/null 2>&1 \
    || { echo "The files of release $to aren't signed by $UPDATER_REPO's release workflow. Nothing was changed."; return 1; }
  [ "$(jq -r '.version // empty' "$WORK/release.json")" = "$to" ] \
    || { echo "The release file at v$to describes another version. Nothing was changed."; return 1; }
  least=$(jq -r '.upgradeFrom // empty' "$WORK/release.json")
  if semver "$least" && newer "$least" "$from"; then
    echo "$to can be reached directly only from $least or later, and this is $from. Update to $least first."; return 1
  fi
  image=$(jq -r '.image // empty' "$WORK/release.json")
  case "$image" in
    "$UPDATER_IMAGE"@sha256:*) ;;
    *) echo "Release $to names an image that isn't $UPDATER_IMAGE. Nothing was changed."; return 1 ;;
  esac
  file=$(jq -r '.compose.file // "docker-compose.yml"' "$WORK/release.json")
  [ "$file" = "$(basename "$file")" ] && fetch "$file" \
    && [ "$(sha256sum "$WORK/$file" | cut -d' ' -f1)" = "$(jq -r '.compose.sha256 // empty' "$WORK/release.json")" ] \
    || { echo "The compose file of release $to isn't the one its release file names. Nothing was changed."; return 1; }
  docker pull -q "$image" > /dev/null 2>&1 || { echo "The image of release $to couldn't be pulled ($image). Nothing was changed."; return 1; }
  cosign verify "$image" --certificate-identity "$SIGNER" --certificate-oidc-issuer "$ISSUER" > /dev/null 2>&1 \
    || { echo "The image of release $to isn't signed by $UPDATER_REPO's release workflow. Nothing was changed."; return 1; }
  docker tag "$image" "$UPDATER_IMAGE:$to" || { echo "The verified image of release $to couldn't be given its tag. Nothing was changed."; return 1; }
  docker image inspect "$image" --format '{{ .Id }}' > "$WORK/image.id" || { echo "The verified image of release $to isn't here after the pull. Nothing was changed."; return 1; }
  compose_with "$WORK/$file" config --quiet > /dev/null 2>&1 \
    || { echo "The compose file of release $to doesn't load with this folder's .env. Nothing was changed."; return 1; }
}

# Puts back what `start` replaced: the compose file, the version that last ran, and the data from before the
# update when the new version got as far as backing it up (the app takes a staged restore at its next start).
rollback() {
  status working 'putting the old version back' "$1"
  compose stop "$SERVICE" > /dev/null 2>&1 || true
  cat "$KEPT/$FILE" > "$HOST_DIR/$FILE"
  if [ -f "$STATE/backups/before-$to.sqlite" ]; then
    mv "$STATE/backups/before-$to.sqlite" "$STATE/restore.pending.sqlite"
    rm -f "$STATE/$DATABASE-wal" "$STATE/$DATABASE-shm"
  fi
  echo "$from" > "$STATE/version"
  # shellcheck disable=SC2046
  compose up -d $(cat "$KEPT/services") > /dev/null 2>&1 || true
  if answers "$from" "$TIMEOUT"; then
    finish failed 'rolled back' "$1 $from is running again with the data from before the update."
  else
    finish failed 'rolled back, but not answering' "$1 The old compose file and data were put back, but $from isn't answering either. Look at the log: docker compose logs $SERVICE."
  fi
}

# After a good update: when the new compose file names another updater image, a short-lived container of that
# image replaces this one, since a container can't recreate itself.
handover() {
  wanted=$(compose config --format json | jq -r --arg s "$OWN_SERVICE" '.services[$s].image // empty')
  mine=$(docker inspect "$(hostname)" --format '{{ .Config.Image }}')
  [ -n "$wanted" ] && [ "$wanted" != "$mine" ] || return 0
  docker pull -q "$wanted" > /dev/null 2>&1 || { say "the new updater image ($wanted) couldn't be pulled; this one keeps running"; return 0; }
  digest=$(docker image inspect "$wanted" --format '{{ index .RepoDigests 0 }}')
  cosign verify "$digest" --certificate-identity "$OWN_SIGNER" --certificate-oidc-issuer "$ISSUER" > /dev/null 2>&1 \
    || { say "the new updater image ($wanted) isn't signed by its release workflow; this one keeps running"; return 0; }
  say "handing over to $wanted"
  docker run -d --rm --name "$NAME-updater-handover" -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$HOST_DIR:$HOST_DIR" --entrypoint /bin/sh "$wanted" -c \
    "sleep 2; docker compose --project-name '$NAME' --project-directory '$HOST_DIR' $(echo "$FILES" | sed "s/.*/-f '&'/" | tr '\n' ' ') up -d '$OWN_SERVICE'" > /dev/null
}

update() {
  started=$(now)
  from=$(running_version)
  if ! semver "$to"; then to=invalid; finish refused 'checking the request' 'The request names no version (three numbers, like 1.2.3).'; return; fi
  if ! semver "$from"; then finish refused 'checking the request' "The app isn't answering at $HEALTH_URL, so it isn't safe to replace. Look at its log first: docker compose logs $SERVICE."; return; fi
  if ! newer "$to" "$from"; then finish refused 'checking the request' "$to isn't newer than the $from that is running."; return; fi

  status working "verifying release $to"
  why=$(verify) || { finish refused "verifying release $to" "$why"; return; }
  file=$(jq -r '.compose.file // "docker-compose.yml"' "$WORK/release.json")

  status working "starting $to"
  mkdir -p "$KEPT"
  cp "$HOST_DIR/$FILE" "$KEPT/$FILE"
  services | tr '\n' ' ' > "$KEPT/services"
  # A copy left by an earlier try at this version is older than the data now; the new version makes a fresh one
  rm -f "$STATE/backups/before-$to.sqlite"
  # Written through the file that is there, so it stays its owner's
  cat "$WORK/$file" > "$HOST_DIR/$FILE"
  # shellcheck disable=SC2046
  if ! out=$(compose up -d $(cat "$KEPT/services") 2>&1); then
    rollback "$to couldn't be started ($(echo "$out" | tail -n 1))."
    return
  fi
  # The tag the compose file names must still be the image that was verified
  started_as=$(docker inspect "$(compose ps -q "$SERVICE" | head -n 1)" --format '{{ .Image }}' 2>/dev/null || true)
  if [ "$started_as" != "$(cat "$WORK/image.id")" ]; then
    rollback "$to started from another image than the one that was verified."
    return
  fi
  status working "waiting for $to to answer"
  if answers "$to" "$TIMEOUT"; then
    finish 'done' "running $to"
    handover
  else
    rollback "$to didn't answer as healthy within $TIMEOUT seconds."
  fi
}

# A run cut short (the host restarted, this container was stopped) is finished one way or the other
recover() {
  [ -f "$DIR/status.json" ] && [ "$(jq -r .state "$DIR/status.json" 2>/dev/null)" = working ] || return 0
  id=$(jq -r .id "$DIR/status.json"); from=$(jq -r .from "$DIR/status.json")
  to=$(jq -r .to "$DIR/status.json"); started=$(jq -r .startedAt "$DIR/status.json")
  if [ ! -f "$KEPT/$FILE" ]; then finish refused 'interrupted' 'The updater stopped before it changed anything. Ask for the update again.'
  elif answers "$to" 30; then finish 'done' "running $to"
  else rollback 'The updater was stopped in the middle of the update.'; fi
}

mkdir -p "$DIR"
project
say "version $VERSION, watching $DIR for $UPDATER_REPO in project $NAME ($HOST_DIR)"
recover
while :; do
  jq -n --arg at "$(now)" --arg version "$VERSION" '{at: $at, version: $version}' | put "$DIR/updater.json"
  if [ -f "$DIR/request.json" ]; then
    id=$(jq -r '.id // "none" | tostring' "$DIR/request.json" 2>/dev/null | head -c 64 | tr -cd 'A-Za-z0-9-') || id=none
    to=$(jq -r '.version // "" | tostring' "$DIR/request.json" 2>/dev/null | head -c 32) || to=
    stale=$(find "$DIR/request.json" -mmin +"$FRESH" 2>/dev/null || true)
    rm -f "$DIR/request.json"
    if [ -n "$stale" ]; then
      started=$(now); from=$(running_version); semver "$to" || to=invalid
      finish refused 'checking the request' "The request waited more than $FRESH minutes for the updater, so it wasn't carried out. Ask again."
    else
      update
    fi
  fi
  sleep "$POLL"
done
