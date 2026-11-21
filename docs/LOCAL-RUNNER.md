# Local bump and validation runner (no GitHub Actions minutes)

`Bump plugin SHAs` and `Validate catalog` are `workflow_dispatch` only. The bump
job never ran on Actions anyway: it asked for `ubuntu-latest-m`, a runner label
that does not exist on this personal account. Its label is now `ubuntu-latest`
for manual runs.

## What runs instead

`scripts/local-bump-runner.sh`, daily at 07:00 America/Vancouver (UTC-7, so 14:00 UTC; the old workflow cron was 15:00 UTC) on Mac-2 (launchd
`com.transition2.plugin-marketplace-bump`, the host with a working `gh` push
login). launchd runs an installed copy, `~/gha-offload/bin/run-plugin-marketplace-bump.sh`; re-copy it after this script changes on `main`. Each run:

1. takes a non-blocking lock (`~/gha-offload/locks/plugin-marketplace-bump.lock`;
   flock(1), or Perl flock(2) on macOS); an overlapping run exits 75 and writes
   `~/gha-offload/status/plugin-marketplace-bump.skipped`;
2. resets a dedicated clone (`~/gha-offload/runners/plugin-marketplace`, origin
   only, no upstream remote) to `origin/main`;
3. runs `python3 -B scripts/bump-plugin-shas.py --only "" --base-branch main
   --github-output <temp file>`. It never passes `--force` and clears
   `FORCE_BUMP`, so it never force-pushes; if today's `bump/daily-*` branch
   exists, the bump is a no-op, so a run that fails partway is not retried
   until the next day (or a manual `gh workflow run` with force).
   **Cross-day dedup:** a plugin that already has an open bump PR (any day) is
   skipped, and an open `bump/daily-*` PR is reused as the base, so unmerged
   stacks never multiply. A plugin branch left over from a closed PR on the
   reused daily is skipped, never overwritten. To get a fresh bump for a plugin,
   close (and delete the branch of) its old PR. `GH_REPO` is pinned to the fork, so `gh pr`
   cannot target `xai-org/plugin-marketplace`;
4. instead of `gh workflow run validate-catalog.yml`, checks out `main` and every
   branch listed in `pr-urls` and runs `validate-catalog.py` and
   `generate-plugin-index.py --check`;
5. logs to `~/gha-offload/logs/plugin-marketplace-bump-<UTC stamp>.log` and
   writes `~/gha-offload/status/plugin-marketplace-bump.last` (and `.FAILED`
   while failing). Nothing is sent anywhere.

Because no workflow runs on the bump PRs, the PRs carry no `validate` check;
the runner's log is the validation record.

Manual: `scripts/local-bump-runner.sh --dry-run` (no push, no PR) or
`scripts/local-bump-runner.sh --only <plugin>`.

## Pull requests from contributors

`Validate catalog` no longer runs on `pull_request` or `push`, so contributor
PRs get no automatic check either. Before merging any PR, run on its branch:

```
python3 scripts/validate-catalog.py && python3 scripts/generate-plugin-index.py --check
```

If the machine is off at 07:00, launchd runs the job when it next wakes; if it
was powered off, that day is skipped. Check the age of `.last`.

## Timeouts

The bump step is limited to 45 minutes (`PM_BUMP_TIMEOUT`), and each git or
validate step to 10 minutes (`PM_STEP_TIMEOUT`). macOS has no timeout(1), so
the runner uses Perl `alarm` there; a timed-out run exits 124/137/142 and is
recorded as FAILED.

## Token scope (to do: needs Eric)

The runner uses Mac-2's existing `gh auth` login, whose token can reach every
repository that account can. Only `GH_REPO` and the origin check limit it to
this fork. To scope it properly, Eric should create a **fine-grained personal
access token** with:

- Resource owner: `ericmacdougall`; Repository access: *Only select
  repositories* → `ericmacdougall/plugin-marketplace`.
- Permissions: Contents **read and write**, Pull requests **read and write**,
  Metadata read. Nothing else. Expiry: 90 days.

Store it in the macOS login keychain (never in the repo or plist):

```
security add-generic-password -a eric -s plugin-marketplace-bump-token -w   # paste at the prompt
```

and add near the top of the installed runner, before `gh auth status`:

```
GH_TOKEN="$(security find-generic-password -a eric -s plugin-marketplace-bump-token -w)" && export GH_TOKEN
```

`gh` then uses that token only. git pushes use it too if the clone's remote is
HTTPS with gh as the credential helper (`gh auth setup-git`). An SSH remote
keeps using the SSH key, so for full scoping switch the runner clone to HTTPS. Until this is done the broader login is in use.

## Testing an unmerged script change

`PM_SCRIPT_REF=<branch>` makes the runner fetch `scripts/` from that branch of
the fork into its temp dir and run it against the clone's `main`
(`BUMP_REPO_ROOT` points the script at the clone). The clone's worktree is not
touched. Leave it unset for the scheduled job. Example (one plugin, real run):

```
PM_SCRIPT_REF=chore/gha-offload-local-bump ./scripts/local-bump-runner.sh --only octen
```
