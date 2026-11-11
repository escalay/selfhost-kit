# selfhost-kit

The parts a self-hosted app needs around its own code, built for [Yardhand](https://github.com/escalay/yardhand) and
shared by Escalay's products. MIT licensed; use them for your own.

| Part | What | Status |
|---|---|---|
| [Updater](updater/README.md) | A container beside your app that installs the updates it asks for and rolls back the ones that fail | Released as `ghcr.io/escalay/updater` |
| Update and telemetry clients, owner sign-in, claim-and-setup, database and migrations | The app side of the same contracts, as copy-in parts | Planned; today they live in Yardhand |

## The updater in one minute

Your app runs from a compose file, read-only and without access to Docker. When its owner clicks "Update", the app
writes a version number to a file. The updater, a second container that does hold the Docker socket:

1. downloads that release's `release.json` and checks that your release workflow signed it;
2. pulls the image that file names by digest and checks its signature;
3. replaces the compose file with the release's, keeping `.env` and the owner's own compose files;
4. starts the new version and waits for it to answer as healthy with the new version number;
5. otherwise puts back the old compose file, the old version and the data from before.

```yaml
services:
  app:
    image: ${APP_IMAGE:-ghcr.io/you/app:1.4.0}
    volumes: [state:/state]
  updater:
    image: ghcr.io/escalay/updater:1.0.0
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

**The updater holds the Docker socket, which is as good as root on the machine.** That is the point of it: one small,
signed script holds that access so that your app doesn't. [updater/README.md](updater/README.md) has the whole
contract and what your release workflow has to publish.

## Develop

```sh
updater/test/run.sh   # the updater end to end against real Docker: about 3 minutes
```

Releases come from the release workflow: merging the release pull request tags the version, tests, builds, pushes
and signs the image, then publishes the release.
