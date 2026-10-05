# engineering-practices

The engineering practices Hugo's repositories follow, and the GitHub Action that enforces the ones a
machine can check.

- [PRACTICES.md](PRACTICES.md) is the registry: one row per practice, with its source, its enforcer, what
  it prevents, what it costs when it fires wrongly and who pays.
- `action.yml` is a composite action every repository runs on its pull requests. It does two things:
  1. **Fails the pull request if it adds dead code** (practice C1): unused files, exports and dependencies
     in TypeScript/JavaScript ([knip](https://knip.dev)), unreachable functions in Go
     ([deadcode](https://pkg.go.dev/golang.org/x/tools/cmd/deadcode)). Only lines the pull request adds
     count ([reviewdog](https://github.com/reviewdog/reviewdog) filters the rest), so existing dead code
     never fails a pull request. It also fails when the repository's own configuration is broken:
     `.github/quality.yml` does not parse, knip reports a configuration error, or deadcode cannot load
     the packages. A tool that cannot be downloaded or installed, or times out, shows "not run" with
     its reason, raises a warning, and passes.
  2. **Posts a Quality report** for the reviewer, as one pull request comment updated in place and as the
     job summary: proof weight per path class, new duplicate code as exact token clones
     ([jscpd](https://github.com/kucherenko/jscpd)), Python definitions nothing references
     ([vulture](https://github.com/jendrikseipp/vulture), confidence 60 and up), and test-job runtime
     against main. These fail nothing. A measure that could not be computed says "not run" and why.

## Adopt it

Add one job to the repository's pull-request workflow:

```yaml
  quality:
    if: ${{ github.event_name == 'pull_request' && !cancelled() }}
    needs: [test]            # the test jobs named in quality.yml, so their runtime is known; or drop it
    runs-on: ubuntu-latest
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
          persist-credentials: false
      - uses: Artexis10/engineering-practices@v1
```

Then commit `.github/quality.yml` (below). The workflow should also run on pushes to the default branch,
so the runtime measure has main runs to compare with.

The action runs on Linux x86_64 and needs `git`, `curl`, `jq` and `python3`, plus `node` when JavaScript
is configured and `go` when Go is. GitHub's `ubuntu-latest` has all of them. Every tool is pinned:
reviewdog, yq and deadcode in `scripts/checks.sh`, knip and jscpd with their whole dependency tree and
its digests in `tools/package-lock.json`, vulture by digest in `tools/requirements.txt`.

Pull requests from forks get a read-only token whatever the job declares, so their report appears in
the job summary only, and the summary gives GitHub's answer. Dependabot pull requests run with the
permissions the job declares.

**The gate runs the pull request's code.** `npm ci --ignore-scripts` skips install scripts only. knip
then loads the repository's config files (its own, and those its plugins read, such as
`vite.config.ts`) and whatever they import, as the repository's test jobs would. So check out with
`persist-credentials: false`, keep tokens out of the job's environment (the action passes its token
to the report step only), and run it on `pull_request`; the action refuses `pull_request_target`,
which would hand that code a write token and the repository's secrets.

**What counts as added.** A finding fails the gate only on a line the pull request adds. An unused file
counts only when the pull request adds the file, and an unused dependency only when the merge base did
not declare it, so editing an old unused file or bumping an old unused dependency passes. Editing the
declaration line of an export that was already unused still fails, because that line counts as added:
delete the export, or leave that line alone.

## `.github/quality.yml`

Every key is optional. A language key that is absent turns its check off, and the report shows it as
"not configured".

```yaml
# Path classes for proof weight. Patterns are glob patterns on repository-relative paths, where `*`
# also matches `/` (so `*.test.ts` matches at any depth). A file takes the first class, in the order
# listed, whose pattern matches; a file matching none is counted as "unclassified". Every class
# except product and docs counts as proof.
classes:
  fixtures: ["tests/fixtures/*"]
  tests: ["tests/*", "*.test.ts"]
  eval: ["eval/*"]
  scripts: ["scripts/*"]
  specs: ["openspec/*"]
  docs: ["*.md"]
  product: ["src/*"]

javascript:            # turns on the knip gate
  root: frontend       # directory with package.json (default "."); `npm ci --ignore-scripts` runs there
  knip:                # knip configuration, passed to knip as is (https://knip.dev/reference/configuration)
    entry: ["src/main.ts"]
    ignoreDependencies: ["@types/node"]

go:                    # turns on the deadcode gate
  root: .              # module directory (default ".")
  goos: windows        # GOOS that deadcode analyses (default linux)
  ignore:              # extended regular expressions; a finding line ("file:line:col: unreachable func: Name") that matches is dropped
    - "unreachable func: OnSystemEvent$"

python:                # turns on the vulture measure
  roots: ["src"]       # default ["."]
  ignore_names: ["test_*"]
  ignore_decorators: ["@app.route"]
  exclude: ["*/migrations/*"]

duplicates:            # the jscpd measure (exact token clones) always runs
  paths: ["src"]       # default ["."]; .gitignore is respected
  ignore: ["**/fixtures/**"]

test_jobs: ["test"]    # job names in this workflow whose runtime is compared with main
```

A false positive in the gate is silenced here and nowhere else, so review sees every ignore entry.

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
