# driftr

[![CI](https://github.com/kova1max/driftr/actions/workflows/ci.yml/badge.svg)](https://github.com/kova1max/driftr/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/%40kova1%2Fdriftr?logo=npm&label=npm)](https://www.npmjs.com/package/@kova1/driftr)
[![License: MIT](https://img.shields.io/github/license/kova1max/driftr)](LICENSE)

Is it merged to prod everywhere? Are dev, stage and prod the same? driftr
answers that for every git repository under a directory.

You give it a chain of branches, upstream first - say `prod,stage,dev`. For
each repository and each adjacent pair (`prod -> stage`, `stage -> dev`) it
lists the commits the upstream branch has and the downstream branch is
missing, and the submodules whose recorded commit differs between the two.

```console
$ driftr ~/work
! api   prod -> stage  1 commit missing
    f716ef3 Fix login redirect loop
! api   stage -> dev   2 commits missing
    c0065e5 Bump timeout for slow uploads
    f7abc4b Add audit log export
- docs  origin/dev not found; skipping its pairs
= docs  prod -> stage  in sync
= web   prod -> stage  in sync
= web   stage -> dev   in sync

Repos: 3  in sync: 1  drifted: 1  skipped: 1  failed: 0
Drifted: api
```

Commits are compared by their patch, not their hash (`git log --cherry-pick`,
the same test as `git cherry`), so a hotfix cherry-picked from prod onto stage
and dev counts as present there - above, `web` is in sync although its
branches have different commits.

## Install

```sh
# npm
npm install -g @kova1/driftr
```

To try it without installing anything:

```sh
npx @kova1/driftr --chain main,staging,develop ~/work
```

## What it will never do

driftr only reads. It will never:

- **Write to a branch**, create a commit, or touch your working tree.
- **Fetch** unless you pass `--fetch`. Without it, driftr compares the
  remote-tracking branches (`origin/prod`, ...) as your last fetch left them.
  `--fetch` only updates remote-tracking refs.
- **Write any configuration**, except `driftr config --set`, which writes
  `driftr.chain` with `git config` and nothing else.
- **Enter a nested repository** or follow symlinked directories.

## Configure the branch chain

Teams name their environment branches differently - `prod`/`stage`/`dev`,
`main`/`staging`/`develop`, `acme-prod`/`acme-stage`/`acme-dev` - so driftr
keeps no names of its own. The chain is a comma-separated list of 2 or more
branches, upstream first. For each repository, driftr uses the first of:

1. `--chain LIST` on the command line, for every repository in the run.
2. `git config driftr.chain`, read in the repository, so git's usual layering
   applies: the repository's own `.git/config` wins over your global config,
   and a whole directory of repositories can share one setting through
   `includeIf` (below).
3. `task.env.prod`, `task.env.stage` and `task.env.dev` from git config, when
   all three are set: the chain is then prod, stage, dev. This is a
   convenience for people who already configure their environments for the
   `task` CLI that way; driftr does not need `task`.

A repository with none of these is reported as `no chain configured` and the
run goes on.

**For all your repositories:**

```sh
driftr config --set main,staging,develop --global
# the same as: git config --global driftr.chain main,staging,develop
```

**For one repository**, overriding the global one:

```sh
driftr config --set release,main ~/work/legacy-app
# the same as: git -C ~/work/legacy-app config driftr.chain release,main
```

**For every repository under a directory**, e.g. all your work repositories
in `~/work`, put the chain in its own file and include it from your global
config for repositories under that directory:

```ini
# ~/.gitconfig
[includeIf "gitdir:~/work/"]
    path = ~/.gitconfig-work
```

```ini
# ~/.gitconfig-work
[driftr]
    chain = acme-prod,acme-stage,acme-dev
```

Repositories elsewhere are unaffected, and a repository under `~/work` can
still override it with its own `driftr.chain`.

**Check what each repository resolves to**, and where it comes from:

```console
$ driftr config ~/work
api     origin/acme-prod -> origin/acme-stage -> origin/acme-dev  (driftr.chain, global config /Users/me/.gitconfig-work)
legacy  origin/release -> origin/main  (driftr.chain, local config .git/config)
tools   no chain configured: set driftr.chain, e.g. driftr config --set prod,stage,dev
```

### Branch names and remotes

A bare name such as `prod` is the branch on `origin`, i.e. `origin/prod`.
`--remote NAME` changes that remote. A name that starts with one of the
repository's remotes, such as `upstream/prod`, picks that remote's branch; any
other name with a slash, such as `release/2.0`, is a branch on the default
remote. A branch that does not exist in a repository is reported for that
repository, and only the pairs that involve it are skipped.

## Usage

```
driftr [options] [DIR]
driftr config [--chain LIST] [--remote NAME] [--max-depth N] [DIR]
driftr config --set LIST [--global | --repo] [DIR]
```

| Option&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; | Default | Meaning |
| :--- | :--- | :--- |
| `DIR` | current&nbsp;directory | Where to look for repositories. A repository itself works too. |
| `--chain LIST` | from git config | Branches to compare, upstream first, e.g. `prod,stage,dev`. See "Configure the branch chain". |
| `--remote NAME` | `origin` | The remote bare branch names refer to |
| `--max-depth N` | `2` | How many directory levels below `DIR` to search. `0` = only `DIR` itself, `1` = `DIR` and its direct children, ... |
| `--fetch` | off | Fetch the remotes each repository's chain uses before comparing, 8 repositories at a time. git never prompts for credentials. |
| `--md` | | Print a Markdown table instead, see below |
| `-q`, `--quiet` | | Only show pairs that drifted and repositories that failed, plus the summary |
| `--no-color` | | Disable colored output. Also disabled when the [`NO_COLOR`](https://no-color.org) environment variable is set, or when output is not a terminal. |
| `-V`, `--version` | | Print the version |
| `-h`, `--help` | | Show help |

`driftr config` takes `--chain`, `--remote` and `--max-depth` to show what a
run would use, and `--set LIST` to write `driftr.chain`: into the repository
at `DIR` (`--repo`, the default) or into your global config (`--global`).

### Output

Each pair gets one line: `!` drifted, with the missing commits (newest first)
and differing submodules indented below it, or `=` in sync. A repository that
could not be checked gets a `-` line saying why (no chain configured, a branch
not found) or, with `--fetch`, an `x` line when the fetch failed.

Exits `1` if any pair drifted or any fetch failed, `2` on invalid arguments,
`0` otherwise. A repository with no chain or a missing branch is not drift.

Merge commits are not listed: the commits they bring in are. A commit whose
patch changed while it was cherry-picked, for example to resolve a conflict,
no longer matches the original and is listed as missing.

### Markdown

`--md` prints the same results as a Markdown table, for a pull request, a
Jira ticket or anything else that renders Markdown tables:

```console
$ driftr --md --quiet ~/work
| Repo | Pair | Missing | Details |
| :--- | :--- | ---: | :--- |
| api | prod → stage | 1 | `f716ef3` Fix login redirect loop |
| api | stage → dev | 2 | `c0065e5` Bump timeout for slow uploads<br>`f7abc4b` Add audit log export |

Repos: 3  in sync: 1  drifted: 1  skipped: 1  failed: 0
Drifted: api
```

## License

[MIT](LICENSE)
