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
#      plugins with an open bump PR (any day) are skipped and an open
#      bump/daily-* PR is reused as the base (cross-day dedup); if today's
#      daily branch exists without an open PR, the bump is a no-op;
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
# Overlap: a run that finds the lock held exits 75 and writes
#   $GHA_OFFLOAD_HOME/status/plugin-marketplace-bump.skipped
# (also check the age of .last: it is not updated if the host is off).
# Env:   PM_REPO (only ericmacdougall/* is accepted; default ericmacdougall/plugin-marketplace)
#        PM_CLONE (default $GHA_OFFLOAD_HOME/runners/plugin-marketplace)
#        GHA_OFFLOAD_HOME (default ~/gha-offload)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export GHA_OFFLOAD_HOME="${GHA_OFFLOAD_HOME:-$HOME/gha-offload}"
name=plugin-marketplace-bump
# Exits 74/78 can happen before the log + EXIT trap exist; still leave a
# .FAILED marker the fleet can poll.
fail_early() {
  local rc="$1"; shift
  local now; now="$(date -u +%FT%TZ)"
  mkdir -p "$GHA_OFFLOAD_HOME/status"
  echo "FAIL $rc $now early" >"$GHA_OFFLOAD_HOME/status/$name.last"
  echo "FAIL $rc $now early" >"$GHA_OFFLOAD_HOME/status/$name.FAILED"
  echo "$*" >&2
  echo "=== $name FAILED rc=$rc $now (early); marker $GHA_OFFLOAD_HOME/status/$name.FAILED ===" >&2
  exit "$rc"
}
repo="${PM_REPO:-ericmacdougall/plugin-marketplace}"
case "$repo" in
  ericmacdougall/*) ;;
  *) fail_early 78 "PM_REPO must be an ericmacdougall/* fork (got $repo); never upstream" ;;
esac
clone="${PM_CLONE:-$GHA_OFFLOAD_HOME/runners/plugin-marketplace}"

dry_run=0; only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --only)
      [ $# -ge 2 ] && [ "${2#--}" = "$2" ] || { echo "--only needs a plugin name" >&2; exit 2; }
      only="$2"; shift ;;
    --force) echo "--force is not supported by the local runner" >&2; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$GHA_OFFLOAD_HOME"/{logs,locks,status,runners}
# Refuse to hard-reset anything but a dedicated runner clone.
case "$(cd "$(dirname "$clone")" 2>/dev/null && pwd -P)/$(basename "$clone")" in
  "$(cd "$GHA_OFFLOAD_HOME/runners" && pwd -P)"/*) ;;
  *) fail_early 78 "PM_CLONE must live under $GHA_OFFLOAD_HOME/runners (got $clone)" ;;
esac
skipped() {  # an overlapping run leaves a trace instead of vanishing
  echo "SKIP 75 $(date -u +%FT%TZ) previous run still holds the lock" >"$GHA_OFFLOAD_HOME/status/$name.skipped"
  echo "$name already running; skipping" >&2; exit 75
}
exec 9>"$GHA_OFFLOAD_HOME/locks/$name.lock"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || skipped
else
  perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or die "fd9: $!"; flock($fh, LOCK_EX|LOCK_NB) or exit 1' && lrc=0 || lrc=$?
  case $lrc in 0) ;; 1) skipped ;; *) fail_early 74 "lock helper failed" ;; esac
fi
rm -f "$GHA_OFFLOAD_HOME/status/$name.skipped"

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

# Bounded steps: a hung git/gh/python cannot hold the lock indefinitely.
# Every child runs with fd 9 (the lock) closed, in its own process group, and
# the whole group is killed on timeout: timeout(1) does that on Linux; on macOS
# a small Perl supervisor does (TERM, then KILL after 30 s; exit 124).
with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout --kill-after=60 "$secs" "$@" 9>&-
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout --kill-after=60 "$secs" "$@" 9>&-
  else
    perl -e '
      my $s = shift;
      my $pid = fork() // die "fork: $!";
      if ($pid == 0) { setpgrp(0, 0); exec @ARGV or die "exec: $!" }
      setpgrp($pid, $pid);
      local $SIG{ALRM} = sub {
        print STDERR "timeout: killing process group $pid after ${s}s\n";
        kill "TERM", -$pid;
        for (1 .. 30) { waitpid($pid, 1); last unless kill(0, -$pid); sleep 1 }  # 1 = WNOHANG
        kill "KILL", -$pid; waitpid($pid, 0); exit 124;
      };
      alarm $s;
      waitpid($pid, 0);
      exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "$secs" "$@" 9>&-
  fi
}
bump_timeout="${PM_BUMP_TIMEOUT:-2700}"     # 45 min for discovery + pushes + PRs
step_timeout="${PM_STEP_TIMEOUT:-600}"      # 10 min for any single git/validate step

echo "=== $name start $(date -u +%FT%TZ) on $(hostname -s) dry_run=$dry_run only=${only:-<all>} ==="
command -v gh >/dev/null || { echo "gh not found" >&2; exit 127; }
gh auth status -h github.com >/dev/null 2>&1 || { echo "gh is not logged in on this host" >&2; exit 77; }
export GH_REPO="$repo"
export GH_PROMPT_DISABLED=1
unset FORCE_BUMP
export PYTHONDONTWRITEBYTECODE=1

# Dedicated clone with a single remote (the fork); never an upstream remote.
if [ ! -d "$clone/.git" ]; then
  with_timeout "$step_timeout" gh repo clone "$repo" "$clone" -- -q
  git -C "$clone" remote remove upstream 2>/dev/null || true
fi
cd "$clone"
if [ "$(git remote)" != "origin" ]; then
  echo "runner clone must have only the 'origin' remote (found: $(git remote | tr '\n' ' '))" >&2; exit 78
fi
case "$(git remote get-url origin)" in
  "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo.git"|"ssh://git@github.com/$repo.git") ;;
  *) echo "origin is not $repo" >&2; exit 78 ;;
esac
with_timeout "$step_timeout" git fetch -q --prune origin
git reset -q --hard
git clean -q -ffdx
git checkout -q -f -B main origin/main
git reset -q --hard origin/main
git clean -q -ffdx
echo "main at $(git rev-parse HEAD)"

out="$tmp/github-output"; : >"$out"
bump_args=(--only "$only" --base-branch main --github-output "$out")
[ "$dry_run" = 1 ] && bump_args+=(--dry-run)
# PM_SCRIPT_REF (testing only): run scripts/ from another branch of the fork
# against main, without touching the clone's worktree. Default: main's scripts.
bump_script="scripts/bump-plugin-shas.py"
if [ -n "${PM_SCRIPT_REF:-}" ]; then
  case "$PM_SCRIPT_REF" in
    *[!A-Za-z0-9._/-]*|-*|*..*) echo "invalid PM_SCRIPT_REF" >&2; exit 64 ;;
  esac
  with_timeout "$step_timeout" git fetch -q origin "refs/heads/$PM_SCRIPT_REF"
  mkdir -p "$tmp/script-ref"
  git archive FETCH_HEAD scripts | tar -x -C "$tmp/script-ref"
  bump_script="$tmp/script-ref/scripts/bump-plugin-shas.py"
  export BUMP_REPO_ROOT="$clone"
  echo "using scripts/ from origin/$PM_SCRIPT_REF at $(git rev-parse FETCH_HEAD)"
fi
echo "==> python3 -B $bump_script ${bump_args[*]}"
set +e
with_timeout "$bump_timeout" python3 -B "$bump_script" "${bump_args[@]}"
bump_rc=$?
set -e
echo "bump-plugin-shas.py exit $bump_rc"
case "$bump_rc" in 124|137) echo "!!! bump-plugin-shas.py timed out after ${bump_timeout}s" ;; esac

# Branches to validate: main plus every non-skipped branch in pr-urls.
pr_urls="$(sed -n 's/^pr-urls=//p' "$out" | tail -1)"
[ -n "$pr_urls" ] || pr_urls="[]"
branches="$(PR_URLS="$pr_urls" python3 -c 'import json,os; [print(e["branch"]) for e in json.loads(os.environ["PR_URLS"]) if not e.get("skipped") and e.get("branch")]')"
[ "$dry_run" = 1 ] && [ -n "$branches" ] && { echo "dry run: these branches were not pushed; validating main only"; branches=""; }

val_fail=0
validate_ref() {
  local ref="$1"
  echo "==> validate $ref"
  if ! git checkout -q -f --detach "$ref"; then
    echo "validate $ref: FAIL (ref missing)"; val_fail=1; return 0
  fi
  git clean -q -ffdx
  if with_timeout "$step_timeout" python3 -B scripts/validate-catalog.py && with_timeout "$step_timeout" python3 -B scripts/generate-plugin-index.py --check; then
    echo "validate $ref: PASS"
  else
    echo "validate $ref: FAIL"; val_fail=1
  fi
}
with_timeout "$step_timeout" git fetch -q --prune origin
validate_ref origin/main
while IFS= read -r b; do [ -n "$b" ] && validate_ref "origin/$b"; done <<<"$branches"
git checkout -q -f main

echo "summary: bump_rc=$bump_rc validate_failures=$val_fail branches_validated=$(echo "$branches" | grep -c . || true)"
# Exit with the bump's own code (e.g. 124 = timed out) so .last/.FAILED show it.
[ "$bump_rc" -ne 0 ] && exit "$bump_rc"
[ "$val_fail" -eq 0 ]
