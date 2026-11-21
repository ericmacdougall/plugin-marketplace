#!/usr/bin/env bash
# Local daily runner replacing the scheduled "Bump plugin SHAs" workflow and the
# validate-catalog re-dispatch (both are workflow_dispatch only now, because the
# personal account has no Actions minutes and `ubuntu-latest-m` never existed).
#
# Each run:
#   1. takes an exclusive non-blocking lock (flock(1), or Perl flock(2) on macOS);
#   2. syncs a dedicated clone to origin/main (never a dev checkout);
#   3. runs scripts/bump-plugin-shas.py with --github-output <temp file>.
#      It NEVER passes --force and clears FORCE_BUMP, so it never force-pushes:
#      if today's bump/daily-* branch already exists the bump is a no-op;
#   4. instead of `gh workflow run validate-catalog.yml`, checks out every
#      non-skipped branch from pr-urls (and main) and runs
#      `validate-catalog.py` and `generate-plugin-index.py --check` locally;
#   5. writes a dated log and status markers (no outbound messages):
#        $GHA_OFFLOAD_HOME/status/plugin-marketplace-bump.last    every run
#        $GHA_OFFLOAD_HOME/status/plugin-marketplace-bump.FAILED  while failing
#
# gh/git use the host's existing `gh auth` login (never printed). GH_REPO is
# pinned to the fork so `gh pr` can never target the upstream repository.
#
# Usage: scripts/local-bump-runner.sh [--dry-run] [--only NAME]
# Env:   PM_REPO (default ericmacdougall/plugin-marketplace)
#        PM_CLONE (default $GHA_OFFLOAD_HOME/runners/plugin-marketplace)
#        GHA_OFFLOAD_HOME (default ~/gha-offload)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export GHA_OFFLOAD_HOME="${GHA_OFFLOAD_HOME:-$HOME/gha-offload}"
name=plugin-marketplace-bump
repo="${PM_REPO:-ericmacdougall/plugin-marketplace}"
clone="${PM_CLONE:-$GHA_OFFLOAD_HOME/runners/plugin-marketplace}"

dry_run=0; only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --only) only="${2:-}"; shift ;;
    --force) echo "--force is not supported by the local runner" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$GHA_OFFLOAD_HOME"/{logs,locks,status,runners}
exec 9>"$GHA_OFFLOAD_HOME/locks/$name.lock"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { echo "$name already running; skipping" >&2; exit 75; }
else
  perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or die; flock($fh, LOCK_EX|LOCK_NB) or exit 1' \
    || { echo "$name already running; skipping" >&2; exit 75; }
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
log="$GHA_OFFLOAD_HOME/logs/$name-$stamp.log"
exec >>"$log" 2>&1
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pm-bump.XXXXXX")"

finish() {
  local rc=$? now; now="$(date -u +%FT%TZ)"
  rm -rf "$tmp"
  if [ "$rc" -eq 0 ]; then
    echo "ok 0 $now $log" >"$GHA_OFFLOAD_HOME/status/$name.last"
    rm -f "$GHA_OFFLOAD_HOME/status/$name.FAILED"
    echo "=== $name ok $now ==="
  else
    echo "FAIL $rc $now $log" >"$GHA_OFFLOAD_HOME/status/$name.last"
    echo "FAIL $rc $now $log" >"$GHA_OFFLOAD_HOME/status/$name.FAILED"
    echo "=== $name FAILED rc=$rc $now; marker $GHA_OFFLOAD_HOME/status/$name.FAILED ==="
  fi
  find "$GHA_OFFLOAD_HOME/logs" -maxdepth 1 -name "$name-*" -mtime +90 -delete 2>/dev/null || true
  exit "$rc"
}
trap finish EXIT

echo "=== $name start $(date -u +%FT%TZ) on $(hostname -s) dry_run=$dry_run only=${only:-<all>} ==="
command -v gh >/dev/null || { echo "gh not found" >&2; exit 127; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in on this host" >&2; exit 77; }
export GH_REPO="$repo"
export GH_PROMPT_DISABLED=1
unset FORCE_BUMP
export PYTHONDONTWRITEBYTECODE=1

# Dedicated clone with a single remote (the fork); never an upstream remote.
if [ ! -d "$clone/.git" ]; then
  gh repo clone "$repo" "$clone" -- -q
  git -C "$clone" remote remove upstream 2>/dev/null || true
fi
cd "$clone"
if [ "$(git remote)" != "origin" ]; then
  echo "runner clone must have only the 'origin' remote (found: $(git remote | tr '\n' ' '))" >&2; exit 78
fi
case "$(git remote get-url origin)" in
  *"github.com/$repo"|*"github.com/$repo.git"|*"github.com:$repo.git") ;;
  *) echo "origin is not $repo" >&2; exit 78 ;;
esac
git fetch -q --prune origin
git checkout -q -B main origin/main
git reset -q --hard origin/main
git clean -q -ffdx
echo "main at $(git rev-parse HEAD)"

out="$tmp/github-output"; : >"$out"
bump_args=(--only "$only" --base-branch main --github-output "$out")
[ "$dry_run" = 1 ] && bump_args+=(--dry-run)
echo "==> python3 -B scripts/bump-plugin-shas.py ${bump_args[*]}"
set +e
python3 -B scripts/bump-plugin-shas.py "${bump_args[@]}"
bump_rc=$?
set -e
echo "bump-plugin-shas.py exit $bump_rc"

# Branches to validate: main plus every non-skipped branch in pr-urls.
pr_urls="$(sed -n 's/^pr-urls=//p' "$out" | tail -1)"
[ -n "$pr_urls" ] || pr_urls="[]"
branches="$(PR_URLS="$pr_urls" python3 -c 'import json,os; [print(e["branch"]) for e in json.loads(os.environ["PR_URLS"]) if not e.get("skipped") and e.get("branch")]')"
[ "$dry_run" = 1 ] && [ -n "$branches" ] && { echo "dry run: these branches were not pushed; validating main only"; branches=""; }

val_fail=0
validate_ref() {
  local ref="$1"
  echo "==> validate $ref"
  git checkout -q --detach "$ref"
  git clean -q -ffdx
  if python3 -B scripts/validate-catalog.py && python3 -B scripts/generate-plugin-index.py --check; then
    echo "validate $ref: PASS"
  else
    echo "validate $ref: FAIL"; val_fail=1
  fi
}
git fetch -q --prune origin
validate_ref origin/main
for b in $branches; do validate_ref "origin/$b"; done
git checkout -q main

echo "summary: bump_rc=$bump_rc validate_failures=$val_fail branches_validated=$(echo "$branches" | grep -c . || true)"
[ "$bump_rc" -eq 0 ] && [ "$val_fail" -eq 0 ]
