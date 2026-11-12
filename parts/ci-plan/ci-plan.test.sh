#!/usr/bin/env bash
# What CI runs for which change (ci-plan.sh), case by case. Run it in a job that always runs; add a case whenever
# you change the map.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
failed=0
# expect "what it is" "e2e compose kubernetes older" EVENT BRANCH TESTED [files…]
expect() {
  local name=$1 want=$2 event=$3 branch=$4 tested=$5 got
  shift 5
  got=$(printf '%s\n' "$@" | EVENT="$event" BRANCH="$branch" TESTED="$tested" "$here/ci-plan.sh" | cut -d= -f2 | tr '\n' ' ')
  if [ "${got% }" = "$want" ]; then echo "ok: $name"; else echo "FAIL: $name: wanted '$want', got '${got% }'"; failed=1; fi
}
t=$'\t'
pr() { local name=$1 want=$2; shift 2; expect "$name" "$want" pull_request feat/x false "$@"; }

pr "prose only runs none of the slow jobs" "false false false none" "README.md${t}false" "docs/updates.md${t}false"
pr "the interface runs the browser tests only" "true false false none" "apps/web/src/Home.tsx${t}false"
pr "the chart runs the cluster only" "false false true none" "deploy/helm/app/values.yaml${t}false"
pr "the compose file runs compose and the older releases" "false true false some" "deploy/compose/docker-compose.yml${t}false"
pr "the Dockerfile runs every kind of install" "false true true some" "Dockerfile${t}false"
pr "server code without a migration skips the older releases" "true true false none" "src/features/tools.ts${t}false"
pr "server code with a migration adds the older releases" "true true false some" "src/features/tools.ts${t}true"
pr "the database code runs everything" "true true true some" "src/db/open.ts${t}false"
pr "a workflow could touch everything" "true true true some" ".github/workflows/ci.yml${t}false" "README.md${t}false"
pr "the lockfile could touch everything" "true true true some" "pnpm-lock.yaml${t}false"
pr "a pull request with no list of files is tested in full" "true true true some"
expect "a push already tested in its pull request repeats nothing" "false false false none" push main true
expect "a push never tested (a squash) is tested in full" "true true true some" push main false
expect "the nightly run tests everything from every release" "true true true all" schedule main false
expect "a run asked for by hand does too" "true true true all" workflow_dispatch main false
expect "a release's pull request gets one real update" "false true false none" pull_request release-please--branches--main false "CHANGELOG.md${t}false"
expect "and the same when its checks are started for it" "false true false none" workflow_dispatch release-please--branches--main false
[ "$failed" = 0 ] && echo "ci-plan: all good"
exit "$failed"
