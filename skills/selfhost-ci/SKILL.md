---
name: selfhost-ci
description: Use when setting up or speeding up CI and releases for a self-hosted product that ships a Docker image and a compose file: which jobs run for which change, the upgrade test through the updater, and a release workflow whose releases the updater can install. Also when CI feels slow, a change is tested twice, or a release pull request's checks never start.
---

# CI and releases for a self-hosted product

The parts live in `parts/` of escalay/selfhost-kit. Install one with `npx shadcn add escalay/selfhost-kit/<part>`;
`parts/README.md` says what each needs afterwards.

## Rules

1. **The map is a script with cases.** A change to `scripts/ci-plan.sh` comes with a case in
   `scripts/ci-plan.test.sh`. Run it: `scripts/ci-plan.test.sh`.
2. **Unknown runs everything.** Keep the last rule of the map. Never add a rule that skips a job for a path you
   haven't read.
3. **Required checks keep their names.** A job skipped by `if` counts as passed; a job that doesn't exist blocks
   the merge.
4. **Measure before changing.** Read each step's time from the last runs before deciding what is slow:
   `gh api repos/<repo>/actions/runs/<id>/jobs`. A fixed wait hides as a slow test.
5. **The upgrade test's hooks are the product's.** `scripts/upgrade-test.sh` stays as shipped, so the kit's next
   version can replace it.
6. **Prove it on GitHub.** A plan that passes its cases can still be wired wrong: open a pull request that touches
   one area and read which jobs ran.

## Check

- `scripts/ci-plan.test.sh` passes.
- `APP_IMAGE=<image> scripts/upgrade-test.sh` passes locally.
- On a pull request that changes only Markdown, the slow jobs show as skipped.
- After merging a pull request by fast-forward, the push to main skips them too.
