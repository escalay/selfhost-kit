# selfhost-kit

The parts a self-hosted app needs around its own code, shared by Escalay's products. Today: the updater.

## Commands

| Command | What |
|---|---|
| `updater/test/run.sh` | The updater end to end against real Docker (needs Docker; about 3 minutes) |
| `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:v0.11.0 -s sh /mnt/updater/updater.sh` | Lint the script |

## Layout

| Path | What |
|---|---|
| `updater/updater.sh` | The whole updater: watch for a request, verify, start, wait, roll back, hand over |
| `updater/README.md` | Its contract with an app: the files, the release's files, the state folder, the settings |
| `updater/test/` | A stand-in app that keeps the contract, a compose project, and `run.sh`; only cosign is replaced |

## Invariants

1. The request is untrusted. Only a version number is read from it, and it must be three numbers. Where releases and
   images come from and who signed them are the container's settings, never the request's.
2. Nothing running is touched before the release file's signature, the image's digest and signature and the compose
   file's hash have all been checked.
3. A failed update ends with the old compose file, the old version and the data from before, or says exactly what
   is left to do by hand.
4. The `.env` and the owner's own compose files are never written.
5. Every behaviour has a case in `updater/test/run.sh`; a change to the script comes with one.
6. Released by the release workflow only. A running updater accepts its successor by that workflow's signature.
