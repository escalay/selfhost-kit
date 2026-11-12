#!/usr/bin/env bash
# What only your product knows, for scripts/upgrade-test.sh. This one is the kit's example app; replace each part.
# shellcheck disable=SC2034,SC2154

# The image releases are published as, the compose file a release ships, and the repository whose tags are releases
PUBLISHED=ghcr.io/escalay/updater-example
COMPOSE_FILE="$root/example/docker-compose.yml"
TAGS=https://github.com/escalay/selfhost-kit.git
# The app's service in the compose file, and the attestation's file name (<repository name>.intoto.jsonl)
SERVICE=app
PROVENANCE=selfhost-kit.intoto.jsonl
# The oldest release to start from, when not every tag has an image (default: upgradeFrom in deploy/release.json)
OLDEST=1.1.0
# Lines for the project's .env: what keeps a test instance from calling out
ENV_LINES=

# dockerfile_for IMAGE VERSION [broken]: a Dockerfile that makes IMAGE answer as VERSION, and with `broken` die at
# start after it has touched the data
dockerfile_for() {
  echo "FROM $1"
  echo "ENV VERSION=$2 BROKEN=${3:+yes}"
}
# seed NAME: write something that must survive, while the app is running
seed() { compose exec -T app sh -c "echo 'written on $1' >> /state/state.sqlite"; }
# kept NAME: what `seed NAME` wrote is still there
kept() { compose exec -T app grep -q "written on $1" /state/state.sqlite; }
# untouched_by VERSION: nothing a failed VERSION wrote is left in the data
untouched_by() { ! compose exec -T app grep -q "migrated by $1" /state/state.sqlite; }
