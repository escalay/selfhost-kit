#!/usr/bin/env bash
# Decides which of CI's slow jobs a run needs, so a change is tested by what it could break and nothing is tested
# twice. Prints one `name=value` per line: e2e, compose, kubernetes (true or false) and older (which older releases
# the upgrade test starts from: none, some, all). The CI workflow reads them; ci-plan.test.sh holds the map to its
# cases. Yours to edit: the map below is the only part that knows your repository.
#
#   EVENT    pull_request, push, schedule or workflow_dispatch
#   BRANCH   the branch the run is for
#   TESTED   true on a push whose exact commit already passed these jobs in its pull request
#   stdin    for a pull request, its files: one per line as `path<TAB>data`, where data is true when the change to
#            that file adds a migration or a table
set -euo pipefail
event="${EVENT:?}" branch="${BRANCH:-}" tested="${TESTED:-false}"
say() { printf 'e2e=%s\ncompose=%s\nkubernetes=%s\nolder=%s\n' "$1" "$2" "$3" "$4"; exit 0; }

# A release's own pull request changes version numbers on code main just tested: one real update is enough
case "$branch" in release-please--*) say false true false none ;; esac

case "$event" in
  # The nightly run and a run asked for by hand test everything, from every release
  schedule | workflow_dispatch) say true true true all ;;
  push) if [ "$tested" = true ]; then say false false false none; else say true true true some; fi ;;
esac

e2e=false compose=false kubernetes=false older=none seen=false
while IFS=$'\t' read -r path data; do
  [ -n "$path" ] || continue
  seen=true
  # ── The map: what a changed path could break. Edit it for your repository; keep the last rule ──
  case "$path" in
    # Prose: the fast jobs cover it
    *.md) ;;
    # The interface
    web/* | apps/web/*) e2e=true ;;
    deploy/helm/*) kubernetes=true ;;
    deploy/compose/* | deploy/release.json | scripts/upgrade-test*) compose=true older=some ;;
    # What the image is made of, on every kind of install
    Dockerfile | */Dockerfile | container/* | */container/*) compose=true kubernetes=true older=some ;;
    # Code that decides what happens to data at a start, an update or a restore
    src/db/* | src/migrations/* | */src/db/* | */src/migrations/*) e2e=true compose=true kubernetes=true older=some ;;
    # Other server code: older releases only when it adds a migration
    src/* | apps/*)
      e2e=true compose=true
      [ "$data" != true ] || older=some ;;
    # Anything else (the workflows, the lockfile, root settings, a new folder) could touch everything
    *) say true true true some ;;
  esac
done
# No list of files is no reason to test less
[ "$seen" = true ] || say true true true some
say "$e2e" "$compose" "$kubernetes" "$older"
