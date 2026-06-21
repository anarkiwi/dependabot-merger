#!/usr/bin/env bash
#
# Dependency-free unit tests for dependabot-merger.sh.
# Sources the script (which does NOT run main when sourced) and exercises the
# pure classification / version / CI-verdict helpers.
#
# Run:  ./tests/run_tests.sh        (or: make test)

# SC1091: the sourced path is computed at runtime; SC2034: knob vars set here
# are consumed by classify() in the sourced script, which shellcheck can't see.
# shellcheck disable=SC1091,SC2034
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
assert_eq "grouped -> skip"              skip:grouped-update "$(classify pip 'Bump the pip group across 3 directories with 2 updates')"
assert_eq "actions group still low"      low "$(classify github_actions 'deps(actions): bump the actions group with 2 updates')"
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

echo
echo "==================================="
echo "PASS: $PASS   FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
