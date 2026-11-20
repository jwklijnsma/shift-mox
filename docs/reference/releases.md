# Releases and updates

## Releases

A release is a `vX.Y.Z` tag on `main` and a GitHub release with notes generated
from the merged pull requests. The tag is only made on a commit that passes the
lint workflow (syntax check, ansible-lint, ruff, shellcheck).

To use a release:

```bash
git clone --branch v0.1.0 https://github.com/jwklijnsma/shift-mox.git
# or, in an existing clone:
git fetch --tags && git checkout v0.1.0
```

### Automatic

`auto-release.yml` starts the release workflow on its own:

| When | What |
|---|---|
| A pull request is merged into `main` | A release right away. Bot PRs (Renovate, Dependabot) don't start one |
| Every Monday at 05:23 UTC | A release of whatever was merged since the last one, such as automerged dependency updates |

Nothing happens when `main` has no commits since the last tag, so a quiet week
makes no release. The first release is `v0.1.0`.

The bump comes from the labels on the pull requests merged since the last
release:

| Label | Bump |
|---|---|
| `release:major` | major |
| `release:minor` | minor |
| none | patch |

Label a pull request `no-release` to keep its merge from starting a release; it
still goes out with the next one.

### By hand

**Actions › release › Run workflow**: pick `patch`, `minor` or `major`, or type
an exact version. **Dry run** works out the version and the notes and tags
nothing.

## Dependency updates

`automerge.yml` merges pull requests from Renovate and Dependabot on its own once
every other check on the pull request has passed:

- only **patch and minor** updates (for 0.x versions: only patches); majors stay
  open for review, as do updates where no version change can be read;
- opt out per pull request with the `no-automerge` label, or by marking it as a draft;
- when the update touched the docs site, the docs deploy is started afterwards.

### Renovate in GitHub Actions

The pull requests come from Renovate, run by `renovate.yml` in this repository's
own Actions every 4 hours (and from **Actions › renovate › Run workflow**). No
Renovate app is needed. `renovate.json` sets what it updates: GitHub Actions
(minor and patch bumps in one PR), the Ansible collections in `requirements.yml`
and the docs site's `requirements-docs.txt`. A **Dependency Dashboard** issue lists
everything Renovate knows about, including the majors it is waiting on.

One-time setup: create a
[fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)
for this repository only, with **Contents**, **Pull requests**, **Issues** and
**Workflows** set to *Read and write*, and save it as the Actions secret
`RENOVATE_TOKEN`. `GITHUB_TOKEN` can't be used: pull requests it opens start no
checks, so they would never be merged automatically.

The pull requests are opened under your account, on `renovate/…` branches;
`automerge.yml` recognises them by that branch name, and merging one never starts
a release on its own (the weekly release picks them up).
