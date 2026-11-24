# The updater

A container that runs beside a self-hosted app in the same Docker Compose project. The app asks for an update by
writing a file; the updater verifies the release, installs it, and rolls back if the new version doesn't come up.
The app needs no access to Docker.

## Install

1. Add the updater to the app's compose file, beside the app, as on the [front page](../README.md#the-updater-in-one-minute):
   the state volume at `/state`, the project folder at `/project`, the Docker socket, `UPDATER_REPO` and
   `UPDATER_IMAGE`. Pin it to a version; from then on each release's compose file names the updater it runs with.
2. Give any other setting (below) in that compose file. A value the compose file reads from the environment
   belongs in `.env`: an update starts the project again from its folder, not from the shell that first started it.
3. `docker compose up -d`, then `docker compose logs updater`. It says
   `updater: version <version>, watching /state/updates for <owner/name> in project <project> (<folder>)`.
4. The app sees `updater.json` change (below). The first update it asks for proves the rest: the release's
   signatures, its compose file and the app's health answer.

## What the app does

Everything is a JSON file in `<state>/updates/`, where `<state>` is the volume both containers mount at `/state`.

| File | Written by | What |
|---|---|---|
| `request.json` | the app | `{ "id": "<any id>", "version": "1.5.0", "at": "<time>" }`. Write a temp file and rename it. The updater removes it when it takes it |
| `updater.json` | the updater, every `UPDATER_POLL` seconds while idle, not during an update | `{ "at": "<time>", "version": "<its version>" }`. Fresh means an updater is there; while `status.json` says `working`, trust that instead |
| `status.json` | the updater | `{ "id", "state", "step", "from", "to", "startedAt", "at", "detail" }` for the last request |
| `history.jsonl` | the updater | One finished `status` per line |

`state` is `working`, then one of:

| State | Meaning |
|---|---|
| `done` | The new version is running |
| `failed` | The new version didn't come up; `from` is running again with the data from before. `detail` says why, and what is left to do by hand when the old version couldn't be put back |
| `refused` | Nothing was changed. `detail` says why, in one of the ways [When it goes wrong](#when-it-goes-wrong) lists |

Only `version` is read from a request, and it must be three numbers (`1.5.0`). Treat the request as a hint: the
updater decides what is installed. It reads the first 4 KiB of a request, once, and only while it is a plain file;
anything else (a link, a pipe, a folder) is removed and refused as naming no version; a folder that isn't empty is
not looked into but renamed aside to `updates/request.left.<random>`. Nothing else in the state volume is an
instruction to the updater. In `<state>/updates/` it writes `updater.json` and `status.json`, adds to `history.jsonl`
(by copying it with the new line), and removes the copy an updater before 1.2.1 left. In `<state>` it writes
`version`, and a rollback moves the app's own data files described below.

The updater never writes through a link in the state volume. It writes each file whole into a new file it creates
itself, refusing any name already taken, and renames that into place: a link to a file at the target is replaced. A
link to a folder at the target, or a folder, is left, and so is the write. It adds to `history.jsonl` only while that
is a plain file, and does nothing in a folder of the volume that is itself a link, such as `updates/` or `backups/`.
A write it leaves out is said in its log (`left … as it was`), and it carries on. Keep these plain files and
folders, or the app won't see the updater's status.

## What the updater keeps for itself

During a run the updater keeps what it may act on later in `.updater/` in the project folder (`/project`), which
only the updater mounts:

| File | What |
|---|---|
| `run.json` | The run in progress: `id`, `from`, `to`, `startedAt`. At its next start, the updater finishes a run it finds here |
| `kept/<compose file>`, `kept/services` | The compose file and the services running before the update: what a rollback starts |
| `kept.sha256` | Their hashes, with `run.json`'s, taken before the compose file is replaced |

A rollback first checks the kept files against `kept.sha256`. When they changed after it was taken, nothing is put
back: the run ends `failed` and `detail` says what to do by hand. The folder is removed when a run ends. The app must
not mount the project folder.

Updaters before 1.2.1 kept the copy for a rollback in `<state>/updates/rollback`. An updater from 1.2.1 on never uses a
copy there: at start it removes the two files such an updater left there, then the folder, without looking at anything
else in it (what else is there is moved aside to `updates/rollback.left.<random>`), and reports it once as `failed`,
step `interrupted`. So an update that such an
earlier updater was carrying out when it stopped, and that the newer updater then starts after, is not rolled back.
`detail` says which version answers now; when that isn't the one that should run, put its compose file (from its
release) back by hand and run `docker compose up -d`. An update that ended before the newer updater started, as the
usual handover does, leaves nothing there. One that stopped before it changed anything leaves nothing there either:
`status.json` stays `working` until the next request; nothing was changed, so ask for the update again.

The app also answers `GET /api/health` (or `UPDATER_HEALTH_URL`) with JSON that has its `version`. That is how the
updater knows what is running and when the new version is up. It reads at most 1 MiB of the answer and 32 characters
of `version`: a longer answer reads as no answer.

## What the app's state folder looks like

A rollback restores data, so the updater relies on three things the app does at start:

| The app | So that |
|---|---|
| writes the version that last ran to `<state>/version` once it is up, and refuses to start on data a newer version wrote | a rollback can say which version the data belongs to |
| copies its database to `<state>/backups/before-<version>.sqlite` before a newer version migrates it, unless that file is already there | the data from before the update exists |
| moves `<state>/restore.pending.sqlite`, if there is one, over its database before opening it | a restore never swaps a database under a running app |

An app without a database to restore can skip the second and third; the rollback then restores the version and the
compose file only.

## What a release publishes

Three files on the GitHub release `v<version>` of `UPDATER_REPO`:

| File | What |
|---|---|
| `release.json` | `{ "version": "1.5.0", "upgradeFrom": "1.2.0", "image": "<UPDATER_IMAGE>@sha256:…", "compose": { "file": "docker-compose.yml", "sha256": "…" } }` |
| the compose file it names | Replaces the project's first compose file |
| `<repo name>.intoto.jsonl` | A Sigstore bundle attesting `release.json`, made by `actions/attest-build-provenance` in `.github/workflows/release.yml` on `main` |

`upgradeFrom` is the oldest version that can move to this one in one step; an older one is refused and told to
update to it first. The image must also be signed with cosign by the same workflow.

Only `release.json` needs the attestation: it names the image by digest and the compose file by hash, so a signed
`release.json` fixes everything that is installed under that version.

## Settings

| Setting | Default | What |
|---|---|---|
| `UPDATER_REPO` | required | `owner/name` on GitHub: where releases are and whose release workflow must have signed them |
| `UPDATER_IMAGE` | required | The image releases are published as, without a tag |
| `UPDATER_SERVICE` | `app` | The app's service in the compose file |
| `UPDATER_HEALTH_URL` | `http://<service>/api/health` | Answers JSON with `version` |
| `UPDATER_TIMEOUT` | `180` | Seconds the new version has to come up. Starting it, health checks of what depends on it included, may take twice that |
| `UPDATER_FRESH` | `60` | Minutes a request stays good. An older one is refused, so an updater that was away doesn't install what was asked for then |
| `UPDATER_WORKFLOW` | `release.yml` | The workflow file that signs releases |
| `UPDATER_DATABASE` | `state.sqlite` | The database file's name in the state folder (no `/`) |
| `UPDATER_RELEASES` | GitHub's release downloads of `UPDATER_REPO` | Another place to fetch the release's files from. Their signature is checked all the same |
| `UPDATER_PROVENANCE` | `<repo name>.intoto.jsonl` | The release's attestation file |
| `UPDATER_OWN_REPO` | `escalay/selfhost-kit` | Whose release workflow must have signed a new updater image before this one hands over to it. Not your app's repository: the updater is this kit's |
| `UPDATER_STATE` | `/state` | Where the state volume is mounted in the updater. It must hold what the app keeps at its own state folder |
| `UPDATER_POLL` | `10` | Seconds between two looks for a request, and between two writes of `updater.json` |
| `UPDATER_VERSION` | the image's | Set by the image and written to `updater.json`. Leave it alone |

Mounts: the state volume at `/state` (`UPDATER_STATE`), the project folder at `/project`, and `/var/run/docker.sock`.
The app mounts the state volume only.

## When it goes wrong

`status.json` says what happened: its `state`, the `step` it got to, and a `detail` the app can show its owner as
it is. `history.jsonl` keeps every run, and `docker compose logs updater` has the same lines. Each case is one in
`updater/test/run.sh`.

### Refused: nothing was changed

| `detail` says | What to do | Case |
|---|---|---|
| The request names no version | The app wrote something other than three numbers on one line: fix what it writes | `a version that isn't one` |
| The request names no version, and `request.json` is gone or in `updates/request.left.<random>` | It was a link, a pipe or a folder: write a plain file and rename it into place | `a request that isn't a plain file` |
| The app isn't answering at … | Make it healthy first: `docker compose logs app`. An answer over 1 MiB, or a `version` over 32 characters, reads as none | `an app that isn't answering` |
| … isn't newer than the … that is running | Nothing: that version or a newer one is there | `an older version` |
| The request waited more than … minutes | Ask again now that the updater runs (`UPDATER_FRESH`) | `a request that waited too long` |
| Release … has no release.json or … | The release wasn't published for the updater, or `UPDATER_RELEASES` doesn't reach it. Update by hand as its notes say | `a release that doesn't exist` |
| The files of release … aren't signed by …'s release workflow | Don't install it by hand. Check `UPDATER_REPO` and `UPDATER_WORKFLOW` | `a bad signature` |
| The release file at v… describes another version | The release's files are mixed up: tell its publisher | `a release file for another version` |
| … can be reached directly only from … | Update to the version it names first, then to this one | `a release this version can't reach directly` |
| Release … names an image that isn't … | Don't install it, or correct `UPDATER_IMAGE` | `an image from elsewhere` |
| The compose file of release … isn't the one its release file names | It changed after signing: don't install it | `a compose file changed after signing` |
| The image of release … couldn't be pulled | `docker pull` it on the host to see why: the registry, the network or a login | `an image that can't be pulled` |
| The image of release … isn't signed by … | Don't install it | `an image nobody signed` |
| The verified image … couldn't be given its tag, or isn't here after the pull | Docker lost it between two commands: ask again | — |
| The compose file of release … doesn't load with this folder's .env | The release needs a setting `.env` doesn't have. Its notes say which: add it and ask again | `a compose file that doesn't load` |
| The updater stopped before it changed anything | Ask again | `a run cut short before it changed anything` |

### Failed: the new version isn't running

| `step` | What happened | What to do | Case |
|---|---|---|---|
| `rolled back` | The new version didn't start, started from another image than the one verified, or didn't answer as healthy with its version within `UPDATER_TIMEOUT`. `from` runs again on its compose file and the data from before; writes made in between are lost | Read `detail` and `docker compose logs app`, and tell the publisher. A new try starts clean | `a new version that never comes up` |
| `rolled back` | The updater was stopped in the middle; at its next start it finished the rollback | As above | `an update interrupted by stopping the updater` |
| `rolled back, but not answering` | The old compose file and data are back, but `from` doesn't answer either | `docker compose logs app`; if it stays down, [go back by hand](#going-back) | — |
| `not rolled back` | The new version didn't come up, and the copy kept in `.updater/` to roll back to changed after it was taken, so nothing was put back | Find out what wrote to the project folder, then [go back by hand](#going-back) from `to` to `from` | `a kept copy changed during the update` |
| `interrupted` | A copy to roll back to that an updater before 1.2.1 left in the state volume was removed unused | When `detail` names another version than the one that should run, [go back by hand](#going-back) | `a copy left in the state volume at start` |

After `done`, a new updater image the release names that can't be pulled, or isn't signed by `UPDATER_OWN_REPO`'s
release workflow, is left alone: the log says so and the running updater stays. The project's compose file names
that image all the same, so the next `docker compose up -d` starts it: to keep the running one, name its image in
`docker-compose.override.yml`.

### The updater won't start

| The log says | What to do | Case |
|---|---|---|
| this container isn't part of a compose project, or the project folder isn't mounted at /project | Run it from the app's compose file with the project folder at `/project`. It exits with 78, and Docker's restart policy tries again | `an updater outside a compose project` |
| UPDATER_DATABASE must name a file in the state folder, not … | Give the database file's name only, without `/` | `a database name with a /` |
| the project folder (…) is inside the state folder, which the app can write | Move the project folder out of the state volume | `a project folder inside the state folder` |
| … is another folder in this container than the project folder mounted at /project | The project folder's path on the host is one the image has (`/root`, `/opt`, `/srv`, …): move it | `a project folder at a folder the image has` |

Each of these exits with 78. Without `UPDATER_REPO` or `UPDATER_IMAGE` it stops at once, and the log names the one
missing.

## Going back

The updater only moves forward: it never installs an older version over newer data, and the app refuses to start on
data a newer version wrote. To go back from `<new>` to `<old>` by hand, do what a rollback does, in the project
folder. No test runs these steps; they are the rollback's, written out. They name the app's service `app`, the
updater's `updater` and the first compose file `docker-compose.yml`: use your project's names.

```sh
docker compose stop app
# The old release's compose file over the first compose file; check it against compose.sha256 in its release.json
curl -fsSL -o docker-compose.yml https://github.com/<owner/name>/releases/download/v<old>/docker-compose.yml
# The data from before the update, which the app takes at its next start, and the version it belongs to
docker compose exec updater sh -c 'cd /state && mv backups/before-<new>.sqlite restore.pending.sqlite &&
  rm -f state.sqlite-wal state.sqlite-shm && echo <old> > version'
docker compose up -d
```

`state.sqlite` is `UPDATER_DATABASE`'s default. Writes made since the update are lost. Without
`backups/before-<new>.sqlite` the old version can't take the data: restore it from your own backup instead.
`docker compose up -d` also starts the updater the old compose file names, which may be older than the one that ran
the update. To keep the newer one, name its image in `docker-compose.override.yml`; a release's compose file
replaces any change to the first one.

## What it never does

- It never reads anything but a version number from the request, and acts on nothing else in the state folder.
- It never rolls back to a kept copy that changed after it was taken.
- It never writes, adds to or removes anything through a link in the state volume.
- It never touches the running app before the release file's signature, the image's digest and signature and the
  compose file's hash are checked.
- It never writes `.env`. Settings given only in the shell that first ran `docker compose up` are not there at an
  update; they belong in `.env`.
- It never replaces compose files after the first. `docker-compose.override.yml` is the owner's and is kept.
- It never installs an older version over newer data.
- It never changes who owns the compose file: it writes through the file that is there.

## Security model

| Who | Holds | Is trusted to |
|---|---|---|
| The app | the state volume; no Docker, not the project folder | ask for a version. Only three numbers are read from its request, and only a newer version is installed. Nothing else it writes there is an instruction to the updater |
| The updater | the Docker socket, as good as root on the host, and the project folder | install what the next row signed, and roll back to the compose file it kept in the project folder's `.updater/` |
| `UPDATER_REPO`'s release workflow on `main` | GitHub's OIDC identity | sign `release.json` (an attestation) and the image (cosign). The release file names the image by digest and the compose file by hash |
| This kit's release workflow (`UPDATER_OWN_REPO`) | its own identity | sign the image a running updater hands over to after an update. Only that handover is held to it: the compose file your app's workflow signs still names the updater the next `docker compose up -d` starts |
| The owner | the host, `.env` and their own compose files | everything. The updater never writes these |

So:

- Whoever can write the state volume, the app included, can ask through a request for a signed version newer than
  the running one, and nothing more by that route: not an older one, not another repository's, not another image.
- The state volume carries no other instruction the updater acts on: a request's version is checked against the
  signed release, and nothing else there is read as one. The updater keeps its own files (the run in progress, the
  copy to roll back to, their hashes) in the project folder, in `.updater/`, which the app must not mount. A rollback
  uses that copy only while it matches the hashes taken with it. Updaters up to 1.2.0 kept the copy in the state
  volume: upgrade to a later one.
- Whoever can write the project folder can change what the updater starts, as they can the compose file there. Give
  it to the owner and the updater only.
- Whoever can run your release workflow on `main` can publish what the updater installs. Protect `main` and that
  workflow file as you would the hosts.
- Whoever controls the release downloads, `UPDATER_RELEASES` or the registry can withhold a release, not change one.
- A release's compose file runs with whatever it asks for, host mounts and privileges included. Its signature says
  who wrote it, not that it is safe.
- To have the updater hand over only to builds you control, set `UPDATER_OWN_REPO` to your fork. A release's compose
  file still names the updater image the next manual `docker compose up -d` starts.

## Updating the updater

When a release's compose file names another updater image, the running updater pulls it, checks that
`UPDATER_OWN_REPO`'s release workflow (by default escalay/selfhost-kit, not your app's) signed it, and starts a
short-lived container of it with the Docker socket and your project folder mounted, which recreates the updater
service. A container can't recreate itself. An image that fails the check isn't handed over to, but the project's
compose file already names it.

## What it can't do

- It works with Docker Compose only, and with one project per updater.
- The first compose file must sit in the project folder, and the project folder must not be inside the state volume:
  the updater refuses to start otherwise.
- The project folder's path on the host must not be a folder the updater's image already has (`/root`, `/opt`,
  `/srv`, …): the updater reaches the project at that same path, and exits with 78 at start when something else is
  there.
- Writes made between the start of an update and its rollback are lost; the app is down for most of that time.
- A release has to come from a GitHub repository whose release workflow signs with GitHub's OIDC identity.
