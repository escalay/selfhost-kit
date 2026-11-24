# selfhost-kit

The parts a self-hosted app needs around its own code, shared by Escalay's products. Today: the updater.

## Commands

| Command | What |
|---|---|
| `updater/test/run.sh` | The updater end to end against real Docker (needs Docker; about 3 minutes) |
| `updater/test/signatures.sh` | The image's own cosign against real published signatures (needs the network) |
| `updater/test/real.sh` | The updater against a published release of the example, nothing replaced (needs the network) |
| `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 -s sh /mnt/updater/updater.sh` | Lint the script |

## Layout

| Path | What |
|---|---|
| `updater/updater.sh` | The whole updater: watch for a request, verify, start, wait, roll back, hand over |
| `updater/README.md` | Its contract with an app: the files, the release's files, the state folder, the settings |
| `updater/test/` | A compose project and `run.sh` (only cosign is replaced), `signatures.sh` and `real.sh` (nothing is) |
| `parts/` | Copy-in files for a product's own repository, listed in `registry.json` (`npx shadcn add escalay/selfhost-kit/<part>`): `ci-plan`, `upgrade-test`, `release`. CI runs the first two against the example app |
| `skills/` | Agent skills (`npx skills add escalay/selfhost-kit`): `selfhost-ci` |
| `example/` | The smallest app that keeps the contract, with its compose file. Every release publishes it signed, as a product would publish itself, and the release is proven against it before and after it is out |

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
