#!/usr/bin/env bats
# End-to-end tests: build a real remote with prod, stage and dev branches plus
# clones of it in a temp dir, then run driftr against them.
# DRIFTR_BASH picks the interpreter, so CI can also cover macOS's bash 3.2.

setup() {
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  : >"$GIT_CONFIG_GLOBAL"
  DRIFTR="$BATS_TEST_DIRNAME/../bin/driftr"
  cd "$BATS_TEST_TMPDIR"

  git init -q --bare -b prod origin.git
  git clone -q origin.git seed 2>/dev/null
  echo base >seed/file && git -C seed add file && git -C seed commit -q -m base
  git -C seed push -q origin prod
  git -C seed push -q origin prod:stage prod:dev
  mkdir ws
}

driftr() {
  "${DRIFTR_BASH:-bash}" "$DRIFTR" "$@"
}

clone() {
  git clone -q origin.git "ws/$1" 2>/dev/null
}

# commit_on BRANCH MESSAGE: a commit that adds a file named after MESSAGE.
commit_on() {
  git -C seed checkout -q "$1" 2>/dev/null || git -C seed checkout -q -b "$1" "origin/$1"
  echo "$2" >"seed/$2" && git -C seed add "$2" && git -C seed commit -q -m "$2"
  git -C seed push -q origin "$1"
}

# cherry_pick SHA BRANCH: copy a commit onto another branch, as a new commit.
cherry_pick() {
  git -C seed checkout -q "$2" 2>/dev/null || git -C seed checkout -q -b "$2" "origin/$2"
  git -C seed cherry-pick "$1" >/dev/null
  git -C seed push -q origin "$2"
}

@test "a chain with no drift is in sync and exits 0" {
  clone api
  run driftr --chain prod,stage,dev ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"= api  prod -> stage  in sync"* ]]
  [[ "$output" == *"= api  stage -> dev   in sync"* ]]
  [[ "$output" == *"Repos: 1  in sync: 1  drifted: 0  skipped: 0  failed: 0"* ]]
}

@test "a commit on prod that stage is missing is reported, and exits 1" {
  commit_on prod hotfix
  clone api
  run driftr --chain prod,stage,dev ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! api  prod -> stage  1 commit missing"* ]]
  [[ "$output" == *"    $(git -C seed rev-parse --short prod) hotfix"* ]]
  [[ "$output" == *"= api  stage -> dev   in sync"* ]]
  [[ "$output" == *"drifted: 1"* ]]
  [[ "$output" == *"Drifted: api"* ]]
}

@test "a cherry-picked copy counts as present" {
  commit_on prod hotfix
  cherry_pick "$(git -C seed rev-parse prod)" stage
  cherry_pick "$(git -C seed rev-parse prod)" dev
  clone api
  [ "$(git -C ws/api rev-parse origin/prod)" != "$(git -C ws/api rev-parse origin/stage)" ]
  run driftr --chain prod,stage,dev ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"= api  prod -> stage  in sync"* ]]
  [[ "$output" == *"= api  stage -> dev   in sync"* ]]
}

@test "only commits missing downstream count, not ones the downstream branch has extra" {
  commit_on prod hotfix
  commit_on stage feature
  cherry_pick "$(git -C seed rev-parse prod)" stage
  commit_on prod another
  clone api
  run driftr --chain prod,stage ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! api  prod -> stage  1 commit missing"* ]]
  [[ "$output" == *" another"* ]]
  [[ "$output" != *" hotfix"* && "$output" != *" feature"* ]]
}

@test "merge commits are not reported, the commits they bring are" {
  git -C seed checkout -q -b topic
  echo x >seed/x && git -C seed add x && git -C seed commit -q -m topic-work
  git -C seed checkout -q prod
  git -C seed merge -q --no-ff -m "Merge topic" topic
  git -C seed push -q origin prod
  clone api
  run driftr --chain prod,stage ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 commit missing"* ]]
  [[ "$output" == *" topic-work"* ]]
  [[ "$output" != *"Merge topic"* ]]
}

@test "a missing branch is reported and only its pairs are skipped" {
  clone api
  run driftr --chain prod,stage,qa ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"- api  origin/qa not found; skipping its pairs"* ]]
  [[ "$output" == *"= api  prod -> stage  in sync"* ]]
  [[ "$output" != *"stage -> qa"* ]]
  [[ "$output" == *"Repos: 1  in sync: 0  drifted: 0  skipped: 1  failed: 0"* ]]
}

@test "a branch named twice in a chain is reported missing once" {
  clone api
  run driftr --chain qa,stage,qa ws
  [ "$status" -eq 0 ]
  [ "$(grep -c "origin/qa not found" <<<"$output")" -eq 1 ]
}

@test "a repository with no chain is reported, the run goes on" {
  commit_on prod hotfix
  clone a-configured
  clone b-plain
  git -C ws/a-configured config driftr.chain prod,stage
  run driftr ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! a-configured  prod -> stage  1 commit missing"* ]]
  [[ "$output" == *"- b-plain       no chain configured: set driftr.chain, e.g. driftr config --set prod,stage,dev"* ]]
  [[ "$output" == *"Repos: 2  in sync: 0  drifted: 1  skipped: 1  failed: 0"* ]]
}

@test "no chain anywhere is not drift: exits 0" {
  clone api
  run driftr ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"- api  no chain configured"* ]]
}

@test "an invalid driftr.chain is reported for that repository" {
  clone api
  git -C ws/api config driftr.chain prod
  run driftr ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"- api  invalid chain 'prod' (driftr.chain, local config .git/config): needs 2 or more"* ]]
}

# Submodule lib is at L1 on prod; a commit on stage moves it to L2. Prod has
# no commit that stage lacks, so only the pointer differs.
@test "a submodule pointer difference is drift" {
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  git init -q --bare -b main lib.git
  git clone -q lib.git libw 2>/dev/null
  git -C libw commit -q --allow-empty -m L1 && git -C libw push -q origin main
  git -C seed submodule add -q "$BATS_TEST_TMPDIR/lib.git" lib 2>/dev/null
  git -C seed commit -q -m "add lib" && git -C seed push -q origin prod
  git -C seed push -q -f origin prod:stage
  local l1 l2
  l1="$(git -C libw rev-parse --short=7 HEAD)"
  git -C libw commit -q --allow-empty -m L2 && git -C libw push -q origin main
  l2="$(git -C libw rev-parse --short=7 HEAD)"
  git -C seed checkout -q -b stage origin/stage
  git -C seed/lib pull -q origin main 2>/dev/null
  git -C seed commit -q -am "bump lib" && git -C seed push -q origin stage
  clone api
  run driftr --chain prod,stage ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! api  prod -> stage  1 submodule differs"* ]]
  [[ "$output" == *"    submodule lib: $l1 on prod, $l2 on stage"* ]]
}

@test "--md prints a Markdown table" {
  commit_on prod "fix | pipe"
  clone api
  clone docs
  git -C ws/api config driftr.chain prod,stage,dev
  run driftr --md ws
  [ "$status" -eq 1 ]
  local sha
  sha="$(git -C seed rev-parse --short prod)"
  [ "${lines[0]}" = "| Repo | Pair | Missing | Details |" ]
  [ "${lines[1]}" = "| :--- | :--- | ---: | :--- |" ]
  [ "${lines[2]}" = "| api | prod → stage | 1 | \`$sha\` fix \\| pipe |" ]
  [ "${lines[3]}" = "| api | stage → dev | 0 |  |" ]
  [ "${lines[4]}" = "| docs |  | - | no chain configured: set driftr.chain, e.g. driftr config --set prod,stage,dev |" ]
  [ "${lines[5]}" = "Repos: 2  in sync: 0  drifted: 1  skipped: 1  failed: 0" ]
  [[ "$output" != *$'\e['* ]]
}

@test "--quiet shows only drift" {
  commit_on prod hotfix
  clone api
  clone docs
  clone web
  git -C ws/api config driftr.chain prod,stage,dev
  git -C ws/web config driftr.chain stage,dev
  run driftr -q ws
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "! api  prod -> stage  1 commit missing" ]
  [ "${lines[1]}" = "    $(git -C seed rev-parse --short prod) hotfix" ]
  [ "${lines[2]}" = "Repos: 3  in sync: 1  drifted: 1  skipped: 1  failed: 0" ]
  [ "${#lines[@]}" -eq 4 ]
  run driftr --quiet --chain stage,dev ws
  [ "$status" -eq 0 ]
  [ "$output" = "Repos: 3  in sync: 3  drifted: 0  skipped: 0  failed: 0" ]
}

@test "reads only: without --fetch the remote's new commits are not seen" {
  clone api
  commit_on prod hotfix
  local before
  before="$(git -C ws/api for-each-ref)"
  run driftr --chain prod,stage ws
  [ "$status" -eq 0 ]
  [ "$(git -C ws/api for-each-ref)" = "$before" ]
  [ -z "$(git -C ws/api status --porcelain)" ]
}

@test "--fetch updates remote-tracking branches first" {
  clone api
  commit_on prod hotfix
  run driftr --fetch --chain prod,stage ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! api  prod -> stage  1 commit missing"* ]]
  [ "$(git -C ws/api rev-parse origin/prod)" = "$(git -C origin.git rev-parse prod)" ]
  [ "$(git -C ws/api rev-parse HEAD)" = "$(git -C origin.git rev-parse stage)" ]
}

@test "--fetch reports a failed fetch, keeps going, exits 1" {
  clone a-broken
  clone b-fine
  git -C ws/a-broken remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
  run driftr --fetch --chain prod,stage ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"x a-broken  fetch failed:"* ]]
  [[ "$output" == *"= b-fine    prod -> stage  in sync"* ]]
  [[ "$output" == *"failed: 1"* && "$output" == *"Failed: a-broken"* ]]
}

@test "bare names use --remote, remote/name picks a remote" {
  commit_on prod hotfix
  git clone -q -o upstream origin.git ws/api 2>/dev/null
  run driftr --chain prod,stage ws
  [[ "$output" == *"origin/prod not found"* ]]
  run driftr --remote upstream --chain prod,stage ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! api  prod -> stage  1 commit missing"* ]]
  run driftr --chain upstream/prod,upstream/stage ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! api  upstream/prod -> upstream/stage  1 commit missing"* ]]
}

@test "a branch name with a slash that is not a remote is a branch on the remote" {
  git -C seed push -q origin prod:release/1
  commit_on prod hotfix
  clone api
  run driftr --chain prod,release/1 ws
  [ "$status" -eq 1 ]
  [[ "$output" == *"! api  prod -> release/1  1 commit missing"* ]]
}

# --- chain resolution --------------------------------------------------------

@test "chain resolution order: --chain, then driftr.chain, then task.env" {
  clone api
  git -C ws/api config task.env.prod prod
  git -C ws/api config task.env.stage stage
  git -C ws/api config task.env.dev dev
  run driftr config ws
  [ "$output" = "api  origin/prod -> origin/stage -> origin/dev  (task.env.prod, task.env.stage, task.env.dev)" ]

  git config --global driftr.chain prod,dev
  run driftr config ws
  [ "$output" = "api  origin/prod -> origin/dev  (driftr.chain, global config $GIT_CONFIG_GLOBAL)" ]

  git -C ws/api config driftr.chain stage,dev
  run driftr config ws
  [ "$output" = "api  origin/stage -> origin/dev  (driftr.chain, local config .git/config)" ]

  run driftr config --chain prod,stage ws
  [ "$output" = "api  origin/prod -> origin/stage  (--chain)" ]
}

@test "the chain a run uses comes from the same resolution" {
  commit_on prod hotfix
  clone api
  git -C ws/api config task.env.prod prod
  git -C ws/api config task.env.stage stage
  git -C ws/api config task.env.dev dev
  run driftr ws
  [[ "$output" == *"! api  prod -> stage  1 commit missing"* ]]
  git -C ws/api config driftr.chain stage,dev
  run driftr ws
  [ "$status" -eq 0 ]
  [[ "$output" == *"= api  stage -> dev  in sync"* ]]
  [[ "$output" != *"prod"* ]]
}

@test "task.env fallback needs all three of prod, stage and dev" {
  clone api
  git -C ws/api config task.env.prod prod
  git -C ws/api config task.env.stage stage
  run driftr config ws
  [[ "$output" == "api  no chain configured"* ]]
}

@test "driftr.chain applies to every repository under a directory via includeIf" {
  clone a
  clone b
  mkdir elsewhere
  git clone -q origin.git elsewhere/c 2>/dev/null
  printf '[driftr]\n\tchain = prod, stage, dev\n' >work.gitconfig
  git config --global "includeIf.gitdir:$(cd ws && pwd -P)/.path" "$BATS_TEST_TMPDIR/work.gitconfig"
  run driftr config ws
  [[ "$output" == *"a  origin/prod -> origin/stage -> origin/dev  (driftr.chain, global config $BATS_TEST_TMPDIR/work.gitconfig)"* ]]
  [[ "$output" == *"b  origin/prod -> origin/stage -> origin/dev  (driftr.chain, global config $BATS_TEST_TMPDIR/work.gitconfig)"* ]]
  run driftr config elsewhere
  [[ "$output" == "c  no chain configured"* ]]
}

@test "driftr config on one repository shows just that one" {
  clone api
  run driftr config ws/api
  [ "$status" -eq 0 ]
  [[ "$output" == ".  no chain configured"* ]]
}

@test "config --set writes driftr.chain to the repository, normalised" {
  clone api
  run driftr config --set " prod , stage,dev" ws/api
  [ "$status" -eq 0 ]
  [ "$(git -C ws/api config --local --get driftr.chain)" = "prod,stage,dev" ]
  [ -z "$(git config --global --get driftr.chain)" ]
  run driftr config --set prod,stage --repo ws/api
  [ "$(git -C ws/api config --local --get driftr.chain)" = "prod,stage" ]
}

@test "config --set --global writes your global config only" {
  clone api
  run driftr config --set prod,stage --global
  [ "$status" -eq 0 ]
  [ "$output" = "driftr.chain = prod,stage (global config)" ]
  [ "$(git config --global --get driftr.chain)" = "prod,stage" ]
  [ -z "$(git -C ws/api config --local --get driftr.chain)" ]
}

@test "config --set refuses a directory that is not a repository" {
  run driftr config --set prod,stage ws
  [ "$status" -eq 2 ]
  [[ "$output" == *"Not a git repository"* ]]
}

# --- arguments ---------------------------------------------------------------

@test "rejects invalid arguments with exit 2" {
  run driftr --chain prod ws
  [ "$status" -eq 2 ]
  [[ "$output" == *"needs 2 or more"* ]]
  run driftr --chain prod,,dev ws
  [ "$status" -eq 2 ]
  run driftr --chain
  [ "$status" -eq 2 ]
  run driftr --max-depth x
  [ "$status" -eq 2 ]
  run driftr --nope
  [ "$status" -eq 2 ]
  run driftr ws ws
  [ "$status" -eq 2 ]
  run driftr does-not-exist
  [ "$status" -eq 2 ]
  run driftr --set prod,stage ws
  [ "$status" -eq 2 ]
  run driftr config --md ws
  [ "$status" -eq 2 ]
  run driftr config --global ws
  [ "$status" -eq 2 ]
  run driftr config --set prod --global
  [ "$status" -eq 2 ]
  run driftr config --set prod,stage --global ws
  [ "$status" -eq 2 ]
}

@test "--version prints the package.json version" {
  local expected
  expected="$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$BATS_TEST_DIRNAME/../package.json")"
  run driftr --version
  [ "$status" -eq 0 ]
  [ "$output" = "driftr $expected" ]
}

@test "--help documents the chain sources" {
  run driftr --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"git config driftr.chain"* ]]
  [[ "$output" == *"task.env.prod"* ]]
}

# --- discovery ---------------------------------------------------------------

@test "default max depth is 2, --max-depth reaches deeper" {
  mkdir -p ws/a/b
  clone a/two
  clone a/b/three
  run driftr --chain prod,stage ws
  [[ "$output" == *"a/two"* && "$output" != *"three"* ]]
  run driftr --max-depth 3 --chain prod,stage ws
  [[ "$output" == *"a/b/three"* ]]
}

@test "defaults to the current directory" {
  clone here
  cd ws
  run driftr --chain prod,stage
  [ "$status" -eq 0 ]
  [[ "$output" == *"= here  prod -> stage  in sync"* ]]
}

@test "reports when no repositories are found" {
  run driftr ws
  [ "$status" -eq 0 ]
  [[ "$output" == "No git repositories found under "*" (max depth 2)" ]]
}

# Runs driftr with stdout on a pseudo-terminal, so its color decision sees a TTY.
driftr_tty() {
  python3 - "${DRIFTR_BASH:-bash}" "$DRIFTR" "$@" <<'PY'
import os, subprocess, sys
leader, follower = os.openpty()
proc = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=follower, stderr=follower)
os.close(follower)
out = b""
while True:
    try:
        chunk = os.read(leader, 4096)
    except OSError:  # Linux raises EIO once the child closes its side
        break
    if not chunk:
        break
    out += chunk
sys.stdout.write(out.decode().replace("\r\n", "\n"))
sys.exit(proc.wait())
PY
}

@test "colors output on a terminal, unless NO_COLOR or --no-color" {
  clone api
  run driftr_tty --chain prod,stage ws
  [[ "$output" == *$'\e[2m='* ]]
  NO_COLOR=1 run driftr_tty --chain prod,stage ws
  [[ "$output" != *$'\e['* ]]
  run driftr_tty --no-color --chain prod,stage ws
  [[ "$output" != *$'\e['* ]]
}
