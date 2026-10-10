#!/usr/bin/env bash
#
# Deploy one commit of this repository to TestFlight.
#
# The usual target is origin/main. A dedicated detached worktree at
# $NOOP_DEPLOY_DIR (default ~/.noop-deploy/main) is created on first use
# and updated on every run. Tools/testflight-upload.sh inside that
# worktree does the archive, so the bits that ship are the fetched
# commit, not the checkout that launched this script.
#
# One deploy runs at a time. The lock is a directory created with mkdir,
# which is atomic, plus a pid file. A second invocation waits (up to
# $NOOP_DEPLOY_LOCK_TIMEOUT seconds, default 3600) and then fetches
# again, so a push that landed during an upload is what gets built. A
# lock whose recorded pid is dead is removed. A missing pid file is
# stale only after 30 seconds, so a lock that is still being written is
# left alone.
#
# If the fetched commit matches the full SHA in $NOOP_DEPLOY_STATE and
# --force is not set, the script prints "Already deployed <sha>" and
# exits 0. A failed upload leaves that file unchanged. The file is not
# created until the first successful upload.
#
# NOOP_DEPLOY_REF, when set, checks out that local commit and skips the
# fetch. It is for a dry run of a commit that is not on the remote yet.
# NOOP_DEPLOY_HOLD_SECONDS sleeps after the lock is taken. It is a test
# hook so a second run can be shown waiting.
#
# Usage:
#   Tools/testflight-deploy-main.sh [--force] [--dry-run]
#
# Settings (environment, then the default):
#   NOOP_DEPLOY_DIR      worktree (default $HOME/.noop-deploy/main)
#   NOOP_DEPLOY_REMOTE   remote name (default origin)
#   NOOP_DEPLOY_BRANCH   branch name (default main)
#   NOOP_DEPLOY_STATE    last deployed full SHA
#                        (default $HOME/.config/noop/testflight-last-deployed)
#   NOOP_DEPLOY_REF      optional local commit; skips fetch
#   NOOP_DEPLOY_LOCK     lock directory (default $HOME/.noop-deploy/lock)
#   NOOP_DEPLOY_LOCK_TIMEOUT  seconds to wait for the lock (default 3600)
#   NOOP_DEPLOY_HOLD_SECONDS  sleep after taking the lock (tests; default 0)
#
# --dry-run resolves the commit, then runs the upload script with
# --dry-run. It does not archive and does not update the state file.
# --force uploads even when the state file already names this commit.
#
# Logs: $HOME/.noop-deploy/logs/<YYYYMMDDHHMMSS>-<shortsha>.log
#
# The fetch refspec has no destination, so it updates FETCH_HEAD in the
# deploy worktree and does not move a branch checked out elsewhere.
# git clean runs only in the deploy worktree, and only when it would
# remove something other than build/ or DerivedData/.

set -euo pipefail

usage() {
  echo "usage: Tools/testflight-deploy-main.sh [--force] [--dry-run]" >&2
}

# Repository that contains this script. Other checkouts of the same clone
# share its common git directory; the deploy worktree is attached there.
SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
COMMON_DIR="$(git -C "$(dirname "$0")/.." rev-parse --git-common-dir)"
if [[ "$COMMON_DIR" != /* ]]; then
  COMMON_DIR="$(cd "$SOURCE_ROOT/$COMMON_DIR" && pwd -P)"
else
  COMMON_DIR="$(cd "$COMMON_DIR" && pwd -P)"
fi

FORCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

require_uint() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "error: ${name} must be a non-negative integer" >&2
    exit 2
  fi
}

require_token() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || "$value" == *"/"* || "$value" == *" "* || "$value" == *$'\n'* || "$value" == -* ]]; then
    echo "error: ${name} must be a single path segment" >&2
    exit 2
  fi
}

# Branch names may contain slashes (release/1.2). They must not look like flags.
require_branch() {
  local value="$1"
  if [[ -z "$value" || "$value" == *" "* || "$value" == *$'\n'* || "$value" == -* || "$value" == */*/*/* ]]; then
    echo "error: NOOP_DEPLOY_BRANCH must be a branch name" >&2
    exit 2
  fi
  if [[ "$value" == /* || "$value" == */ || "$value" == *..* || "$value" == *~* ]]; then
    echo "error: NOOP_DEPLOY_BRANCH must be a branch name" >&2
    exit 2
  fi
}

DEPLOY_DIR="${NOOP_DEPLOY_DIR:-${HOME}/.noop-deploy/main}"
REMOTE="${NOOP_DEPLOY_REMOTE:-origin}"
BRANCH="${NOOP_DEPLOY_BRANCH:-main}"
STATE_FILE="${NOOP_DEPLOY_STATE:-${HOME}/.config/noop/testflight-last-deployed}"
LOCK_DIR="${NOOP_DEPLOY_LOCK:-${HOME}/.noop-deploy/lock}"
LOCK_TIMEOUT="${NOOP_DEPLOY_LOCK_TIMEOUT:-3600}"
HOLD_SECONDS="${NOOP_DEPLOY_HOLD_SECONDS:-0}"
LOG_DIR="${HOME}/.noop-deploy/logs"

require_uint NOOP_DEPLOY_LOCK_TIMEOUT "$LOCK_TIMEOUT"
require_uint NOOP_DEPLOY_HOLD_SECONDS "$HOLD_SECONDS"
require_token NOOP_DEPLOY_REMOTE "$REMOTE"
require_branch "$BRANCH"

# Physical path with . and .. removed. Does not create anything. realpath
# resolves existing parents, so a deploy dir under a symlinked checkout is
# compared against git's worktree paths before any directory is created.
if [[ -x /usr/bin/python3 ]]; then
  physical_path() {
    /usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
  }
else
  physical_path() {
    local path="$1"
    if [[ "$path" != /* ]]; then
      path="${PWD}/${path}"
    fi
    if [[ -d "$path" ]]; then
      (cd "$path" && pwd -P)
      return
    fi
    printf '%s\n' "$path"
  }
fi

DEPLOY_DIR="$(physical_path "$DEPLOY_DIR")"
LOCK_DIR="$(physical_path "$LOCK_DIR")"
STATE_FILE="$(physical_path "$STATE_FILE")"

if [[ "$DEPLOY_DIR" == "/" || "$DEPLOY_DIR" == "$HOME" || "$DEPLOY_DIR" == "$SOURCE_ROOT" ]]; then
  echo "error: refusing to use ${DEPLOY_DIR} as the deploy worktree." >&2
  exit 2
fi
case "$DEPLOY_DIR" in
  "$SOURCE_ROOT"/*)
    echo "error: NOOP_DEPLOY_DIR must be outside the checkout that contains this script (${SOURCE_ROOT})." >&2
    exit 2
    ;;
esac
case "$LOCK_DIR" in
  "$DEPLOY_DIR"|"$DEPLOY_DIR"/*)
    echo "error: the lock directory must not be inside the deploy worktree." >&2
    exit 2
    ;;
esac

common_dir_of() {
  local repo="$1"
  local common
  common="$(git -C "$repo" rev-parse --git-common-dir)"
  if [[ "$common" != /* ]]; then
    common="$(cd "$repo/$common" && pwd -P)"
  else
    common="$(cd "$common" && pwd -P)"
  fi
  printf '%s\n' "$common"
}

# Do not checkout or clean a worktree this script does not own. A path on
# a branch is someone else's checkout. The source checkout is refused above
# even when it is detached.
assert_safe_deploy_dir() {
  local line path physical
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        if [[ -d "$path" ]]; then
          physical="$(cd "$path" && pwd -P)"
        else
          physical="$path"
        fi
        if [[ "$DEPLOY_DIR" == "$physical"/* ]]; then
          echo "error: ${DEPLOY_DIR} is inside another worktree (${path})." >&2
          exit 1
        fi
        ;;
    esac
  done < <(git -C "$SOURCE_ROOT" worktree list --porcelain)

  if [[ ! -d "$DEPLOY_DIR" ]]; then
    return 0
  fi
  if ! git -C "$DEPLOY_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: ${DEPLOY_DIR} exists and is not a git worktree. Refusing to replace it." >&2
    exit 1
  fi
  local other
  other="$(common_dir_of "$DEPLOY_DIR")"
  if [[ "$other" != "$COMMON_DIR" ]]; then
    echo "error: ${DEPLOY_DIR} belongs to a different git repository. Refusing to touch it." >&2
    exit 1
  fi
  if git -C "$DEPLOY_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
    echo "error: ${DEPLOY_DIR} is on a branch. The deploy worktree stays detached. Refusing to check out or clean it." >&2
    exit 1
  fi
}

# Missing registration for this path only. git worktree prune drops admin
# data for worktrees whose directories are already gone. It does not delete
# a checkout that is still on disk.
prune_missing_registration() {
  local line path registered=0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"
        if [[ "$path" == "$DEPLOY_DIR" ]]; then
          registered=1
        fi
        ;;
    esac
  done < <(git -C "$SOURCE_ROOT" worktree list --porcelain)
  if [[ "$registered" -eq 1 && ! -d "$DEPLOY_DIR" ]]; then
    git -C "$SOURCE_ROOT" worktree prune
  fi
}

ensure_deploy_worktree() {
  assert_safe_deploy_dir
  if [[ -d "$DEPLOY_DIR" ]]; then
    return 0
  fi
  prune_missing_registration
  # HEAD here is only the initial commit. The caller detaches at the target.
  git -C "$SOURCE_ROOT" worktree add --detach "$DEPLOY_DIR" HEAD
  assert_safe_deploy_dir
}

# Excludes match a gitignore directory pattern: build/ and DerivedData/
# anywhere in the deploy worktree. Nothing outside that worktree is cleaned.
clean_if_needed() {
  local preview
  preview="$(git -C "$DEPLOY_DIR" clean -ffdxn -e build/ -e DerivedData/)"
  if [[ -n "$preview" ]]; then
    git -C "$DEPLOY_DIR" clean -ffdx -e build/ -e DerivedData/
  fi
}

detach_at() {
  local target="$1"
  if ! git -C "$DEPLOY_DIR" -c advice.detachedHead=false checkout --detach --force "$target"; then
    echo "Checkout of ${target} failed in ${DEPLOY_DIR}. Cleaning untracked files and retrying." >&2
    git -C "$DEPLOY_DIR" clean -ffdx -e build/ -e DerivedData/
    git -C "$DEPLOY_DIR" -c advice.detachedHead=false checkout --detach --force "$target"
  fi
  clean_if_needed
}

LOCK_HELD=0

cleanup() {
  local status=$?
  set +e
  if [[ "$LOCK_HELD" -eq 1 && -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    local current=""
    if [[ -f "$LOCK_DIR/pid" ]]; then
      current="$(tr -d '[:space:]' < "$LOCK_DIR/pid" 2>/dev/null || true)"
    fi
    if [[ "$current" == "$$" ]]; then
      rm -rf "$LOCK_DIR" || true
    fi
    LOCK_HELD=0
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

lock_age_seconds() {
  local mtime now
  mtime="$(stat -f %m "$LOCK_DIR")"
  now="$(date +%s)"
  printf '%s\n' $((now - mtime))
}

pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ "$pid" -lt 2 ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

acquire_lock() {
  local deadline announced=0 holder again age now
  deadline=$(( $(date +%s) + LOCK_TIMEOUT ))
  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      if ! printf '%s\n' "$$" > "$LOCK_DIR/pid"; then
        rm -rf "$LOCK_DIR" || true
        echo "error: could not record the deploy lock pid." >&2
        exit 1
      fi
      LOCK_HELD=1
      return 0
    fi
    if [[ ! -d "$LOCK_DIR" ]]; then
      echo "error: could not create the deploy lock at ${LOCK_DIR}." >&2
      exit 1
    fi
    holder=""
    if [[ -f "$LOCK_DIR/pid" ]]; then
      holder="$(tr -d '[:space:]' < "$LOCK_DIR/pid" 2>/dev/null || true)"
    fi
    if [[ -z "$holder" || ! "$holder" =~ ^[0-9]+$ || "$holder" -lt 2 ]]; then
      age="$(lock_age_seconds)"
      if [[ "$age" -ge 30 ]]; then
        echo "Removing a deploy lock with no live pid."
        rm -rf "$LOCK_DIR" || true
        continue
      fi
      sleep 1
      continue
    fi
    if ! pid_alive "$holder"; then
      again=""
      if [[ -f "$LOCK_DIR/pid" ]]; then
        again="$(tr -d '[:space:]' < "$LOCK_DIR/pid" 2>/dev/null || true)"
      fi
      if [[ "$again" == "$holder" ]] && ! pid_alive "$holder"; then
        echo "Removing stale deploy lock for pid ${holder}."
        rm -rf "$LOCK_DIR" || true
        continue
      fi
    fi
    now="$(date +%s)"
    if [[ "$now" -ge "$deadline" ]]; then
      echo "error: timed out after ${LOCK_TIMEOUT}s waiting for the deploy lock held by pid ${holder}." >&2
      exit 1
    fi
    if [[ "$announced" -eq 0 ]]; then
      echo "Waiting for deploy lock held by pid ${holder}."
      announced=1
    fi
    sleep 2
  done
}

read_state_sha() {
  STATE_SHA=""
  if [[ ! -f "$STATE_FILE" ]]; then
    return 0
  fi
  local value lower
  value="$(tr -d '[:space:]' < "$STATE_FILE")"
  if [[ -z "$value" ]]; then
    return 0
  fi
  lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  if [[ ! "$lower" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: ${STATE_FILE} must contain one full commit SHA or be empty." >&2
    exit 1
  fi
  STATE_SHA="$lower"
}

write_state_sha() {
  local sha="$1"
  local dir tmp
  dir="$(dirname "$STATE_FILE")"
  mkdir -p "$dir"
  tmp="${STATE_FILE}.tmp.$$"
  printf '%s\n' "$sha" > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

print_upload_failure() {
  local status="$1"
  local log="$2"
  local matches
  echo "error: TestFlight upload failed (exit ${status})." >&2
  echo "Log: ${log}" >&2
  matches="$(grep -E 'error:|fatal:|\*\* (ARCHIVE|EXPORT|BUILD) FAILED \*\*|errSec' "$log" | tail -n 20 || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" >&2
  else
    tail -n 20 "$log" >&2 || true
  fi
}

# "Uploaded <bundle> <version> (<build>) to TestFlight."
# Parameter expansion, not =~ : bash 3.2 misparses parentheses inside [[ ]].
parse_uploaded_line() {
  local log="$1"
  local line rest before
  line="$(grep ' to TestFlight\.' "$log" | tail -n 1 || true)"
  case "$line" in
    "Uploaded "*" ("*") to TestFlight.") ;;
    *) return 1 ;;
  esac
  rest="${line#Uploaded }"
  rest="${rest% to TestFlight.}"
  UPLOADED_BUILD="${rest##* (}"
  UPLOADED_BUILD="${UPLOADED_BUILD%)}"
  before="${rest% (*}"
  UPLOADED_VERSION="${before##* }"
  if [[ -z "$UPLOADED_VERSION" || -z "$UPLOADED_BUILD" || "$UPLOADED_VERSION" == *" "* ]]; then
    return 1
  fi
  return 0
}

export GIT_TERMINAL_PROMPT=0

mkdir -p "$(dirname "$DEPLOY_DIR")" "$(dirname "$LOCK_DIR")"

acquire_lock

if [[ "$HOLD_SECONDS" -gt 0 ]]; then
  echo "Holding the deploy lock for ${HOLD_SECONDS}s."
  sleep "$HOLD_SECONDS"
fi

# Resolve a local override before creating the worktree, so a bad ref
# fails without checking out a commit.
target_expr=""
if [[ -n "${NOOP_DEPLOY_REF:-}" ]]; then
  if ! target_expr="$(git -C "$SOURCE_ROOT" rev-parse --verify "${NOOP_DEPLOY_REF}^{commit}")"; then
    echo "error: NOOP_DEPLOY_REF is not a commit: ${NOOP_DEPLOY_REF}" >&2
    exit 1
  fi
fi

ensure_deploy_worktree

if [[ -n "${NOOP_DEPLOY_REF:-}" ]]; then
  echo "Checking out ${NOOP_DEPLOY_REF} in ${DEPLOY_DIR}."
  detach_at "$target_expr"
else
  echo "Fetching ${REMOTE} ${BRANCH}."
  if ! git -C "$DEPLOY_DIR" fetch "$REMOTE" "$BRANCH"; then
    echo "error: git fetch ${REMOTE} ${BRANCH} failed." >&2
    exit 1
  fi
  echo "Checking out FETCH_HEAD in ${DEPLOY_DIR}."
  detach_at FETCH_HEAD
fi

SHA="$(git -C "$DEPLOY_DIR" rev-parse --verify 'HEAD^{commit}')"
SHORT="$(git -C "$DEPLOY_DIR" rev-parse --short=12 HEAD)"
if [[ -n "${NOOP_DEPLOY_REF:-}" ]]; then
  echo "Resolved ${NOOP_DEPLOY_REF} at ${SHA}."
else
  echo "Resolved ${REMOTE}/${BRANCH} at ${SHA}."
fi

read_state_sha
if [[ "$FORCE" -eq 0 && -n "$STATE_SHA" && "$STATE_SHA" == "$SHA" ]]; then
  echo "Already deployed ${SHA}"
  exit 0
fi

UPLOAD="${DEPLOY_DIR}/Tools/testflight-upload.sh"
if [[ ! -f "$UPLOAD" ]]; then
  echo "error: ${UPLOAD} is missing at ${SHA}." >&2
  echo "This commit has no TestFlight upload script, so nothing was uploaded." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
STAMP="$(date +%Y%m%d%H%M%S)"
LOG="${LOG_DIR}/${STAMP}-${SHORT}.log"
if [[ -e "$LOG" ]]; then
  LOG="${LOG_DIR}/${STAMP}-${SHORT}-$$.log"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Would run: ${UPLOAD} --dry-run"
else
  echo "Running: ${UPLOAD}"
fi
echo "Log: ${LOG}"

upload_status=0
if [[ "$DRY_RUN" -eq 1 ]]; then
  (cd "$DEPLOY_DIR" && "$UPLOAD" --dry-run) 2>&1 | tee "$LOG" || upload_status=$?
else
  (cd "$DEPLOY_DIR" && "$UPLOAD") 2>&1 | tee "$LOG" || upload_status=$?
fi

if [[ "$upload_status" -ne 0 ]]; then
  print_upload_failure "$upload_status" "$LOG"
  exit "$upload_status"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: ${SHORT} would be uploaded. No archive. State file unchanged."
  exit 0
fi

if ! parse_uploaded_line "$LOG"; then
  # The upload process exited 0, so record the SHA. A retry must not upload
  # the same commit again. The missing summary line is still a failure.
  write_state_sha "$SHA"
  echo "error: upload exited 0 but the log has no 'Uploaded ... to TestFlight.' line." >&2
  echo "Log: ${LOG}" >&2
  exit 1
fi

write_state_sha "$SHA"
echo "Deployed ${SHORT} as ${UPLOADED_VERSION} (${UPLOADED_BUILD})"
