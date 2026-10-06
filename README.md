# engineering-practices

The engineering practices Hugo's repositories follow, and the GitHub Action that enforces the ones a
machine can check.

- [PRACTICES.md](PRACTICES.md) is the registry: one row per practice, with its source, its enforcer, what
  it prevents, what it costs when it fires wrongly and who pays.
- `action.yml` is a composite action every repository runs on its pull requests. It does two things:
  1. **Fails the pull request if it adds dead code or lint findings.** Dead code (practice C1): unused
     files, exports and dependencies in TypeScript/JavaScript ([knip](https://knip.dev)), unreachable
     functions in Go ([deadcode](https://pkg.go.dev/golang.org/x/tools/cmd/deadcode)), and in Python the
     [ruff](https://docs.astral.sh/ruff/) F rules: unused imports and variables, undefined names,
     redefinitions. Lint (practice C5), from each linter the repository turns on: its own
     [ESLint](https://eslint.org) with its config and plugins, [staticcheck](https://staticcheck.dev)
     for Go, and [ShellCheck](https://www.shellcheck.net) for the shell scripts the pull request
     changes. A banned pattern (practice C6), found by [semgrep](https://semgrep.dev) with
     `rules/banned-patterns.yml` and the repository's own rules: a word list or word regex that decides
     what a person meant, a regex over SQL, HTML or XML, and, listed for the reviewer without failing, a
     domain vocabulary fixed in code. Only lines the pull request adds count
     ([reviewdog](https://github.com/reviewdog/reviewdog) filters the rest), so an existing finding fails
     a pull request only when it edits that line (see "What counts as added" below). The gate also fails
     when input the repository owns is broken: `.github/quality.yml` does not parse, `npm ci` rejects the
     lockfile (missing, out of step with `package.json`, or unparseable), knip, ruff or ESLint reports a
     configuration error, the ESLint root does not install ESLint, `go.mod` does not parse, deadcode or
     staticcheck cannot load the repository's Go code, `python.roots` or a `semgrep` path names a missing
     file, ShellCheck rejects `shellcheck.args`, or semgrep cannot load the repository's rule files. A
     tool or dependency that cannot be downloaded or installed, or a tool that
     times out, shows "not run" with its reason, raises a warning, and passes.
  2. **Posts a Quality report** for the reviewer, as one pull request comment updated in place and as the
     job summary: proof weight per path class, new duplicate code as exact token clones
     ([jscpd](https://github.com/kucherenko/jscpd)), Python definitions nothing references
     ([vulture](https://github.com/jendrikseipp/vulture), confidence 60 and up), and test-job runtime
     against main. These fail nothing. A measure that could not be computed says "not run" and why, and
     one that could not read a file the pull request changes says "partial" and names the file.

## Adopt it

Add one job to the repository's pull-request workflow:

```yaml
  quality:
    if: ${{ github.event_name == 'pull_request' && !cancelled() }}
    needs: [test]            # the test jobs named in quality.yml, so their runtime is known; or drop it
    runs-on: ubuntu-latest
    timeout-minutes: 15      # a hung step must not leave the check pending, which holds merges
    concurrency:
      group: quality-${{ github.workflow }}-${{ github.event.pull_request.number }}
      cancel-in-progress: true
    permissions:
      contents: read
      pull-requests: write   # the sticky comment
      actions: read          # test-job runtimes
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0     # the merge base must be present
          # Keep the default ref: on pull_request it is the merge ref the base is measured against.
          persist-credentials: false
      - uses: Artexis10/engineering-practices@v1
```

Then commit `.github/quality.yml` (below). The workflow should also run on pushes to the default branch,
so the runtime measure has main runs to compare with.

The action runs on Linux x86_64 and needs `git`, `curl`, `jq` and `python3`, plus `node` when JavaScript
or ESLint is configured and `go` when Go is. GitHub's `ubuntu-latest` has all of them. Every tool is
pinned: reviewdog, yq, ShellCheck, deadcode and staticcheck in `scripts/checks.sh`, knip and jscpd with
their whole dependency tree and its digests in `tools/package-lock.json`, ruff and vulture by digest in
`tools/requirements.txt`, semgrep with its whole dependency tree by digest in
`tools/semgrep-requirements.txt`, and ESLint by the repository's own lockfile.

Pull requests from forks get a read-only token whatever the job declares, so their report appears in
the job summary only, and the summary gives GitHub's answer. Dependabot pull requests run with the
permissions the job declares.

**The gate runs the pull request's code.** `npm ci --ignore-scripts` skips install scripts only. knip
and ESLint then load the repository's config files (knip's own and those its plugins read, such as
`vite.config.ts`; ESLint's config and its plugins) and whatever they import, as the repository's test
jobs would. So check out with
`persist-credentials: false`, keep tokens out of the job's environment (the action passes its token
to the report step only), and run it on `pull_request`; the action refuses `pull_request_target`,
which would hand that code a write token and the repository's secrets. That code can still write
`$GITHUB_ENV` and `$GITHUB_PATH` and so reach the report step, which holds the job's token; this matters
for Dependabot runs, which get the permissions the job declares. The fix, not yet done, is to run the
report in a separate job that executes no repository code.

**What counts as added.** A finding fails the gate only on a line the pull request adds, measured against
the base branch as it is now: on the merge ref that `actions/checkout` checks out, that is HEAD's first
parent, so commits that land on the base branch after the pull request opened are not counted as its
lines. On any other checkout it is the merge base with the base branch as fetched
(`origin/<base branch>`), or with the event's base commit when that branch was not fetched. An unused file
counts only when the pull request adds the file, and an unused dependency only when the merge base did
not declare it, so editing an old unused file or bumping an old unused dependency passes. Editing the
declaration line of an export, function or import that was already unused still fails, because that line
counts as added: delete it, or leave that line alone. A moved line counts as added too, so moving an old
unused import fails: delete it, or run `ruff check --fix`. ShellCheck runs only on the shell scripts the
pull request adds or changes: `*.sh` and `*.bash` files, and files whose first line is a `sh`, `bash`,
`dash` or `ksh` shebang. It skips templates (`*.j2`, `*.jinja`, `*.jinja2`, `*.tmpl`, `*.tpl`), because
a rendered template is not the file in the repository, and any path `shellcheck.exclude` matches.

**ruff and the repository's own config.** The gate runs `ruff check --select F`, which replaces the rule
selection in the repository's ruff config, a global `ignore` of F codes included: silence those with
`per-file-ignores` (for example `__init__.py = ["F401"]` for re-exports) or `# noqa`, which still apply,
as do excludes. A Python file that does not parse is reported on its added lines too. A ruff config the
pinned ruff cannot load fails the gate on purpose, so keep it compatible with the version in
`tools/requirements.txt`.

**Linters and their own config.** ESLint runs as `eslint --format json <args>` in `eslint.root`, with
the repository's config. Only errors count, so a rule set to `warn` does not fail. ESLint only warns
about a file that no config object matches, so a config that matches no file passes silently: check
that `eslint.root` and `args` reach the files you expect. staticcheck runs the
checks the repository's `staticcheck.conf` selects and honours `//lint:ignore`. Its findings go through
the same per-GOOS rule and `go.ignore` as deadcode. staticcheck builds with the build tags in `GOFLAGS`,
while deadcode ignores them. ShellCheck reads `.shellcheckrc` and `# shellcheck disable=` comments.
The action runs it with `--severity=warning`, so only warnings and errors count; notes and style
findings, such as SC2086 quoting, do not. A `--severity` in `shellcheck.args` comes later and wins.
A Go file whose path contains a space or a colon does not match the diff, so deadcode and staticcheck
findings in it are dropped.

**Banned patterns.** semgrep reads the files the pull request changes under `semgrep.paths` (each rule
reads one file at a time, so no other file can change a finding) and reviewdog keeps the findings on
added lines. A rule of severity ERROR fails the gate; WARNING and INFO findings are listed in the report
for the reviewer. Each rule's message says what the pattern usually is, the sound shapes, and when to keep
it: a line that checks a field's format, or reads a closed machine format, may keep a finding with
`# nosemgrep: <rule-id> -- <reason>`, which review checks. A repository adds its own stricter bans as
semgrep rule files under `semgrep.rules`, with the same severities. semgrep runs as one job with 120
seconds per rule and file; a file it gives up on, in whole or in one long function, makes the result
"partial" and names the file.

**Time.** The action has one time budget, `EP_BUDGET` seconds (default 600), from the start of its first
step. Each download and each tool runs for at most 600 seconds or what is left of the budget, and a step
that cannot start or finish within it reports "not run" and a warning. The report may run 60 seconds past
the budget to post; a runtime measure or comment it cannot finish by then says "not run: time budget used
up". So the action ends within 11 minutes of starting, leaving room inside `timeout-minutes: 15` for job
setup and steps before the action (for example setup-go).

## `.github/quality.yml`

Every key is optional. A language or linter key that is absent turns its check off, and the report shows it as
"not configured".

**Path classes default to product.** A path belongs in a proof class (tests, fixtures, eval, scripts,
tooling or another name you choose) only if it never runs in a build, deploy, image, scheduled job or
runtime import, and never ships in a bundle. A deploy or migration script, a data-changing script, or a
mock that ships in the production bundle is product. Name proof tooling by file or by a narrow glob,
never a whole `scripts/` directory.

These lockfiles are always "generated" at any depth, whatever class you list also matches them:
`package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `bun.lock`, `bun.lockb`,
`Cargo.lock`, `go.sum`, `uv.lock`, `poetry.lock`, `Pipfile.lock`, `composer.lock` and `Gemfile.lock`.

```yaml
# Path classes for proof weight. Patterns are glob patterns on repository-relative paths, where `*`
# also matches `/` (so `*.test.ts` matches at any depth). A file takes the first class, in the order
# listed, whose pattern matches; lockfiles are always "generated", and any other file that matches
# none is product. Class names are free-form; every class except product, docs and generated
# counts as proof, and generated and docs count as neither.
classes:
  fixtures: ["tests/fixtures/*"]
  tests: ["tests/*", "*.test.ts"]
  eval: ["eval/*"]
  scripts: ["scripts/lint-*.sh", "scripts/new-fixture.py"]   # dev-only, by name
  specs: ["openspec/*"]
  tooling: [".github/*", ".pre-commit-config.yaml"]          # CI, lint, hook and agent config
  docs: ["*.md"]
  generated: ["plugin/dist/*"]   # regenerated output; lockfiles are generated without listing them

javascript:            # turns on the knip gate
  root: frontend       # directory with package.json (default "."); `npm ci --ignore-scripts` runs there
  knip:                # knip configuration, passed to knip as is (https://knip.dev/reference/configuration)
    entry: ["src/main.ts"]
    ignoreDependencies: ["@types/node"]

go:                    # turns on the deadcode gate
  root: .              # module directory (default ".")
  goos: [linux, windows]  # a GOOS or a list of them (default linux); with several, a deadcode or staticcheck
                          # finding counts only if every GOOS that builds its file reports it
  staticcheck: true    # also runs staticcheck (default false)
  ignore:              # extended regular expressions; a finding line that matches is dropped. The line is
                       # "file:line:col: message", file relative to the repository root; deadcode's message is
                       # "unreachable func: Name", and staticcheck's ends in its check, such as "(SA4006)"
    - "unreachable func: OnSystemEvent$"

python:                # turns on the ruff gate and the vulture measure
  roots: ["src"]       # default ["."]
  ignore_names: ["test_*"]
  ignore_decorators: ["@app.route"]
  exclude: ["*/migrations/*"]

eslint:                # turns on the ESLint gate: the repository's own ESLint, config and plugins
  root: frontend       # directory with package.json and the lockfile that installs eslint (default ".");
                       # `npm ci --ignore-scripts` runs there, once when javascript.root is the same
  args: ["src"]        # arguments after `eslint --format json` (default ["."])

shellcheck:            # turns on the ShellCheck gate for the shell scripts a pull request changes
  args: ["--exclude=SC1091"]   # options for shellcheck after --severity=warning (default none)
  exclude: ["**/vendor/*"]     # glob patterns on repository-relative paths to skip, where `*` also matches `/`
                               # and a leading `**/` also matches at the root; args and exclude take a string too

semgrep:               # turns on the banned-patterns gate (Python)
  paths: ["src"]       # where to look (default ["."]); name product code, not tests or evaluation
  rules: [".semgrep/local.yml"]  # optional: the repository's own rule files; rules/banned-patterns.yml always runs

duplicates:            # the jscpd measure (exact token clones) always runs
  paths: ["src"]       # default ["."]; .gitignore is respected
  ignore: ["**/fixtures/**"]

test_jobs: ["test"]    # job names in this workflow whose runtime is compared with main
```

A false positive from knip or deadcode is silenced here, where review sees every ignore entry. ruff,
ESLint, staticcheck and ShellCheck findings are silenced the tool's own way (`# noqa`, `eslint-disable`,
`//lint:ignore`, `# shellcheck disable=`), which review sees in the diff; staticcheck's also through
`go.ignore`. A banned pattern is kept on its own line with `# nosemgrep: <rule-id> -- <reason>`, where
review sees it.

**Test runtime** compares each named job in this run with the median of its last five successful runs
on the default branch, in the same workflow and on the same runner: the same labels for GitHub-hosted
runners, which get a new name for every job, and the same runner name for self-hosted ones. With fewer
than three such runs it shows "not comparable".

## How `v1` moves

Callers follow the moving tag `v1`. It moves only to a commit on `main` whose CI passed. That CI runs
the fixture tests in `tests/` and, on pull requests, the action on this repository itself. A change
reaches every repository with one tag move, and a rollback is moving the tag back:

```sh
git tag -f v1 <commit> && git push -f origin v1
```

A change that would break existing callers' `quality.yml` goes to `v2` instead.

## Development

```sh
python3 -m unittest discover -s tests -v
```

The tests build throwaway git repositories and run the scripts in them, so they need the same tools
as the action and network access on the first run. Set `EP_TOOLS` to a directory to reuse the
downloaded tools between runs.
