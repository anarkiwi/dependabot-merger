#!/usr/bin/env bash
#
# Dependency-free unit tests for dependabot-merger.sh.
# Sources the script (which does NOT run main when sourced) and exercises the
# pure classification / version / CI-verdict helpers.
#
# Run:  ./tests/run_tests.sh        (or: make test)

# SC1091: the sourced path is computed at runtime; SC2034: knob vars set here
# are consumed by classify() in the sourced script, which shellcheck can't see.
# SC2016: literal backticks in the sample Dependabot bodies below are intended.
# shellcheck disable=SC1091,SC2034,SC2016
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dependabot-merger.sh
source "$HERE/../dependabot-merger.sh"
set_defaults   # establish knob defaults; individual tests override as needed

PASS=0; FAIL=0

# assert_eq <description> <expected> <actual>
assert_eq() {
  local desc="$1" exp="$2" act="$3"
  if [[ "$exp" == "$act" ]]; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n         expected: %q\n         actual:   %q\n' "$desc" "$exp" "$act"
  fi
}

echo "== extract_major =="
assert_eq ">=24.0 -> 24"                 24 "$(extract_major '>=24.0')"
assert_eq "0.2.0 -> 0"                   0  "$(extract_major '0.2.0')"
assert_eq "3.23 -> 3"                    3  "$(extract_major '3.23')"
assert_eq "prefers >= bound (left)"      9  "$(extract_major '<10,>=9.0.3')"
assert_eq "prefers >= bound (right)"     9  "$(extract_major '>=9.1.0,<10')"
assert_eq "leading v stripped"           1  "$(extract_major 'v1.2.3')"

echo "== classify (defaults) =="
set_defaults
assert_eq "actions minor -> low"         low "$(classify github_actions 'Bump actions/checkout from 6 to 7')"
assert_eq "docker same-major -> low"     low "$(classify docker 'Bump alpine from 3.23 to 3.24')"
assert_eq "docker major -> skip"         skip:docker-major "$(classify docker 'Bump ubuntu from 24.04 to 26.04')"
assert_eq "pip patch -> low"             low "$(classify pip 'Bump numpy from 2.4.4 to 2.4.6')"
assert_eq "pip major -> skip"            skip:dep-major "$(classify pip 'Bump os-ken from 2.11.2 to 4.2.1')"
assert_eq "grouped (no body) -> skip"    skip:grouped-update "$(classify pip 'Bump the pip group across 3 directories with 2 updates')"
assert_eq "actions group still low"      low "$(classify github_actions 'deps(actions): bump the actions group with 2 updates')"

GROUP_TITLE='Bump the pip group across 3 directories with 2 updates'
GROUP_MINOR_BODY='Bumps the pip group with 2 updates: requests and urllib3.

Updates `requests` from 2.28.0 to 2.31.0
- changelog

Updates `urllib3` from 1.26.0 to 1.26.18
- changelog'
GROUP_MAJOR_BODY='Bumps the pip group with 2 updates: requests and urllib3.

Updates `requests` from 2.28.0 to 2.31.0

Updates `urllib3` from 1.26.0 to 2.0.0'
assert_eq "grouped all-minor body -> low"  low "$(classify pip "$GROUP_TITLE" "$GROUP_MINOR_BODY")"
assert_eq "grouped major in body -> skip"  skip:grouped-update "$(classify pip "$GROUP_TITLE" "$GROUP_MAJOR_BODY")"
assert_eq "group_all_minor: minors -> low" low "$(group_all_minor "$GROUP_MINOR_BODY")"
assert_eq "group_all_minor: major -> skip" skip:grouped-update "$(group_all_minor "$GROUP_MAJOR_BODY")"
assert_eq "group_all_minor: empty -> skip" skip:grouped-update "$(group_all_minor '')"
assert_eq "requirement same major -> low" low "$(classify pip 'Update pytest requirement from <10,>=9.0.3 to >=9.1.0,<10')"
assert_eq "requirement major -> skip"    skip:dep-major "$(classify pip 'Update packaging requirement from >=24.0 to >=26.2')"

echo "== classify (knobs flipped) =="
set_defaults; ALLOW_MAJOR_DEPS=1
assert_eq "ALLOW_MAJOR_DEPS=1 -> low"    low "$(classify pip 'Bump os-ken from 2.11.2 to 4.2.1')"
set_defaults; ALLOW_MAJOR_DOCKER=1
assert_eq "ALLOW_MAJOR_DOCKER=1 -> low"  low "$(classify docker 'Bump ubuntu from 24.04 to 26.04')"
set_defaults; ALLOW_GROUPS=1
assert_eq "ALLOW_GROUPS=1 -> low"        low "$(classify pip 'Bump the pip group across 3 directories with 2 updates')"
set_defaults; ALLOW_MAJOR_ACTIONS=0
assert_eq "ALLOW_MAJOR_ACTIONS=0 major" skip:actions-major "$(classify github_actions 'Bump actions/checkout from 6 to 7')"
set_defaults

echo "== CI verdict (dbm_jq_ci) =="
ci_verdict() { jq -r "$(dbm_jq_ci)" | cut -f5; }
assert_eq "empty rollup -> none"   none    "$(echo '[{"number":1,"headRefName":"x","createdAt":"t","title":"t","statusCheckRollup":[]}]' | ci_verdict)"
assert_eq "all success -> green"   green   "$(echo '[{"number":1,"headRefName":"x","createdAt":"t","title":"t","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}]}]' | ci_verdict)"
assert_eq "a failure -> red"       red     "$(echo '[{"number":1,"headRefName":"x","createdAt":"t","title":"t","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"},{"status":"COMPLETED","conclusion":"FAILURE"}]}]' | ci_verdict)"
assert_eq "in-progress -> pending" pending "$(echo '[{"number":1,"headRefName":"x","createdAt":"t","title":"t","statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]}]' | ci_verdict)"
assert_eq "status ctx error -> red" red    "$(echo '[{"number":1,"headRefName":"x","createdAt":"t","title":"t","statusCheckRollup":[{"state":"ERROR","context":"ci"}]}]' | ci_verdict)"
assert_eq "skipped only -> green"  green   "$(echo '[{"number":1,"headRefName":"x","createdAt":"t","title":"t","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SKIPPED"}]}]' | ci_verdict)"

echo "== is_workflow_scope_err =="
GH_SCOPE_ERR='failed to merge pull request: refusing to allow an OAuth App to create or update workflow `.github/workflows/ci.yml` without `workflow` scope'
is_workflow_scope_err "$GH_SCOPE_ERR"; assert_eq "gh OAuth refusal"        0 "$?"
is_workflow_scope_err 'GraphQL: refusing to allow a Personal Access Token to create or update workflow `.github/workflows/x.yml` without `workflow` scope (mergePullRequest)'
assert_eq "gh PAT refusal"                                                 0 "$?"
is_workflow_scope_err 'Pull request is not mergeable: the base branch was modified'; assert_eq "unrelated merge failure" 1 "$?"
is_workflow_scope_err 'GraphQL: Resource not accessible by integration';   assert_eq "permission failure" 1 "$?"

echo "== git_land_pr (local repos) =="
# Exercises the real fallback mechanics — fast-forward land, merge-commit land
# when base has moved on, head-branch deletion — over a file:// remote.
GITDIR=$(mktemp -d); trap 'rm -rf "$GITDIR"' EXIT
git_q() { git -C "$1" -c user.name=t -c user.email=t@e -c init.defaultBranch=main "${@:2}" >/dev/null 2>&1; }

# origin: main with one commit, plus a "PR" branch on top of it.
mkdir -p "$GITDIR/work"
git -C "$GITDIR/work" init -q -b main >/dev/null 2>&1
echo base >"$GITDIR/work/f"; git_q "$GITDIR/work" add f; git_q "$GITDIR/work" commit -m base
git_q "$GITDIR/work" checkout -b pr
echo bumped >"$GITDIR/work/f"; git_q "$GITDIR/work" commit -am bump
git init -q --bare "$GITDIR/origin.git" >/dev/null 2>&1
git -C "$GITDIR/origin.git" config uploadpack.allowFilter true
git_q "$GITDIR/work" remote add origin "$GITDIR/origin.git"
git_q "$GITDIR/work" push origin main pr

land_err=$(git_land_pr "$GITDIR/c1" "$GITDIR/origin.git" main refs/heads/pr pr "merge pr" 2>&1)
assert_eq "ff land succeeds"      0 "$?"
assert_eq "ff land is silent"     "" "$land_err"
assert_eq "base has the bump"     bumped "$(git -C "$GITDIR/origin.git" show main:f)"
assert_eq "ff land is linear"     0 "$(git -C "$GITDIR/origin.git" rev-list --count --merges main)"
assert_eq "head branch deleted"   "" "$(git -C "$GITDIR/origin.git" for-each-ref --format='%(refname)' refs/heads/pr)"

# Second PR branched off the old base, with origin/main since moved on: needs a
# merge commit, and the reused checkout dir exercises the cached-clone path.
git_q "$GITDIR/work" checkout -b pr2 main
echo other >"$GITDIR/work/g"; git_q "$GITDIR/work" add g; git_q "$GITDIR/work" commit -m other
git_q "$GITDIR/work" push origin pr2
git_land_pr "$GITDIR/c1" "$GITDIR/origin.git" main refs/heads/pr2 pr2 "merge pr2" >/dev/null 2>&1
assert_eq "diverged land succeeds" 0 "$?"
assert_eq "merge commit created"   1 "$(git -C "$GITDIR/origin.git" rev-list --count --merges main)"
assert_eq "bump survives merge"    bumped "$(git -C "$GITDIR/origin.git" show main:f)"
assert_eq "pr2 file landed"        other  "$(git -C "$GITDIR/origin.git" show main:g)"

# A conflicting PR must fail cleanly rather than push anything.
git_q "$GITDIR/work" checkout -b pr3 main
echo conflicting >"$GITDIR/work/f"; git_q "$GITDIR/work" commit -am conflict
git_q "$GITDIR/work" push origin pr3
BEFORE=$(git -C "$GITDIR/origin.git" rev-parse main)
land_err=$(git_land_pr "$GITDIR/c1" "$GITDIR/origin.git" main refs/heads/pr3 pr3 "merge pr3" 2>&1)
assert_eq "conflicting land fails"  1 "$?"
assert_eq "conflict is reported"    1 "$([[ "$land_err" == *"cannot merge onto main"* ]] && echo 1 || echo 0)"
assert_eq "base untouched"          "$BEFORE" "$(git -C "$GITDIR/origin.git" rev-parse main)"
assert_eq "conflicting head kept"   1 "$(git -C "$GITDIR/origin.git" for-each-ref --format=x refs/heads/pr3 | wc -l)"

echo
echo "==================================="
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
