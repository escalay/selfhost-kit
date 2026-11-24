# Parts

Files you copy into your own repository and then own. Each is what Yardhand runs, with its names taken out.

```sh
npx shadcn add escalay/selfhost-kit/ci-plan
npx shadcn add escalay/selfhost-kit/upgrade-test
npx shadcn add escalay/selfhost-kit/release
```

| Part | What you get | Needs | Then |
|---|---|---|---|
| `ci-plan` | `scripts/ci-plan.sh`, its test, and `.github/workflows/ci.yml` | `upgrade-test`, which is installed with it. A pnpm repository with `gate` and `e2e` scripts and a `.node-version`, a root `Dockerfile`, `scripts/smoke.sh`, `deploy/release.json` (from `release`) and `.release-please-manifest.json`; for the kubernetes job, a chart at `deploy/helm/app` and `scripts/smoke-helm.sh` | Edit the map in `ci-plan.sh` to your folders, and add a case to the test for each rule you change |
| `upgrade-test` | `scripts/upgrade-test.sh` and `scripts/upgrade-test.hooks.sh` | Docker with buildx, `git` and `jq`; a compose file that pins the updater (`image: ghcr.io/escalay/updater:<version>`); releases tagged `v<version>` whose images can be pulled | Fill the hooks (below): where you publish, how to make your image another version, how to put data in and find it again |
| `release` | `.github/workflows/release.yml` and `deploy/release.json` | release-please's `release-please-config.json` and `.release-please-manifest.json`, a root `Dockerfile`, `scripts/smoke.sh`, `deploy/compose/docker-compose.yml` with a line `image: ghcr.io/escalay/updater:<version>` and `deploy/compose/.env.example`, and a CI workflow named `ci.yml` (`ci-plan`'s) to start for the release pull request. Optional: `docs/releases/<version>.md` to lead a release's notes | Set `upgradeFrom` in `deploy/release.json` to the oldest version that can update to the next release in one step |

### The upgrade-test hooks

`scripts/upgrade-test.hooks.sh` is what only your product knows. `upgrade-test.sh` reads it with `$root` set to
your repository and `compose` running Docker Compose in the test's project; the file as shipped fills it for the
kit's example app. Run the test with `APP_IMAGE=<image> bash scripts/upgrade-test.sh`; its header lists the rest.

| Name | What | Default |
|---|---|---|
| `PUBLISHED` | The image releases are published as, without a tag | required |
| `COMPOSE_FILE` | The compose file a release ships | required |
| `TAGS` | The git repository whose `v<version>` tags are the releases | required |
| `SERVICE` | The app's service in the compose file | `app` |
| `PROVENANCE` | The attestation's file name, `<repository name>.intoto.jsonl` | `app.intoto.jsonl` |
| `OLDEST` | The oldest release to start from, when not every tag has an image | `upgradeFrom` in the `release.json` one folder above the compose file |
| `ENV_LINES` | Lines for the test project's `.env`: what keeps a test instance from calling out | none |
| `HEALTH_URL` | Where the app answers with its version | `http://<SERVICE>/api/health` |
| `dockerfile_for IMAGE VERSION [broken]` | Prints a Dockerfile that makes IMAGE answer as VERSION, and with `broken` die at start after it has touched the data | required |
| `seed NAME` | Writes something that must survive, while the app runs | required |
| `kept NAME` | Succeeds when what `seed NAME` wrote is still there | required |
| `untouched_by VERSION` | Succeeds when nothing a failed VERSION wrote is left in the data | required |

## Updating a part

Each copied file says where it came from, on its first line after any `#!`: `# selfhost-kit <part>@<version>`. A
file installed from `main` between two releases may be ahead of the version it names. `deploy/release.json` is the
exception: JSON has no comments, so it carries no stamp, and its `upgradeFrom` is yours; merge it by hand against
the version your `release.yml` names. To take a newer version:

1. Read the [changelog](../CHANGELOG.md) after the version your files name, the lines marked **parts** first.
2. Compare each file with the one the new version ships, and carry the changes into yours:
   ```sh
   curl -fsSL https://raw.githubusercontent.com/escalay/selfhost-kit/v<version>/parts/ci-plan/ci-plan.sh | diff scripts/ci-plan.sh -
   ```
   `scripts/upgrade-test.sh` stays as shipped, so it is replaced whole. The map in `ci-plan.sh`, the hooks and the
   workflows are yours, and are merged by hand.
3. Set the stamp to the version your file now matches, and run the checks in the `selfhost-ci` skill.

## What they are built on

- **Test a change by what it could break.** A map from changed paths to slow jobs, written as a script so it can
  have test cases. An unknown path runs everything, and every night everything runs, so a wrong map is caught
  within a day.
- **Never test the same commit twice.** A push to main skips what its pull request passed on that exact commit.
- **A release's pull request gets one real update,** started by the release workflow, since a pull request a bot
  opens starts no workflow by itself.
- **The upgrade test starts from real releases with real data,** one job per older release so they run side by
  side, and it proves the rollback as well as the update.
- **A release is checked the way it will be installed:** the workflow runs the updater's own two signature checks
  against the release before publishing it.

## What Yardhand measured

Measured in November 2026: before these, one CI run took about 14 minutes of waiting and every change ran twice.
After: about 3 minutes for a change that touches everything, under a minute for prose, and nothing on the push that
follows a pull request. Most of the time lost had been one wait loop that never saw its update finish; the timing of
each step in the log is what found it.

## What keeps them working

This repository runs `ci-plan.test.sh` and the whole upgrade test against its own example app on every change
(`.github/workflows/ci.yml`), lints every part's shell and workflow files, and runs `test/docs.sh`, which holds this
page's install lines, Needs and hooks table to the parts themselves. The release workflow part is linted but not
run here: Yardhand's own copy is the proof of it.
