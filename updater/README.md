# The updater

A container that runs beside a self-hosted app in the same Docker Compose project. The app asks for an update by
writing a file; the updater verifies the release, installs it, and rolls back if the new version doesn't come up.
The app needs no access to Docker.

## What the app does

Everything is a JSON file in `<state>/updates/`, where `<state>` is the volume both containers mount at `/state`.

| File | Written by | What |
|---|---|---|
| `request.json` | the app | `{ "id": "<any id>", "version": "1.5.0", "at": "<time>" }`. Write a temp file and rename it. The updater removes it when it takes it |
| `updater.json` | the updater, every 10 s | `{ "at": "<time>", "version": "1.0.0" }`. Fresh means an updater is there |
| `status.json` | the updater | `{ "id", "state", "step", "from", "to", "startedAt", "at", "detail" }` for the last request |
| `history.jsonl` | the updater | One finished `status` per line |

`state` is `working`, then one of:

| State | Meaning |
|---|---|
| `done` | The new version is running |
| `failed` | The new version didn't come up; `from` is running again with the data from before. `detail` says why, and what is left to do by hand when the old version couldn't be put back |
| `refused` | Nothing was changed: the version isn't newer, the release isn't signed, or it can't be reached from `from` in one step |

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

Mounts: the state volume at `/state`, the project folder at `/project`, and `/var/run/docker.sock`. The app mounts
the state volume only.

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

## Updating the updater

When a release's compose file names another updater image, the running updater pulls it, checks that this
repository's release workflow signed it, and starts a short-lived container of it that recreates the updater
service. A container can't recreate itself.

## What it can't do

- It works with Docker Compose only, and with one project per updater.
- The first compose file must sit in the project folder, and the project folder must not be inside the state volume:
  the updater refuses to start otherwise.
- The project folder's path on the host must not be a folder the updater's image already has (`/root`, `/opt`,
  `/srv`, …): the updater reaches the project at that same path, and exits with 78 at start when something else is
  there.
- Writes made between the start of an update and its rollback are lost; the app is down for most of that time.
- A release has to come from a GitHub repository whose release workflow signs with GitHub's OIDC identity.
