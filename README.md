# dependabot-merger

Multi-pass, parallel auto-merger for **low-risk Dependabot / CI pull requests**
across one or more GitHub owners (users or orgs).

It discovers every open Dependabot PR, decides which are low-risk, and merges
them as their checks go green — one merge per repo per pass (so the rest rebase
cleanly), repos handled in parallel — looping until everything mergeable is
merged or the rest are *consistently* red.

## How it works

Each **pass**:

1. Discover all open PRs by `app/dependabot` across `$OWNERS`
   (`gh search prs`).
2. Classify each PR as **low-risk** (auto-mergeable) or **skip** (needs a
   human), using the ecosystem from the branch name (`dependabot/<eco>/…`)
   plus a version parse of the title.
3. For every repo **in parallel**, merge at most **one** green + clean PR
   (oldest first) so the remaining PRs in that repo rebase cleanly.
4. Record why anything wasn't merged: red CI, conflict, behind, blocked.

It then sleeps (letting Dependabot rebase and CI re-run) and starts the next
pass. A PR that stays red/blocked for `RED_STRIKES` passes is abandoned. The
run stops when nothing mergeable remains.

### What counts as low-risk (defaults)

| Change | Default |
| --- | --- |
| GitHub Actions bumps (incl. major) | ✅ merge |
| Patch/minor library bumps | ✅ merge |
| Same-major Docker base-image bumps (e.g. `3.23 → 3.24`) | ✅ merge |
| Major library bumps | ⏭️ skip (`ALLOW_MAJOR_DEPS=1` to enable) |
| Major Docker bumps (e.g. `ubuntu 24 → 26`) | ⏭️ skip (`ALLOW_MAJOR_DOCKER=1`) |
| Grouped PRs where every member is minor/patch | ✅ merge |
| Grouped PRs containing a major bump | ⏭️ skip (`ALLOW_GROUPS=1` to force) |

A PR is only merged if it is also mergeable and its required checks are green.

### Workflow PRs (SSH fallback)

The GitHub merge API refuses any PR touching `.github/workflows/*` unless the
token carries the `workflow` scope — which blocks most Dependabot
`github_actions` bumps, and cannot always be granted (org OAuth-app policy).

SSH keys carry no OAuth scopes, so when the API refuses, the merge is redone as
a plain git push over SSH: fetch the base and `refs/pull/<n>/head` into a
reusable blobless checkout, fast-forward (or build a merge commit if base has
moved on), push to the base branch, delete the head branch. The PR head SHA
lands in base, so GitHub marks the PR **merged**, not just closed. Such merges
are reported as `MERGED-SSH`.

Because the SHA must survive, this path always fast-forwards or merges;
`MERGE_METHOD` (squash/rebase) does not apply to it. Branch protection still
applies — a protected base rejects the push and the PR is left alone.

Needs `git` and an SSH key registered with GitHub (`ssh -T git@github.com`).
Disable with `--no-ssh-fallback`; use `--ssh-always` to skip the API entirely
when the token is known to lack the scope.

## Requirements

- [`gh`](https://cli.github.com/) (authenticated: `gh auth login`)
- `jq`
- `bash` 4+
- `git` + an SSH key registered with GitHub (for the workflow-PR fallback)

## Usage

```bash
./dependabot-merger.sh                       # dry-run (safe preview), default owners
./dependabot-merger.sh --execute             # actually merge
./dependabot-merger.sh --owners "me myorg" --execute
./dependabot-merger.sh --config ./my.conf --execute
ALLOW_GROUPS=1 ./dependabot-merger.sh --execute
```

**Safe by default:** without `--execute` it changes nothing — it prints what it
*would* merge, plus the skipped/red lists. Run a dry-run first.

See `./dependabot-merger.sh --help` for all flags.

## Configuration

Precedence (highest wins): **CLI flags → environment variables → config file →
built-in defaults**. Every flag has an equivalent env var.

| Knob | Default | Meaning |
| --- | --- | --- |
| `OWNERS` | `anarkiwi c65sdn` | space-separated owners to scan |
| `AUTHOR` | `app/dependabot` | PR author to act on |
| `DRY_RUN` | `1` | `1` preview, `0` merge (`--execute`) |
| `MAX_PASSES` | `30` | safety cap on passes |
| `SLEEP_SECONDS` | `45` | wait between passes |
| `RED_STRIKES` | `3` | red passes before abandoning a PR |
| `MERGE_METHOD` | `auto` | `auto`/`squash`/`rebase`/`merge` |
| `PR_LIMIT` | `100` | max PRs fetched per repo |
| `REBASE_BEHIND` | `1` | comment `@dependabot rebase` on behind PRs |
| `SSH_FALLBACK` | `1` | `0` off, `1` merge over SSH when the API refuses for lack of `workflow` scope, `always` never use the API |
| `SSH_HOST` | `github.com` | SSH target (`git@$SSH_HOST:owner/repo.git`) |
| `ALLOW_MAJOR_ACTIONS` | `1` | merge Actions major bumps |
| `ALLOW_MAJOR_DOCKER` | `0` | merge Docker major bumps |
| `ALLOW_MAJOR_DEPS` | `0` | merge library major bumps |
| `ALLOW_GROUPS` | `0` | `1` = merge any grouped PR (incl. major bumps); all-minor groups merge regardless |

Copy `dependabot-merger.conf.example` to `dependabot-merger.conf`, edit, and
pass `--config dependabot-merger.conf` (or set `DBM_CONFIG`).

## Development

```bash
make lint    # shellcheck
make test    # unit tests (no external deps beyond jq)
make check   # both
```

CI runs `make lint` and `make test` on every push and PR.
