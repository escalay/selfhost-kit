# selfhost-kit

The parts a self-hosted app needs around its own code, built for [Yardhand](https://github.com/escalay/yardhand) and
shared by Escalay's products. MIT licensed; use them for your own.

| Part | What | Status |
|---|---|---|
| [Updater](updater/README.md) | A container beside your app that installs the updates it asks for and rolls back the ones that fail | Released as `ghcr.io/escalay/updater` |
| [CI and release parts](parts/README.md) | Copy-in files: `ci-plan`, CI that tests a change by what it could break; `upgrade-test`, the upgrade test through the updater; `release`, a release workflow whose releases the updater can install | `npx shadcn add escalay/selfhost-kit/<part>` |
| Update and telemetry clients, owner sign-in, claim-and-setup, database and migrations | The app side of the same contracts, as copy-in parts | Planned; today they live in Yardhand |

## The updater in one minute

Your app runs from a compose file, read-only and without access to Docker. When its owner clicks "Update", the app
writes a version number to a file. The updater, a second container that does hold the Docker socket:

1. downloads that release's `release.json` and checks that your release workflow signed it;
2. pulls the image that file names by digest and checks its signature;
3. replaces the compose file with the release's, keeping `.env` and the owner's own compose files;
4. starts the new version and waits for it to answer as healthy with the new version number;
5. otherwise puts back the old compose file, the old version and the data from before.

<!-- x-release-please-start-version -->
```yaml
services:
  app:
    image: ${APP_IMAGE:-ghcr.io/you/app:<version>}
    volumes: [state:/state]
  updater:
    image: ghcr.io/escalay/updater:1.2.1 # x-release-please-version
    environment:
      UPDATER_REPO: you/app
      UPDATER_IMAGE: ghcr.io/you/app
    volumes:
      - state:/state
      - .:/project
      - /var/run/docker.sock:/var/run/docker.sock
volumes:
  state:
```
<!-- x-release-please-end -->

**The updater holds the Docker socket, which is as good as root on the machine.** That is the point of it: one small,
signed script holds that access so that your app doesn't. [updater/README.md](updater/README.md) has the whole
contract, what your release workflow has to publish and the [security model](updater/README.md#security-model);
[SECURITY.md](SECURITY.md) says how to check the image and how to report a flaw.

## Try it

[example/](example/) is the smallest app that keeps the contract. Every release of this repository publishes it
signed, the way your own release workflow would, and is proven against it.

## For agents

`npx skills add escalay/selfhost-kit` gives a coding agent the kit's skills:

| Skill | Use it when |
|---|---|
| `selfhost-ci` | Setting up or speeding up CI and releases for a self-hosted product, or adopting the updater |

An agent working on this repository starts at [AGENTS.md](AGENTS.md).

## Develop

```sh
updater/test/run.sh          # the updater end to end against real Docker: about 6 minutes (November 2026)
updater/test/signatures.sh   # its cosign against real published signatures
updater/test/real.sh         # the updater against a published release of the example, nothing replaced
```

Releases come from the release workflow: merging the release pull request tags the version, tests, builds, pushes
and signs the image, then publishes the release.
