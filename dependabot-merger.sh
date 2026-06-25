#!/usr/bin/env bash
#
# dependabot-merger.sh — multi-pass, parallel auto-merger for low-risk
# Dependabot / CI PRs across one or more GitHub owners (users or orgs).
#
# Each PASS:
#   1. Discovers all open PRs authored by Dependabot across $OWNERS.
#   2. Classifies each as low-risk (auto-mergeable) or skip (needs a human).
#   3. For every repo IN PARALLEL, merges at most ONE green/clean PR
#      (oldest first) so the rest of that repo's PRs rebase cleanly.
#   4. Records why anything wasn't merged (red CI, conflict, behind, blocked).
#
# It loops PASS after PASS — letting Dependabot rebase the remaining PRs and
# CI re-run between passes — until everything mergeable is merged or the
# remaining PRs are *consistently* red/blocked (RED_STRIKES passes in a row).
#
# SAFE BY DEFAULT: dry-run. It prints what it WOULD merge and changes nothing.
# Pass --execute (or DRY_RUN=0) to actually merge.
#
# Configuration precedence (highest wins):
#   CLI flags  >  environment variables  >  config file  >  built-in defaults
#
# Requires: gh (authenticated), jq, bash 4+.
#
# Usage:
#   ./dependabot-merger.sh                       # dry-run, default owners
#   ./dependabot-merger.sh --execute             # actually merge
#   ./dependabot-merger.sh --owners "me myorg" --execute
#   ./dependabot-merger.sh --config ./my.conf --execute
#   OWNERS="anarkiwi c65sdn" ./dependabot-merger.sh --execute
#
# See --help for the full flag/knob list.

# The "knobs" this script understands (used for env snapshotting & defaults).
DBM_KNOBS=(OWNERS AUTHOR DRY_RUN MAX_PASSES SLEEP_SECONDS RED_STRIKES
  MERGE_METHOD REBASE_BEHIND PR_LIMIT ALLOW_MAJOR_ACTIONS ALLOW_MAJOR_DOCKER
  ALLOW_MAJOR_DEPS ALLOW_GROUPS)

# Built-in defaults. Called by main() and by the test suite.
set_defaults() {
  OWNERS="anarkiwi c65sdn"        # space-separated GitHub users/orgs
  AUTHOR="app/dependabot"         # PR author to act on
  DRY_RUN=1                       # 1 = show only; 0 = merge (--execute)
  MAX_PASSES=30                   # safety cap on number of passes
  SLEEP_SECONDS=45                # wait between passes (lets CI/rebase run)
  RED_STRIKES=3                   # give up on a PR after this many red passes
  MERGE_METHOD=auto               # auto|squash|rebase|merge
  REBASE_BEHIND=1                 # comment "@dependabot rebase" on BEHIND PRs
  PR_LIMIT=100                    # max PRs fetched per repo

  # Risk knobs (1 = treat as low-risk / eligible to auto-merge).
  ALLOW_MAJOR_ACTIONS=1           # github_actions major bumps (CI) — usually safe
  ALLOW_MAJOR_DOCKER=0            # docker base-image major bumps (ubuntu 24->26)
  ALLOW_MAJOR_DEPS=0              # library major bumps (breaking) — off by default
  ALLOW_GROUPS=0                  # 1 = allow ALL grouped PRs (incl. ones with a
                                  # major bump). Off by default, but all-minor
                                  # groups are still treated as low-risk.
}

usage() {
  sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Flags:
  --config FILE              source FILE for config (shell var assignments)
  --owners "a b c"           GitHub owners to scan            [OWNERS]
  --author NAME              PR author to act on              [AUTHOR]
  --execute                  actually merge (sets DRY_RUN=0)
  --dry-run                  preview only (default)
  --max-passes N             max passes                       [MAX_PASSES]
  --sleep N                  seconds between passes           [SLEEP_SECONDS]
  --red-strikes N            red passes before abandoning     [RED_STRIKES]
  --merge-method M           auto|squash|rebase|merge         [MERGE_METHOD]
  --pr-limit N               max PRs fetched per repo         [PR_LIMIT]
  --[no-]rebase-behind       toggle "@dependabot rebase"      [REBASE_BEHIND]
  --[no-]allow-major-actions toggle actions major bumps       [ALLOW_MAJOR_ACTIONS]
  --[no-]allow-major-docker  toggle docker major bumps        [ALLOW_MAJOR_DOCKER]
  --[no-]allow-major-deps    toggle library major bumps       [ALLOW_MAJOR_DEPS]
  --[no-]allow-groups        toggle grouped PRs               [ALLOW_GROUPS]
  -h, --help                 this help

Every flag has an equivalent environment variable (shown in [brackets]).
EOF
}

# ----------------------------- pure helpers ---------------------------------

# first integer ("major") of the best version token on one side of "from X to Y".
# prefers a ">=" lower bound (handles "Update foo requirement from >=1,<2 to >=3").
extract_major() {
  local s="$1" v
  v=$(grep -oE '>=[0-9]+(\.[0-9]+)*' <<<"$s" | head -1 | grep -oE '[0-9]+(\.[0-9]+)*')
  [ -z "$v" ] && v=$(grep -oE '[0-9]+(\.[0-9]+)*' <<<"$s" | head -1)
  grep -oE '^[0-9]+' <<<"$v"
}

# Decide a grouped-update PR from its body: echo "low" if EVERY member update
# stays within the same major version (minor/patch only), else
# "skip:grouped-update". Dependabot lists each member as a line like
#   Updates `foo` from 1.2.0 to 1.3.0
#   Bumps `actions/checkout` from 3 to 4
# A body with no recognisable member lines is treated as skip (unknown = unsafe).
group_all_minor() {
  local body="$1" x y mx my n=0
  # SC2016: the backticks below are literal text in Dependabot PR bodies, not
  # command substitution.
  # shellcheck disable=SC2016
  while IFS=$'\t' read -r x y; do
    [ -z "$x" ] && continue
    n=$((n+1))
    mx=$(extract_major "$x"); my=$(extract_major "$y")
    if [[ -n "$mx" && -n "$my" && "$mx" != "$my" ]]; then
      echo "skip:grouped-update"; return
    fi
  done < <(grep -oiE '(updates|bumps) `[^`]+` from [^ ]+ to [^ ]+' <<<"$body" \
            | sed -E 's/.* [Ff]rom (.+) [Tt]o (.+)$/\1\t\2/')
  if (( n == 0 )); then echo "skip:grouped-update"; else echo low; fi
}

# classify <ecosystem> <title> [body]  -> echoes "low" or "skip:<reason>"
# Reads the ALLOW_* knobs from the environment. For grouped PRs the optional
# body is inspected so an all-minor group is treated as low-risk.
classify() {
  local eco="$1" title="$2" body="${3:-}" x y mx my major=0 group=0
  shopt -s nocasematch
  [[ "$title" =~ (the\ .*\ group|group\ with|group\ across) ]] && group=1
  if [[ "$title" =~ from\ (.+)\ to\ (.+)$ ]]; then
    x="${BASH_REMATCH[1]}"; y="${BASH_REMATCH[2]}"
    mx=$(extract_major "$x"); my=$(extract_major "$y")
    [[ -n "$mx" && -n "$my" && "$mx" != "$my" ]] && major=1
  fi
  shopt -u nocasematch

  if [[ "$eco" == "github_actions" ]]; then
    if [[ "$major" == 1 && "$ALLOW_MAJOR_ACTIONS" != 1 ]]; then echo "skip:actions-major"; else echo low; fi
    return
  fi
  # Grouped PRs: allowed wholesale via ALLOW_GROUPS, otherwise only when every
  # member update in the body is a same-major (minor/patch) bump.
  if [[ "$group" == 1 && "$ALLOW_GROUPS" != 1 ]]; then group_all_minor "$body"; return; fi
  case "$eco" in
    docker)
      if [[ "$major" == 1 && "$ALLOW_MAJOR_DOCKER" != 1 ]]; then echo "skip:docker-major"; else echo low; fi ;;
    *)
      if [[ "$major" == 1 && "$ALLOW_MAJOR_DEPS" != 1 ]]; then echo "skip:dep-major"; else echo low; fi ;;
  esac
}

# jq program: reduce a list of PRs (with .statusCheckRollup) to TSV rows where
# column 5 is the CI verdict red|pending|green|none. Exposed for tests.
dbm_jq_ci() {
  cat <<'JQ'
def ci(r):
  (r // []) as $r
  | if ($r|length)==0 then "none"
    elif ($r|map(select(
        ((.conclusion // "")|ascii_upcase|IN("FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"))
        or ((.state // "")|ascii_upcase|IN("FAILURE","ERROR"))))|length) > 0 then "red"
    elif ($r|map(select(
        ((.status // "")|ascii_upcase|IN("QUEUED","IN_PROGRESS","PENDING","WAITING","REQUESTED"))
        or ((.state // "")|ascii_upcase=="PENDING")))|length) > 0 then "pending"
    else "green" end;
[ .[] | [ (.number|tostring), .headRefName, (.mergeable//"UNKNOWN"),
          (.mergeStateStatus//"UNKNOWN"), ci(.statusCheckRollup), .createdAt, .title ] | @tsv ] | .[]
JQ
}

# ----------------------------- gh-backed helpers ----------------------------

# is a repo archived? (archived repos are read-only — PRs can never be merged)
# Cached across passes in REPO_ARCHIVED. Echoes "true"/"false".
repo_is_archived() {
  local repo="$1"
  if [[ -n "${REPO_ARCHIVED[$repo]:-}" ]]; then echo "${REPO_ARCHIVED[$repo]}"; return; fi
  local a; a=$(gh repo view "$repo" --json isArchived 2>/dev/null | jq -r '.isArchived // false')
  [[ "$a" == true ]] || a=false
  REPO_ARCHIVED[$repo]="$a"; echo "$a"
}

# resolve a repo's preferred merge method
merge_method_for() {
  local repo="$1"
  if [[ -n "${MERGE_CACHE[$repo]:-}" ]]; then echo "${MERGE_CACHE[$repo]}"; return; fi
  local m="$MERGE_METHOD"
  if [[ "$m" == auto ]]; then
    local caps; caps=$(gh repo view "$repo" --json squashMergeAllowed,rebaseMergeAllowed,mergeCommitAllowed 2>/dev/null)
    if   [[ "$(jq -r .squashMergeAllowed <<<"$caps")" == true ]]; then m=squash
    elif [[ "$(jq -r .rebaseMergeAllowed <<<"$caps")" == true ]]; then m=rebase
    else m=merge; fi
  fi
  MERGE_CACHE[$repo]="$m"; echo "$m"
}

# Process one repo: merge at most one ready PR (oldest first). Writes result
# lines "STATE\trepo\tnum\ttitle" to $outfile. Runs in background (parallel).
#   $1 repo  $2 outfile  $3 elig-file (num\teco\ttitle)  $4 merge-method
process_repo() {
  local repo="$1" outfile="$2" elig="$3" method="$4"
  local rows; rows=$(gh pr list --repo "$repo" --author "$AUTHOR" --state open --limit "$PR_LIMIT" \
      --json number,title,headRefName,mergeable,mergeStateStatus,createdAt,statusCheckRollup 2>/dev/null \
      | jq -r "$(dbm_jq_ci)" 2>/dev/null | sort -t$'\t' -k6,6)   # oldest first by createdAt
  [ -z "$rows" ] && return

  local merged_here=0 num headref mergeable state ci title key
  while IFS=$'\t' read -r num headref mergeable state ci _ title; do
    grep -q "^${num}	" "$elig" || continue          # only eligible (low-risk) PRs
    key="$repo#$num"
    [[ -n "${ABANDONED[$key]:-}" ]] && continue

    if [[ "$merged_here" == 1 ]]; then
      echo -e "WAIT\t$repo\t$num\t$title" >>"$outfile"; continue
    fi
    if [[ "$ci" == red ]]; then
      echo -e "RED\t$repo\t$num\t$title" >>"$outfile"; continue
    fi
    if [[ "$mergeable" == CONFLICTING || "$state" == DIRTY ]]; then
      echo -e "CONFLICT\t$repo\t$num\t$title" >>"$outfile"; continue
    fi
    if [[ "$state" == BEHIND ]]; then
      echo -e "BEHIND\t$repo\t$num\t$title" >>"$outfile"; continue
    fi
    if [[ "$ci" == pending || "$mergeable" == UNKNOWN || "$state" == UNKNOWN ]]; then
      echo -e "PENDING\t$repo\t$num\t$title" >>"$outfile"; continue
    fi
    if [[ "$state" == BLOCKED ]]; then
      echo -e "BLOCKED\t$repo\t$num\t$title" >>"$outfile"; continue
    fi
    # READY: CLEAN/UNSTABLE/HAS_HOOKS with green or no checks
    if [[ "$state" =~ ^(CLEAN|UNSTABLE|HAS_HOOKS)$ && ( "$ci" == green || "$ci" == none ) ]]; then
      if [[ "$DRY_RUN" == 1 ]]; then
        echo -e "WOULD-MERGE\t$repo\t$num\t$title" >>"$outfile"; merged_here=1
      elif gh pr merge --repo "$repo" "$num" "--$method" --delete-branch >/dev/null 2>"$outfile.err"; then
        echo -e "MERGED\t$repo\t$num\t$title" >>"$outfile"; merged_here=1
      else
        echo -e "MERGE-FAIL\t$repo\t$num\t$title ($(tr '\n' ' ' <"$outfile.err"))" >>"$outfile"
      fi
      rm -f "$outfile.err"
      continue
    fi
    echo -e "PENDING\t$repo\t$num\t$title" >>"$outfile"
  done <<<"$rows"
}

# ----------------------------- the run loop ---------------------------------
run() {
  command -v gh >/dev/null || { echo "gh not found" >&2; return 1; }
  command -v jq >/dev/null || { echo "jq not found" >&2; return 1; }

  WORK="$(mktemp -d)"   # global; cleaned by the EXIT trap set in main()
  declare -A STRIKES ABANDONED REBASED MERGE_CACHE REPO_ARCHIVED
  local TOTAL_MERGED=0 pass WORKFLOW_SCOPE_FAIL=0

  local owner_args=(); local o; for o in $OWNERS; do owner_args+=(--owner "$o"); done

  echo "== dependabot-merger =="
  echo "owners: $OWNERS | author: $AUTHOR | dry-run: $DRY_RUN | red-strikes: $RED_STRIKES | sleep: ${SLEEP_SECONDS}s"
  echo

  for ((pass=1; pass<=MAX_PASSES; pass++)); do
    echo "================= PASS $pass ================="

    # 1. discover all open dependabot PRs
    local all_json="$WORK/all.$pass.json"
    gh search prs "${owner_args[@]}" --author "$AUTHOR" --state open --limit 500 \
        --json repository,number,title,createdAt >"$all_json" 2>/dev/null

    # 2. classify per repo using the authoritative branch ecosystem
    : >"$WORK/eligible_repos"; : >"$WORK/skips"; rm -f "$WORK"/elig.*.list
    local repos repo num headref title eco verdict key
    mapfile -t repos < <(jq -r '.[].repository.nameWithOwner' "$all_json" | sort -u)
    for repo in "${repos[@]}"; do
      if [[ "$(repo_is_archived "$repo")" == true ]]; then
        printf '%s\t%s\t%s\t%s\n' "$repo" "" "archived" "repository is archived (read-only)" >>"$WORK/skips"
        continue
      fi
      local elig="$WORK/elig.${repo//\//__}.list"; local body
      : >"$elig"
      while IFS=$'\t' read -r num headref title; do
        key="$repo#$num"; [[ -n "${ABANDONED[$key]:-}" ]] && continue
        eco=$(cut -d/ -f2 <<<"$headref")
        # Grouped non-actions PRs need the body to tell all-minor groups
        # (mergeable) from groups that hide a major bump (skip).
        body=""
        if [[ "$ALLOW_GROUPS" != 1 && "$eco" != github_actions && "${title,,}" == *group* ]]; then
          body=$(gh pr view "$num" --repo "$repo" --json body -q .body 2>/dev/null)
        fi
        verdict=$(classify "$eco" "$title" "$body")
        if [[ "$verdict" == low ]]; then
          printf '%s\t%s\t%s\n' "$num" "$eco" "$title" >>"$elig"
        else
          printf '%s\t#%s\t%s\t%s\n' "$repo" "$num" "${verdict#skip:}" "$title" >>"$WORK/skips"
        fi
      done < <(gh pr list --repo "$repo" --author "$AUTHOR" --state open --limit "$PR_LIMIT" \
                --json number,headRefName,title \
                | jq -r '.[] | [(.number|tostring), .headRefName, .title] | @tsv')
      [ -s "$elig" ] && echo "$repo" >>"$WORK/eligible_repos"
    done

    if [[ ! -s "$WORK/eligible_repos" ]]; then
      echo "No eligible low-risk PRs remaining. Done."; break
    fi

    # 3. process every eligible repo IN PARALLEL (one merge per repo this pass)
    rm -f "$WORK"/res.*.txt; local pids=() out method
    while read -r repo; do
      out="$WORK/res.${repo//\//__}.txt"; : >"$out"
      method=$(merge_method_for "$repo")
      process_repo "$repo" "$out" "$WORK/elig.${repo//\//__}.list" "$method" &
      pids+=($!)
    done <"$WORK/eligible_repos"
    local p; for p in "${pids[@]}"; do wait "$p"; done

    # 4. aggregate results, update strikes
    cat "$WORK"/res.*.txt 2>/dev/null | sort >"$WORK/pass.txt"
    local merged_this=0 pending_this=0 behind_this=0 stat
    while IFS=$'\t' read -r stat repo num title; do
      [ -z "$stat" ] && continue
      key="$repo#$num"
      case "$stat" in
        MERGED)       merged_this=$((merged_this+1)); TOTAL_MERGED=$((TOTAL_MERGED+1)); STRIKES[$key]=0 ;;
        WOULD-MERGE)  merged_this=$((merged_this+1)); STRIKES[$key]=0 ;;
        PENDING|WAIT) pending_this=$((pending_this+1)); STRIKES[$key]=0 ;;
        BEHIND)
          behind_this=$((behind_this+1)); STRIKES[$key]=0
          if [[ "$REBASE_BEHIND" == 1 && "$DRY_RUN" == 0 && -z "${REBASED[$key]:-}" ]]; then
            gh pr comment --repo "$repo" "$num" --body "@dependabot rebase" >/dev/null 2>&1 && REBASED[$key]=1
          fi ;;
        RED|CONFLICT|BLOCKED|MERGE-FAIL)
          [[ "$stat" == MERGE-FAIL && "$title" == *"workflow"*"scope"* ]] && WORKFLOW_SCOPE_FAIL=1
          STRIKES[$key]=$(( ${STRIKES[$key]:-0} + 1 ))
          if (( ${STRIKES[$key]} >= RED_STRIKES )); then ABANDONED[$key]=1; fi ;;
      esac
    done <"$WORK/pass.txt"

    awk -F'\t' '{printf "  %-12s %s#%s  %s\n",$1,$2,$3,$4}' "$WORK/pass.txt"
    echo "  ---- pass $pass: merged=$merged_this pending=$pending_this behind=$behind_this (total merged=$TOTAL_MERGED)"

    # 5. stop conditions
    local remaining=0
    while read -r repo; do
      while IFS=$'\t' read -r num _ _; do
        key="$repo#$num"; [[ -z "${ABANDONED[$key]:-}" ]] && remaining=$((remaining+1))
      done <"$WORK/elig.${repo//\//__}.list"
    done <"$WORK/eligible_repos"

    if (( remaining == 0 )); then echo "All eligible PRs resolved."; break; fi
    if (( pass < MAX_PASSES )); then
      echo "  $remaining eligible PR(s) still open; sleeping ${SLEEP_SECONDS}s before next pass..."
      sleep "$SLEEP_SECONDS"
    fi
  done

  echo; echo "================= SUMMARY ================="
  echo "Total merged: $TOTAL_MERGED  (dry-run=$DRY_RUN)"
  if (( WORKFLOW_SCOPE_FAIL )); then
    echo
    echo "HINT: a merge failed because your gh token lacks the 'workflow' scope,"
    echo "      which is required to merge PRs that touch .github/workflows/* files"
    echo "      (e.g. Dependabot github_actions bumps). Add it with:"
    echo "          gh auth refresh -h github.com -s workflow"
    echo "      (org OAuth-app restrictions may also need an owner to approve it.)"
  fi
  if [[ -s "$WORK/skips" ]]; then
    echo; echo "Skipped (need a human — not low-risk):"
    sort -u "$WORK/skips" | awk -F'\t' '{printf "  %-30s %-16s %s\n",$1$2,$3,$4}'
  fi
  if [[ -n "${ABANDONED[*]+x}" ]]; then
    echo; echo "Abandoned (consistently red/blocked after $RED_STRIKES passes):"
    local k; for k in "${!ABANDONED[@]}"; do echo "  $k"; done | sort
  fi
}

# ----------------------------- main / config --------------------------------
main() {
  set -uo pipefail
  WORK=""; trap 'rm -rf "${WORK:-}" 2>/dev/null || true' EXIT

  # Snapshot env-provided knob values (they outrank the config file).
  declare -A _env; local k
  for k in "${DBM_KNOBS[@]}"; do [[ -n "${!k+x}" ]] && _env[$k]="${!k}"; done

  set_defaults

  # Pre-scan for --config / DBM_CONFIG so the file loads before other flags.
  local CONFIG_FILE="${DBM_CONFIG:-}" i=0 args=("$@")
  while (( i < ${#args[@]} )); do
    [[ "${args[i]}" == "--config" ]] && CONFIG_FILE="${args[i+1]:-}"
    i=$((i+1))
  done
  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || { echo "config file not found: $CONFIG_FILE" >&2; return 2; }
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi

  # Env overrides config.
  for k in "${!_env[@]}"; do printf -v "$k" '%s' "${_env[$k]}"; done

  # CLI flags override everything.
  while (( $# )); do
    case "$1" in
      --config) shift ;;                                   # already handled
      --owners) OWNERS="$2"; shift ;;
      --author) AUTHOR="$2"; shift ;;
      --execute) DRY_RUN=0 ;;
      --dry-run) DRY_RUN=1 ;;
      --max-passes) MAX_PASSES="$2"; shift ;;
      --sleep) SLEEP_SECONDS="$2"; shift ;;
      --red-strikes) RED_STRIKES="$2"; shift ;;
      --merge-method) MERGE_METHOD="$2"; shift ;;
      --pr-limit) PR_LIMIT="$2"; shift ;;
      --rebase-behind) REBASE_BEHIND=1 ;;
      --no-rebase-behind) REBASE_BEHIND=0 ;;
      --allow-major-actions) ALLOW_MAJOR_ACTIONS=1 ;;
      --no-allow-major-actions) ALLOW_MAJOR_ACTIONS=0 ;;
      --allow-major-docker) ALLOW_MAJOR_DOCKER=1 ;;
      --no-allow-major-docker) ALLOW_MAJOR_DOCKER=0 ;;
      --allow-major-deps) ALLOW_MAJOR_DEPS=1 ;;
      --no-allow-major-deps) ALLOW_MAJOR_DEPS=0 ;;
      --allow-groups) ALLOW_GROUPS=1 ;;
      --no-allow-groups) ALLOW_GROUPS=0 ;;
      -h|--help) usage; return 0 ;;
      *) echo "unknown arg: $1 (try --help)" >&2; return 2 ;;
    esac
    shift
  done

  run
}

# Run main only when executed, not when sourced (e.g. by the test suite).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
