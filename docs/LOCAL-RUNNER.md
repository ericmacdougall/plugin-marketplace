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
   until the next day (or a manual `gh workflow run` with force). `GH_REPO` is pinned to the fork, so `gh pr`
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
