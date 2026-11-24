#!/usr/bin/env bash
# The docs held to the code: every fact a doc lists by hand is checked against the file that defines it, so a new
# setting, part, skill or refusal can't be left out of one. Each failure names the line to add or the code to look at.
# Each check is a function check() runs, which shellcheck can't see; a backtick in a pattern is Markdown's
# shellcheck disable=SC2329,SC2016
set -euo pipefail
cd "$(dirname "$0")/.."
failed=0
version=$(jq -r '."."' .release-please-manifest.json)
items=$(jq -r '.items[].name' registry.json)
skills=$(git ls-files --cached --others --exclude-standard 'skills/*/SKILL.md' | cut -d/ -f2)
bumped=$(jq -r '.packages["."]["extra-files"][] | if type == "string" then . else .path end' release-please-config.json)
# The repository's files, new ones included
files() { git ls-files --cached --others --exclude-standard "$@"; }

# check NAME FUNCTION: FUNCTION prints one line per problem, and nothing when all is well
check() {
  local problems
  problems=$("$2") || true
  if [ -z "$problems" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    printf '%s\n' "$problems" | sed 's/^/  /'
    failed=1
  fi
}
# section FILE HEADING: the lines under HEADING, up to the next heading of its level or above (code blocks skipped)
section() {
  awk -v h="$2" '
    /^```/ { fence = !fence }
    on && !fence && /^#+ / { if (index($0, " ") <= level) exit }
    on { print }
    $0 == h { on = 1; level = index(h, " ") }' "$1"
}
listed() { printf '%s\n' "$1" | grep -qxF "$2"; }

# The updater pinned in a doc is the released one, and release-please moves it at the next release
pins() {
  local file
  for file in $(files '*.md' | grep -vx CHANGELOG.md); do
    awk -v want="$version" -v file="$file" '
      /^<!-- x-release-please-start-version -->$/ { block = 1 }
      /^<!-- x-release-please-end -->$/ { block = 0 }
      match($0, /ghcr\.io\/escalay\/updater:[0-9]+\.[0-9]+\.[0-9]+/) {
        pin = substr($0, RSTART + 24, RLENGTH - 24)
        if (pin != want) print file ":" NR ": pins the updater at " pin ", but this tree is " want
        else if (!block && $0 !~ /x-release-please-version/) print file ":" NR ": the pin has no release-please marker"
        next
      }
      block && /[0-9]+\.[0-9]+\.[0-9]+/ { print file ":" NR ": release-please would move this version to the kit'"'"'s too" }' "$file"
  done
  for file in $(git grep --untracked -lE '^<!-- x-release-please-start-version -->$|# x-release-please-version$'); do
    listed "$bumped" "$file" || echo "$file: has a release-please marker, but isn't in release-please-config.json's extra-files"
  done
  for file in $bumped; do
    [ -f "$file" ] || echo "release-please-config.json: bumps $file, which isn't there"
  done
}

# updater/README.md's Settings table has every UPDATER_* the script reads, and nothing else
settings() {
  local read documented name
  read=$(grep -oE 'UPDATER_[A-Z_]+' updater/updater.sh | sort -u)
  documented=$(section updater/README.md '## Settings' | grep -oE '^\| `UPDATER_[A-Z_]+`' | grep -oE 'UPDATER_[A-Z_]+' | sort -u)
  for name in $read; do
    listed "$documented" "$name" || echo "updater/README.md: the Settings table has no row for $name, which updater.sh reads"
  done
  for name in $documented; do
    listed "$read" "$name" || echo "updater/README.md: the Settings table has $name, which updater.sh never reads"
  done
}

# Each outcome in updater/README.md's When it goes wrong has its case in updater/test/run.sh, and each refusal run.sh
# tests is documented there
outcomes() {
  local documented cases name
  documented=$(section updater/README.md '## When it goes wrong')
  # A case is `refused VERSION "name" …`, or a block that starts with `why="name"`
  cases=$(sed -nE "s/^refused ('[^']*'|[^ ]+) \"([^\"]+)\".*/\\2/p; s/^why=\"([^\"]+)\"$/\\1/p" updater/test/run.sh)
  printf '%s\n' "$documented" | grep -E '^\| ' | while IFS= read -r row; do
    name=$(printf '%s\n' "$row" | awk -F'|' '{ print $(NF - 1) }' | sed 's/^ *//; s/ *$//')
    case "$name" in
      Case | ---*) ;;
      \`*\`)
        name=${name#\`} name=${name%\`}
        listed "$cases" "$name" || echo "updater/README.md: \"$name\" isn't a case in updater/test/run.sh (a refused line or a why= line)" ;;
      *)
        case "$row" in
          # Docker losing an image between two of its own commands, and an old version that fails too: no test
          # makes either happen on purpose
          *"couldn't be given its tag"* | *"rolled back, but not answering"*) ;;
          *) echo "updater/README.md: no case in updater/test/run.sh for: $row" ;;
        esac ;;
    esac
  done
  printf '%s\n' "$cases" | while IFS= read -r name; do
    printf '%s\n' "$documented" | grep -qF "\`$name\`" || echo "updater/README.md: When it goes wrong doesn't name the case \"$name\""
  done
}

# SECURITY.md checks the image with the identity the release workflow signs with and a running updater expects, and the
# updater keeps what it acts on later in the project folder, as the Security model says, never in the state volume
security() {
  local identity
  identity="https://github.com/escalay/selfhost-kit/.github/workflows/release.yml@refs/heads/main"
  grep -qF '"https://github.com/${GITHUB_REPOSITORY}/.github/workflows/release.yml@refs/heads/main"' .github/workflows/release.yml \
    || echo ".github/workflows/release.yml: no longer verifies with the identity SECURITY.md gives"
  grep -qF 'OWN_SIGNER="https://github.com/${UPDATER_OWN_REPO:-escalay/selfhost-kit}/.github/workflows/release.yml@refs/heads/main"' updater/updater.sh \
    || echo "updater/updater.sh: no longer expects its successor signed with the identity SECURITY.md gives"
  # The run and the copy to roll back to are under OWN, and OWN is in the project folder, which the app doesn't mount
  local name
  grep -qxF 'OWN="$PROJECT_MOUNT/.updater"' updater/updater.sh \
    || echo "updater/updater.sh: OWN isn't \$PROJECT_MOUNT/.updater, where the Security model says the updater keeps its own files"
  for name in RUN KEPT SUMS; do
    grep -qE "^$name=\"\\\$OWN/" updater/updater.sh || echo "updater/updater.sh: $name isn't under \$OWN, in the project folder"
  done
  grep -nE '(run\.json|kept)' updater/updater.sh | grep -E '\$(STATE|DIR)\b' \
    | sed 's/^/updater\/updater.sh:/; s/$/  <- keeps the run or the copy to roll back to in the state volume/'
  section updater/README.md '## Security model' | grep -qF 'keeps its own files' \
    || echo "updater/README.md: the Security model doesn't say the updater keeps its own files in the project folder's .updater/"
  # A part is copied into another repository, which has its own SECURITY.md or none
  git grep --untracked -l SECURITY.md -- parts | sed 's/$/: names SECURITY.md, which the repository it is copied into may not have/'
  [ -f SECURITY.md ] || { echo "SECURITY.md: missing"; return; }
  grep -qF -- "--certificate-identity $identity" SECURITY.md || echo "SECURITY.md: doesn't verify with --certificate-identity $identity"
  grep -qF -- "--certificate-oidc-issuer https://token.actions.githubusercontent.com" SECURITY.md \
    || echo "SECURITY.md: doesn't verify with GitHub's OIDC issuer"
}

# What a part's workflow calls in the product's repository is installed with the part, by it or a part it depends
# on, or named in its Needs in parts/README.md. Its scripts read only what their hooks and settings name.
needs() {
  local item deps dep installed row file calls token
  # A path in the product's repository, a root file, or the updater image a compose line pins
  local called='(scripts|deploy|docs)/[A-Za-z0-9._/-]*[A-Za-z0-9_]|\.node-version|\.release-please-manifest\.json'
  called="$called"'|release-please-config\.json|Dockerfile|ci\.yml|ghcr\.io/escalay/updater'
  for item in $items; do
    deps=$(jq -r --arg i "$item" '.items[] | select(.name == $i) | .registryDependencies // [] | .[]' registry.json \
      | sed 's|^escalay/selfhost-kit/||')
    for dep in $deps; do
      listed "$items" "$dep" || echo "registry.json: $item depends on $dep, which isn't a part of this registry"
    done
    installed=$(for one in $item $deps; do
      jq -r --arg i "$one" '.items[] | select(.name == $i) | .files[].target' registry.json
    done | sed 's|^~/||')
    row=$(grep -F "| \`$item\` |" parts/README.md | head -n 1 | awk -F'|' '{ print $4 }')
    for file in $(jq -r --arg i "$item" '.items[] | select(.name == $i) | .files[].path | select(endswith(".yml"))' registry.json); do
      calls=$(sed 's|\\/|/|g' "$file" | grep -oE "$called" | sort -u)
      for token in $calls; do
        listed "$installed" "$token" && continue
        case "$row" in *"$token"*) continue ;; esac
        echo "parts/README.md: $file calls $token, which $item doesn't install and its Needs doesn't name"
      done
    done
  done
}

# A part that reads the updater pin from a compose file reads it as the kit's own compose file writes it, with
# release-please's marker after it: the image and nothing else
pin_readers() {
  local file expression read
  for file in parts/release/release.yml parts/upgrade-test/upgrade-test.sh; do
    expression=$(grep -oE "sed -n 's/\^ \*image: [^']*'" "$file" | head -n 1 | sed "s/^sed -n '//; s/'\$//")
    [ -n "$expression" ] || { echo "$file: no longer reads the updater pin with sed -n 's/^ *image: …'; update this check"; continue; }
    read=$(sed -n "$expression" example/docker-compose.yml)
    [ "$read" = "ghcr.io/escalay/updater:$version" ] \
      || echo "$file: reads the updater pin in example/docker-compose.yml as \"$read\", not ghcr.io/escalay/updater:$version"
  done
}

# The upgrade-test hooks table in parts/README.md has every name the example hooks define, and only names the
# script reads
hooks() {
  local table defined name
  table=$(section parts/README.md '### The upgrade-test hooks' | grep -oE '^\| `[A-Za-z_]+' | sed 's/^| `//' | sort -u)
  defined=$({
    grep -oE '^[A-Z_]+=' parts/upgrade-test/upgrade-test.hooks.sh | tr -d =
    grep -oE '^[a-z_]+\(\)' parts/upgrade-test/upgrade-test.hooks.sh | tr -d '()'
  } | sort -u)
  for name in $defined; do
    listed "$table" "$name" || echo "parts/README.md: the hooks table has no row for $name, which upgrade-test.hooks.sh defines"
  done
  for name in $table; do
    grep -qw "$name" parts/upgrade-test/upgrade-test.sh || echo "parts/README.md: the hooks table has $name, which upgrade-test.sh never reads"
  done
}

# Every file a part copies says which part and version it came from, and release-please moves the version. A JSON
# file can't carry a comment, so it goes without, and parts/README.md's Updating a part says so.
stamps() {
  local updating
  updating=$(section parts/README.md '## Updating a part')
  jq -r '.items[] | .name as $n | .files[] | "\($n) \(.path) \(.target)"' registry.json | while read -r item path target; do
    case "$path" in
      *.json)
        case "$updating" in *"\`${target#\~/}\`"*) ;; *) echo "parts/README.md: Updating a part doesn't say ${target#\~/} carries no stamp" ;; esac
        continue ;;
    esac
    head -n 2 "$path" | grep -qxF "# selfhost-kit $item@$version # x-release-please-version" \
      || echo "$path: neither of its first two lines is \"# selfhost-kit $item@$version # x-release-please-version\""
    listed "$bumped" "$path" || echo "release-please-config.json: $path isn't in extra-files, so its stamp would stay behind"
  done
}

# Every part and skill is named in every doc an agent or a person starts from, and the registry matches parts/
names() {
  local doc item skill dir path
  for doc in README.md AGENTS.md parts/README.md $(files 'skills/*/SKILL.md'); do
    for item in $items; do
      grep -qF "\`$item\`" "$doc" || echo "$doc: never names the part \`$item\`"
    done
  done
  for item in $items; do
    grep -qF "npx shadcn add escalay/selfhost-kit/$item" parts/README.md || echo "parts/README.md: no install line for $item"
    grep -qF "| \`$item\` |" parts/README.md || echo "parts/README.md: no row for $item"
  done
  for skill in $skills; do
    for doc in README.md AGENTS.md; do
      grep -qF "\`$skill\`" "$doc" || echo "$doc: never names the skill \`$skill\`"
    done
    [ "$(sed -n 's/^name: //p' "skills/$skill/SKILL.md")" = "$skill" ] || echo "skills/$skill/SKILL.md: its name isn't $skill"
  done
  for dir in $(files 'parts/*/*' | cut -d/ -f2 | sort -u); do
    listed "$items" "$dir" || echo "registry.json: no part for parts/$dir/"
  done
  for path in $(files 'parts/*/*'); do
    jq -e --arg p "$path" 'any(.items[].files[]; .path == $p)' registry.json > /dev/null \
      || echo "registry.json: $path isn't in any part"
  done
  for path in $(jq -r '.items[].files[].path' registry.json); do
    [ -f "$path" ] || echo "registry.json: $path isn't there"
  done
}

# The sections an operator or agent looks for are where they look
headings() {
  local pair file heading
  for pair in \
    'updater/README.md|## Install' 'updater/README.md|## When it goes wrong' 'updater/README.md|## Going back' \
    'updater/README.md|## Settings' 'updater/README.md|## Security model' 'parts/README.md|## Updating a part' \
    'parts/README.md|### The upgrade-test hooks' 'skills/selfhost-ci/SKILL.md|## Adopt the updater'; do
    file=${pair%%|*} heading=${pair#*|}
    grep -qxF "$heading" "$file" || echo "$file: no \"$heading\""
  done
}

check "the updater pins in the docs are this release, and release-please moves them" pins
check "every UPDATER_* setting the updater reads is in its Settings table, and only those" settings
check "every documented outcome has its case in run.sh, and every refused case is documented" outcomes
check "SECURITY.md and the Security model match what the release workflow and the updater trust" security
check "what a part's workflow calls is installed with it or in its Needs" needs
check "the parts read the updater pin as the kit's compose files write it" pin_readers
check "the upgrade-test hooks table matches the hooks and the script" hooks
check "every copied file carries its part and version, and release-please moves it" stamps
check "every part and skill is named in every doc, and the registry matches parts/" names
check "the docs have the sections operators and agents look for" headings
[ "$failed" = 0 ] && echo "docs: all good"
exit "$failed"
