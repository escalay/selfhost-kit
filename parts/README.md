# Parts

Files you copy into your own repository and then own. Each is what Yardhand runs, with its names taken out.

```sh
npx shadcn add escalay/selfhost-kit/ci-plan
npx shadcn add escalay/selfhost-kit/upgrade-test
npx shadcn add escalay/selfhost-kit/release
```

| Part | What you get | Then |
|---|---|---|
| `ci-plan` | `scripts/ci-plan.sh`, its test, and `.github/workflows/ci.yml` | Edit the map in `ci-plan.sh` to your folders, and add a case to the test for each rule you change |
| `upgrade-test` | `scripts/upgrade-test.sh` and `scripts/upgrade-test.hooks.sh` | Fill the hooks: where you publish, how to make your image another version, how to put data in and find it again |
| `release` | `.github/workflows/release.yml` and `deploy/release.json` | Add release-please's two config files, and `scripts/smoke.sh` |

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

Before these, one CI run took about 14 minutes of waiting and every change ran twice. After: about 3 minutes for a
change that touches everything, under a minute for prose, and nothing on the push that follows a pull request.
Most of the time lost had been one wait loop that never saw its update finish; the timing of each step in the
log is what found it.

## What keeps them working

This repository runs `ci-plan.test.sh` and the whole upgrade test against its own example app on every change
(`.github/workflows/ci.yml`), and lints the two workflow files. The release workflow part is linted but not run
here: Yardhand's own copy is the proof of it.
