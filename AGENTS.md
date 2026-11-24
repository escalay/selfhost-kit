# selfhost-kit

The parts a self-hosted app needs around its own code: the updater (a released image that holds the Docker socket)
and three copy-in parts (`ci-plan`, `upgrade-test`, `release`), with the `selfhost-ci` skill. Shared by Escalay's
products. The repository is public: use the example's and the tests' names, never a real host, person or account.

## Commands

| Command | What |
|---|---|
| `bash test/docs.sh` | The docs against the code: pins, settings, outcomes, Needs, hooks, stamps, names (seconds) |
| `bash parts/ci-plan/ci-plan.test.sh` | The map's cases (seconds) |
| `updater/test/run.sh` | The updater end to end against real Docker (needs Docker; about 6 minutes, November 2026) |
| `updater/test/signatures.sh` | The image's own cosign against real published signatures (needs the network) |
| `updater/test/real.sh` | The updater against a published release of the example, nothing replaced (needs the network) |
| The `parts` job's last step in `.github/workflows/ci.yml` | The upgrade test, against the example app (needs Docker) |
| `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 -s sh /mnt/updater/updater.sh` | Lint the script |
| `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.11.0 -x parts/*/*.sh test/*.sh` | Lint the parts and the docs test |
| `docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -color` | Lint the workflows; add `parts/*/*.yml` for the parts' |
| `pipx run zizmor==1.32.0 --offline .github` | The ways a workflow can be turned against the repository |

## Layout

| Path | What |
|---|---|
| `updater/updater.sh` | The whole updater: watch for a request, verify, start, wait, roll back, hand over |
| `updater/README.md` | Its contract with an app and its operator: install, the files, the settings, what goes wrong, going back, the security model |
| `updater/test/` | A compose project and `run.sh` (only cosign is replaced), `signatures.sh` and `real.sh` (nothing is) |
| `parts/` | Copy-in files for a product's own repository, listed in `registry.json` (`npx shadcn add escalay/selfhost-kit/<part>`): `ci-plan`, `upgrade-test`, `release`. CI runs the first two against the example app |
| `skills/` | Agent skills (`npx skills add escalay/selfhost-kit`): `selfhost-ci` |
| `example/` | The smallest app that keeps the contract, with its compose file. Every release publishes it signed, as a product would publish itself, and the release is proven against it before and after it is out |
| `test/docs.sh` | Holds every fact a doc lists by hand to the file that defines it |
| `SECURITY.md` | How to report a flaw and check the image |

## A change and the files it touches

| Change | Files |
|---|---|
| An updater behaviour | `updater/updater.sh`, a case in `updater/test/run.sh`, `updater/README.md` |
| An updater setting | `updater/updater.sh`, a row in `updater/README.md`'s Settings |
| Something the updater refuses or reports | `updater/updater.sh`, a case in `updater/test/run.sh`, a row in `updater/README.md`'s When it goes wrong |
| A part's file | the file under `parts/<part>/`, keeping its stamp; its Needs in `parts/README.md` when it calls something new |
| The upgrade-test hooks | `parts/upgrade-test/upgrade-test.hooks.sh`, `upgrade-test.sh`, the hooks table in `parts/README.md` |
| A new part | `parts/<part>/` with a stamp on each file, its item in `registry.json`, its files in `release-please-config.json`, its install line and row in `parts/README.md`, its name in `README.md`, this file and every skill |
| A new skill | `skills/<skill>/SKILL.md`, its row in `README.md`, its name here |
| A version pin or stamp | none: release-please moves them at a release |

`test/docs.sh` fails on whatever of these is left out, and names the line to add. The docs are written by hand and
checked; a generated map, one README shape per part and per-version upgrade notes wait until there are about six
parts.

## Invariants

1. The request is untrusted. Only a version number is read from it, and it must be three numbers. Where releases and
   images come from and who signed them are the container's settings, never the request's.
2. Nothing running is touched before the release file's signature, the image's digest and signature and the compose
   file's hash have all been checked.
3. A failed update ends with the old compose file, the old version and the data from before, or says exactly what
   is left to do by hand.
4. The `.env` and the owner's own compose files are never written.
5. Every behaviour has a case in `updater/test/run.sh`; a change to the script comes with one. That test replaces
   cosign, so `updater/test/signatures.sh` runs the image's real cosign, with the script's own flags, against a
   published release: a change to cosign or to those flags must pass it.
6. Released by the release workflow only. A running updater accepts its successor by that workflow's signature.
7. The state volume is the app's to write: the updater acts on nothing there but a request's version, and writes there
   only its status files, `version` and the app's own data files a rollback restores. What it keeps to act on later
   (the run, the copy to roll back to) is in the project folder's `.updater/`, which the app doesn't mount, and a
   rollback uses that copy only when it matches the hashes taken with it.
8. Nothing is written through a link in the state volume: every write, removal and rename there runs inside a folder
   reached through no link (`within`), and a file is written whole into a new file the updater creates exclusively
   (noclobber), then renamed into place (`write`). Nothing the app built there is walked: only names the updater
   knows are removed, never recursively. A write that can't be made so is logged and skipped, never fatal.
9. A pull request's title is a Conventional Commit (`feat`, `fix`, `docs`, …): it becomes the squash commit and a
   line in the release notes. CI checks it.
10. A version that a doc or a part's file pins is never edited by hand. It sits on a line ending in
    `# x-release-please-version`, or between the Markdown comments `x-release-please-start-version` and
    `x-release-please-end`, in a file listed in `release-please-config.json`'s `extra-files`; `test/docs.sh` checks
    both.
