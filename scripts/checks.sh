#!/usr/bin/env bash
# shellcheck disable=SC2329 # the check_* functions are called as "check_$check"
# Run the gate or the review measures on the repository in the current
# directory, over the diff between the pull request's base and HEAD.
#
#   checks.sh gate       dead code: knip (TS/JS), deadcode (Go) and ruff's F rules
#                        (Python); the linters the repository turns on: ESLint,
#                        staticcheck and ShellCheck; and semgrep's banned patterns
#                        (rules/banned-patterns.yml). Exits 1 when one reports a
#                        finding on a line the diff adds, or reports that the
#                        repository's own input is broken
#   checks.sh measures   jscpd and vulture; never fails
#   checks.sh audit      semgrep's banned patterns over every file under semgrep.paths,
#                        with no base commit: writes $EP_OUT/semgrep.audit, one
#                        "path:line: rule-id" per finding, and prints the count per rule;
#                        never fails
#
# Each check writes $EP_OUT/<check>.status ("passed", "failed: ...",
# "N on added lines", "not configured" or "not run: <reason>") and
# $EP_OUT/<check>.findings (one "path:line: message" per finding).
# A download, install or timeout failure is "not run", never a failure: the
# tools and dependencies come from the network, and an outage must not freeze
# every merge. Input the repository owns (quality.yml, its lockfile, its code
# and its knip, ESLint or staticcheck configuration) fails the gate when it is broken.
#
# Environment: EP_BASE and EP_HEAD (the pull request's base and head commits), EP_BASE_REF (its base
# branch), EP_OUT and EP_TOOLS
# (default under $RUNNER_TEMP). Needs bash, git, curl, jq and python3; node for
# knip, jscpd and ESLint; go for deadcode and staticcheck. Linux x86_64 only.
set -uo pipefail

# Pinned tools. knip and jscpd are pinned with their whole dependency tree by
# tools/package-lock.json, ruff and vulture by tools/requirements.txt, semgrep with its whole
# dependency tree by tools/semgrep-requirements.txt, and ESLint by the repository's own lockfile.
# Moving a version is a change to these files, gated by the fixture tests.
REVIEWDOG=0.21.2 REVIEWDOG_SHA256=30413aa3c7443e9c3c157fe5766cad40e3bb39a32e210ee69b710a8d5c4b8e51
YQ=4.54.1 YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
SHELLCHECK=0.11.0 SHELLCHECK_SHA256=b7af85e41cc99489dcc21d66c6d5f3685138f06d34651e6d34b42ec6d54fe6f6
# go install checks these against the Go checksum database.
DEADCODE=0.51.0   # golang.org/x/tools
STATICCHECK=0.8.1 # honnef.co/go/tools
TIMEOUT=600     # seconds, per tool command
BUDGET=${EP_BUDGET:-600} # seconds for the whole action, so it ends inside a caller's timeout-minutes: 15
# No check needs VCS stamping, and Go's VCS lookup fails in a linked worktree (its .git is a file)
# under a directory whose .git git rejects, such as an agent sandbox's stub.
export GOFLAGS="${GOFLAGS:+$GOFLAGS }-buildvcs=false"

mode=${1:-}
case $mode in
  # Cheapest first, so a slow npm install or Go build cannot leave the quick checks without budget.
  gate) checks=(ruff shellcheck knip eslint semgrep deadcode staticcheck) ;;
  measures) checks=(jscpd vulture) ;;
  audit) checks=(semgrep) ;;
  *) echo "usage: checks.sh gate|measures|audit" >&2; exit 2 ;;
esac
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${EP_OUT:-${RUNNER_TEMP:?}/engineering-practices/out}
tools=${EP_TOOLS:-${RUNNER_TEMP:?}/engineering-practices/tools}
mkdir -p "$out" "$tools"
rd=$tools/reviewdog-$REVIEWDOG yq=$tools/yq-$YQ
[ -s "$out/started" ] || date +%s > "$out/started" # the first run of the action starts the budget
started=$(cat "$out/started")
printf '%s\n' "$BUDGET" > "$out/budget" # report.py reads the budget from here

# bounded <command...>: run under the smaller of TIMEOUT and what is left of the budget;
# exit 124, like timeout, when it runs out or is already spent
bounded() {
  local left=$((started + BUDGET - $(date +%s)))
  [ "$left" -gt 0 ] || return 124
  timeout "$((left < TIMEOUT ? left : TIMEOUT))" "$@"
}

# say <check> <status>: record a check's result, one line
say() {
  local status=${2%%$'\n'*}
  printf '%s\n' "$status" > "$out/$1.status"
  echo "$1: $status"
  [[ $status != "not run"* ]] || echo "::warning::$1: ${status//%/%25}"
}

# why <exit code> <stderr file>: one line saying why a command gave no result
why() {
  if [ "$1" = 124 ]; then
    if [ $((started + BUDGET - $(date +%s))) -le 0 ]; then echo "time budget of ${BUDGET}s used up"; else echo "timed out after ${TIMEOUT}s"; fi
    return
  fi
  local line
  line=$({ grep -m1 -i error "$2" || head -n1 "$2"; } 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  echo "exit $1: ${line:-no output}"
}

cfg() { jq -r "$1" "$out/config.json"; }
enabled() { jq -e --arg key "$1" '(. // {}) | has($key)' "$out/config.json" > /dev/null; }

# fetch <url> <sha256> <dest>: download a pinned file and check its digest
fetch() {
  bounded curl -sSfL --retry 2 --connect-timeout 30 --max-time 300 -o "$3.part" "$1" || return
  echo "$2  $3.part" | sha256sum -c --quiet - > /dev/null 2>&1 || { echo "sha256 checksum mismatch for $1" >&2; return 1; }
  mv "$3.part" "$3"
}

# setup: install reviewdog and yq, read the config, find the base commit. On failure
# prints the reason and returns 1, or 2 when the repository's config is broken.
setup() {
  local rc second base err=$out/setup.err
  [ "$(uname -sm)" = "Linux x86_64" ] || { echo "the runner is $(uname -sm); the action supports Linux x86_64"; return 1; }
  if [ ! -x "$rd" ]; then
    { fetch "https://github.com/reviewdog/reviewdog/releases/download/v$REVIEWDOG/reviewdog_${REVIEWDOG}_Linux_x86_64.tar.gz" \
        "$REVIEWDOG_SHA256" "$tools/reviewdog.tgz" && tar -xzf "$tools/reviewdog.tgz" -C "$tools" reviewdog &&
        mv "$tools/reviewdog" "$rd"; } 2> "$err" || { rc=$?; echo "cannot install reviewdog: $(why "$rc" "$err")"; return 1; }
  fi
  if [ ! -x "$yq" ]; then
    { fetch "https://github.com/mikefarah/yq/releases/download/v$YQ/yq_linux_amd64" "$YQ_SHA256" "$yq" &&
        chmod +x "$yq"; } 2> "$err" || { rc=$?; echo "cannot install yq: $(why "$rc" "$err")"; return 1; }
  fi
  [ -f .github/quality.yml ] || { echo "the repository has no .github/quality.yml"; return 1; }
  "$yq" -o=json . .github/quality.yml > "$out/config.json" 2> "$err" ||
    { rc=$?; echo ".github/quality.yml does not parse: $(why "$rc" "$err")"; return 2; }
  [ "$mode" != audit ] || return 0 # the audit reads the whole tree, not a diff
  [ -n "${EP_BASE:-}" ] || { echo "no pull request base commit; the action runs on pull_request events"; return 1; }
  # On the pull request's merge ref (what actions/checkout checks out), HEAD merges the head into the base
  # branch as it is now, while the event's base commit can be older; diffing against it would count the
  # base branch's later commits as the pull request's. So the base is HEAD's first parent there.
  # On any other checkout, it is the merge base with the base branch as fetched now, and with the
  # event's base commit only when that branch was not fetched.
  second=$(git rev-parse -q --verify 'HEAD^2' 2> /dev/null)
  base=$EP_BASE
  git rev-parse -q --verify "refs/remotes/origin/${EP_BASE_REF:-}" > /dev/null 2>&1 && base=refs/remotes/origin/$EP_BASE_REF
  if [ -n "$second" ] && [ "$second" = "$(git rev-parse -q --verify "${EP_HEAD:-}^{commit}" 2> /dev/null)" ]; then
    git rev-parse 'HEAD^1' > "$out/merge_base"
  else
    git merge-base "$base" HEAD > "$out/merge_base" 2> "$err" ||
      { rc=$?; echo "no merge base with $base ($(why "$rc" "$err")); check out with fetch-depth: 0"; return 1; }
  fi
}

# node_tools: install knip and jscpd exactly as tools/package-lock.json pins them
node_tools() {
  local dir
  dir=$tools/node-$(sha256sum < "$here/tools/package-lock.json" | cut -c1-12)
  [ -f "$dir/installed" ] && return
  mkdir -p "$dir" && cp "$here/tools/package.json" "$here/tools/package-lock.json" "$dir/" &&
    bounded npm ci --ignore-scripts --no-audit --no-fund --prefix "$dir" > /dev/null && touch "$dir/installed"
}
node_bin() { echo "$tools/node-$(sha256sum < "$here/tools/package-lock.json" | cut -c1-12)/node_modules/.bin/$1"; }

# python_tools [file]: install the tools exactly as tools/<file> pins them (default requirements.txt:
# ruff and vulture)
python_tools() {
  local venv
  venv=$(dirname "$(dirname "$(python_bin pip "${1:-}")")")
  [ -f "$venv/installed" ] && return
  python3 -m venv "$venv" &&
    bounded "$venv/bin/pip" install -q --require-hashes --only-binary=:all: \
      -r "$here/tools/${1:-requirements.txt}" > /dev/null &&
    touch "$venv/installed"
}
python_bin() { echo "$tools/python-$(sha256sum < "$here/tools/${2:-requirements.txt}" | cut -c1-12)/bin/$1"; }

# npm_ci <check> <dir>: install the repository's dependencies in <dir> as its lockfile pins them,
# without install scripts, once per run. On failure records <check>'s status and returns 1.
declare -A npm_installed=()
npm_ci() {
  local rc abs
  abs=$(cd "$2" && pwd -P)
  [ -z "${npm_installed[$abs]:-}" ] || return 0
  bounded env -C "$2" npm ci --ignore-scripts --no-audit --no-fund > /dev/null 2> "$out/$1.err" || {
    rc=$?
    # A lockfile out of step with package.json, or one that does not parse, is the repository's own input.
    if grep -qE '^npm (ERR!|error) code (EUSAGE|EJSONPARSE)$' "$out/$1.err"; then
      say "$1" "failed: npm ci rejects the repository's package files: $(why "$rc" "$out/$1.err")"
    else
      say "$1" "not run: npm ci $(why "$rc" "$out/$1.err")"
    fi
    return 1
  }
  npm_installed[$abs]=1
}

# go_prepare <check> <package> <version>: download the module's dependencies (and any toolchain
# go.mod asks for), then install the tool. It type-checks with the Go it was built with, so it is built
# with the Go the module selects (+auto lets it go newer if the tool itself needs that). Sets the
# caller's dir, gooses and bin; on failure records <check>'s status and returns 1.
go_prepare() {
  local check=$1 rc gover
  dir=$(cfg '.go.root // "."')
  mapfile -t gooses < <(cfg '.go.goos // "linux" | if type == "array" then .[] else . end')
  # A network failure is "not run".
  bounded env -u PWD -C "$dir" go mod download 2> "$out/$check.err" || {
    rc=$?
    if grep -q 'errors parsing go.mod' "$out/$check.err"; then
      say "$check" "failed: go.mod does not parse: $(grep -m1 -A1 'errors parsing go.mod' "$out/$check.err" | tail -n1)"
    else
      say "$check" "not run: cannot download the Go modules or toolchain: $(why "$rc" "$out/$check.err")"
    fi
    return 1
  }
  gover=$(env -u PWD -C "$dir" go env GOVERSION 2> "$out/$check.err") ||
    { rc=$?; say "$check" "not run: cannot tell which Go the module selects: $(why "$rc" "$out/$check.err")"; return 1; }
  bin=$tools/$check-$3-$gover/$check
  [ -x "$bin" ] || bounded env GOBIN="$(dirname "$bin")" GOTOOLCHAIN="$gover+auto" \
    go install "$2@v$3" 2> "$out/$check.err" ||
    { rc=$?; say "$check" "not run: cannot install $check with $gover: $(why "$rc" "$out/$check.err")"; return 1; }
}

# go_kept <check> [go list flags...]: from $out/<check>.<GOOS>.txt, one "file:line:col: message" per
# finding with the file absolute or relative to dir, keep a finding only if every GOOS that builds its
# file reports it: a helper in a shared file called only from one platform's files is live in that
# platform's build. Writes the kept findings, relative to the repository root and minus go.ignore, to
# $out/<check>.kept; on failure records <check>'s status and returns 1.
go_kept() {
  local check=$1 goos rc absdir top
  local each='{{$.Dir}}/{{.}}{{"\n"}}'
  shift
  # Findings and built files are matched on absolute paths, and go list prints absolute directories.
  # Every Go command runs without PWD, so Go resolves its directory physically, as pwd -P and git do,
  # even in a symlinked workspace.
  absdir=$(cd "$dir" && pwd -P)
  top=$(git rev-parse --show-toplevel)
  : > "$out/$check.runs"
  for goos in "${gooses[@]}"; do
    # The files this GOOS builds, its packages' dependencies included ("built<TAB>GOOS<TAB>path"),
    # then its findings ("hit<TAB>finding").
    env -u PWD -C "$dir" GOOS="$goos" GOPROXY=off go list -deps -test "$@" -f \
      "{{range .GoFiles}}$each{{end}}{{range .CgoFiles}}$each{{end}}{{range .TestGoFiles}}$each{{end}}{{range .XTestGoFiles}}$each{{end}}" \
      ./... 2> "$out/$check.err" | awk -v goos="$goos" '{ print "built\t" goos "\t" $0 }' >> "$out/$check.runs" ||
      { rc=$?; say "$check" "failed: go list cannot load the packages (GOOS=$goos): $(why "$rc" "$out/$check.err")"; return 1; }
    awk -v dir="$absdir/" '{ print "hit\t" (index($0, "/") == 1 ? "" : dir) $0 }' "$out/$check.$goos.txt" >> "$out/$check.runs"
  done
  awk -F '\t' '
    $1 == "built" { built[$2, $3] = 1; gooses[$2] = 1; next }
    { finding = substr($0, 5); if (!(finding in hits)) order[++m] = finding; hits[finding]++ }
    END {
      for (j = 1; j <= m; j++) {
        split(order[j], part, ":"); need = 0
        for (g in gooses) need += ((g, part[1]) in built)
        if (hits[order[j]] == need) print order[j]
      }
    }' "$out/$check.runs" | awk -v top="$top/" 'index($0, top) == 1 { $0 = substr($0, length(top) + 1) } { print }' \
    > "$out/$check.txt"
  cfg '.go.ignore // [] | .[]' > "$out/$check.ignore"
  grep -Ev -f "$out/$check.ignore" "$out/$check.txt" > "$out/$check.kept" 2> "$out/$check.err"
  rc=$?
  [ "$rc" -le 1 ] ||
    { say "$check" "failed: go.ignore in .github/quality.yml is not a valid regex list ($(why "$rc" "$out/$check.err"))"; return 1; }
}

# filter <check> <dir> <fail level> <reviewdog input flags...> < tool output
# Keeps the findings on lines the diff adds. Runs in <dir>, where the tool ran,
# so that reviewdog maps the tool's relative paths onto the diff. --text keeps a
# .gitattributes "-diff" from hiding a file's lines from the filter.
filter() {
  local check=$1 dir=$2 level=$3 rc n
  shift 3
  env -C "$dir" "$rd" "$@" -name="$check" -reporter=rdjsonl -filter-mode=added -fail-level="$level" \
    -diff="git diff --text $mb HEAD" > "$out/$check.rdjsonl" 2> "$out/$check.err"
  rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$out/$check.rdjsonl" ]; then
    say "$check" "not run: reviewdog $(why "$rc" "$out/$check.err")"
    return
  fi
  # A path or message with a control character is shown JSON-escaped, so it stays on one line.
  jq -r --arg dir "$dir" 'def safe: if test("[[:cntrl:]]") then tojson else . end;
    "\((if $dir == "." then "" else $dir + "/" end) + .location.path | safe):\(.location.range.start.line // 1): \(.message | safe)"' \
    "$out/$check.rdjsonl" > "$out/$check.findings"
  n=$(jq -s length "$out/$check.rdjsonl")
  if [ "$level" = none ]; then
    if [ "$n" -gt 0 ]; then say "$check" "$n on added lines"; else say "$check" "none on added lines"; fi
  elif [ "$rc" -ne 0 ]; then
    say "$check" "failed: $n on added lines"
  else
    say "$check" passed
  fi
  sed 's/^/  /' "$out/$check.findings"
}

# base_deps <dir>: {"<package.json under dir>": [the dependencies it declared at the merge base]}
base_deps() {
  jq -r 'select(.code.value // "" | endswith("ependencies")) | .location.path' "$out/knip.all.rdjsonl" | sort -u |
    while IFS= read -r manifest; do
      env -C "$1" git show "$mb:./$manifest" 2> /dev/null | jq --arg manifest "$manifest" \
        '{($manifest): [(.dependencies, .devDependencies, .optionalDependencies, .peerDependencies) // {} | keys[]]}' 2> /dev/null
    done | jq -s 'add // {}'
}

check_knip() {
  local dir rc config=()
  enabled javascript || { say knip "not configured"; return; }
  dir=$(cfg '.javascript.root // "."')
  if [ -f "$dir/package.json" ]; then npm_ci knip "$dir" || return; fi
  node_tools 2> "$out/knip.err" || { rc=$?; say knip "not run: cannot install knip: $(why "$rc" "$out/knip.err")"; return; }
  if [ "$(cfg '.javascript.knip | type')" = object ]; then
    jq .javascript.knip "$out/config.json" > "$out/knip.json"
    config=(--config "$out/knip.json")
  fi
  # knip's Lefthook plugin asks git for the hooks path; the machine's own git config (a global core.hooksPath)
  # would become entry globs outside the repository, so knip sees only the repository's config, as on a hosted runner.
  bounded env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$(node_bin knip)" --directory "$dir" "${config[@]}" --include files,exports,dependencies \
    --reporter sarif --no-progress > "$out/knip.sarif" 2> "$out/knip.err"
  rc=$? # 1 means it found unused code; 2 means the repository's configuration is broken
  [ "$rc" != 2 ] || { say knip "failed: knip reports a configuration error: $(why "$rc" "$out/knip.err")"; return; }
  [ "$rc" -le 1 ] || { say knip "not run: knip $(why "$rc" "$out/knip.err")"; return; }
  # Read the SARIF once without filtering: reviewdog decodes its URIs into the paths git uses.
  env -C "$dir" "$rd" -f=sarif -filter-mode=nofilter -reporter=rdjsonl < "$out/knip.sarif" > "$out/knip.all.rdjsonl" 2> "$out/knip.err" ||
    { rc=$?; say knip "not run: reviewdog cannot read knip's output: $(why "$rc" "$out/knip.err")"; return; }
  # Old debt stays out of the gate. An unused file's finding has no line and the added-line filter
  # drops it, so only a file this pull request adds gets line 1. An unused dependency the merge base
  # already declared is dropped, so a version bump on its line does not fail.
  env -C "$dir" git diff --text -z --name-only --diff-filter=A --relative "$mb" HEAD > "$out/knip.added"
  base_deps "$dir" > "$out/knip.base.json"
  jq -c --rawfile added "$out/knip.added" --slurpfile base "$out/knip.base.json" '
    ($added | split("\u0000")) as $new
    | if .location.range == null and (.location.path | IN($new[])) then .location.range = {start: {line: 1}} else . end
    | select((.code.value // "" | endswith("ependencies") | not)
        or ((.message | sub("^[^:]*: "; "")) as $name | $base[0][.location.path] // [] | any(.[]; . == $name) | not))' \
    "$out/knip.all.rdjsonl" > "$out/knip.new.rdjsonl" 2> "$out/knip.err" ||
    { rc=$?; say knip "not run: cannot read knip's findings: $(why "$rc" "$out/knip.err")"; return; }
  filter knip "$dir" error -f=rdjsonl < "$out/knip.new.rdjsonl"
}

check_deadcode() {
  local dir bin goos rc gooses=()
  enabled go || { say deadcode "not configured"; return; }
  go_prepare deadcode golang.org/x/tools/cmd/deadcode "$DEADCODE" || return
  for goos in "${gooses[@]}"; do
    # With the network off, a load failure is the repository's own code. deadcode prints a file under
    # its directory relative to it, and any other file absolute.
    bounded env -u PWD -C "$dir" GOOS="$goos" GOPROXY=off "$bin" -test ./... > "$out/deadcode.$goos.txt" 2> "$out/deadcode.err"
    rc=$?
    [ "$rc" != 124 ] || { say deadcode "not run: deadcode (GOOS=$goos) $(why "$rc" "$out/deadcode.err")"; return; }
    [ "$rc" = 0 ] || { say deadcode "failed: deadcode cannot load the packages (GOOS=$goos): $(why "$rc" "$out/deadcode.err")"; return; }
  done
  # -tags= matches deadcode, which overrides tags in GOFLAGS.
  go_kept deadcode -tags= || return
  filter deadcode . error -efm='%f:%l:%c: %m' < "$out/deadcode.kept"
}

check_staticcheck() {
  local dir bin goos rc broken gooses=()
  enabled go && [ "$(cfg '.go.staticcheck')" = true ] || { say staticcheck "not configured"; return; }
  go_prepare staticcheck honnef.co/go/tools/cmd/staticcheck "$STATICCHECK" || return
  for goos in "${gooses[@]}"; do
    # Exit 1 means findings, or packages that do not load: with the network off, the repository's own code.
    bounded env -u PWD -C "$dir" GOOS="$goos" GOPROXY=off "$bin" -f json ./... \
      > "$out/staticcheck.$goos.json" 2> "$out/staticcheck.err"
    rc=$?
    [ "$rc" -le 1 ] || { say staticcheck "not run: staticcheck (GOOS=$goos) $(why "$rc" "$out/staticcheck.err")"; return; }
    [ "$rc" = 0 ] || [ -s "$out/staticcheck.$goos.json" ] ||
      { say staticcheck "failed: staticcheck cannot load the packages (GOOS=$goos): $(why "$rc" "$out/staticcheck.err")"; return; }
    # Code that does not type-check, or a staticcheck.conf it cannot read, is reported as a finding
    # without a line; it is the repository's own input.
    broken=$(jq -r 'select(.code == "compile" or .code == "config") | .message | gsub("\\s+"; " ")' \
      "$out/staticcheck.$goos.json" 2> "$out/staticcheck.err" | head -n1)
    [ -z "$broken" ] || { say staticcheck "failed: staticcheck cannot check the packages (GOOS=$goos): $broken"; return; }
    jq -r '"\(.location.file):\(.location.line):\(.location.column): \(.message | gsub("\\s+"; " ")) (\(.code))"' \
      "$out/staticcheck.$goos.json" > "$out/staticcheck.$goos.txt" 2> "$out/staticcheck.err" ||
      { rc=$?; say staticcheck "not run: cannot read staticcheck's output: $(why "$rc" "$out/staticcheck.err")"; return; }
  done
  # No -tags=: staticcheck, unlike deadcode, builds with the tags in GOFLAGS, as go list does.
  go_kept staticcheck || return
  filter staticcheck . error -efm='%f:%l:%c: %m' < "$out/staticcheck.kept"
}

check_eslint() {
  local dir rc top args=()
  enabled eslint || { say eslint "not configured"; return; }
  dir=$(cfg '.eslint.root // "."')
  mapfile -t args < <(cfg '.eslint.args // ["."] | .[]')
  [ -f "$dir/package.json" ] ||
    { say eslint "failed: eslint.root in .github/quality.yml names $dir, which has no package.json"; return; }
  # The repository's own ESLint, plugins and config, as its lockfile pins them.
  npm_ci eslint "$dir" || return
  [ -x "$dir/node_modules/.bin/eslint" ] || { say eslint "failed: $dir/package.json does not install eslint"; return; }
  rm -f "$out/eslint.json"
  bounded env -C "$dir" node_modules/.bin/eslint --format json --output-file "$out/eslint.json" "${args[@]}" \
    > /dev/null 2> "$out/eslint.err"
  rc=$? # 1 means it found errors; 2 means the repository's configuration is broken
  [ "$rc" != 2 ] || { say eslint "failed: eslint reports a configuration error: $(why "$rc" "$out/eslint.err")"; return; }
  [ "$rc" -le 1 ] || { say eslint "not run: eslint $(why "$rc" "$out/eslint.err")"; return; }
  # Errors only: a rule the repository sets to "warn" does not fail its own lint either. ESLint gives
  # absolute paths; a message without a line is dropped by the added-line filter.
  top=$(git rev-parse --show-toplevel)
  jq -c --arg top "$top/" '.[] | .filePath as $file | .messages[] | select(.severity == 2) | {
      message: (.message + if .ruleId then " (\(.ruleId))" else "" end),
      location: {
        path: (if ($file | startswith($top)) then $file[($top | length):] else $file end),
        range: (if .line then {start: {line: .line, column: (.column // 1)}} else null end)
      },
      severity: "ERROR"
    }' "$out/eslint.json" > "$out/eslint.all.rdjsonl" 2> "$out/eslint.err" ||
    { rc=$?; say eslint "not run: cannot read eslint's output: $(why "$rc" "$out/eslint.err")"; return; }
  filter eslint . error -f=rdjsonl < "$out/eslint.all.rdjsonl"
}

check_shellcheck() {
  local rc file first pattern sc=$tools/shellcheck-$SHELLCHECK files=() args=() exclude=()
  local shebang='^#!.*[/[:space:]](sh|bash|dash|ksh)([[:space:]]|$)'
  enabled shellcheck || { say shellcheck "not configured"; return; }
  mapfile -t args < <(cfg '.shellcheck.args // [] | if type == "array" then .[] else . end')
  mapfile -t exclude < <(cfg '.shellcheck.exclude // [] | if type == "array" then .[] else . end')
  # Only the shell scripts this pull request adds or changes can have added lines: *.sh and *.bash
  # files, and files whose first line is a shebang for a shell ShellCheck checks. A template is not
  # the script that runs, so it is skipped, as is a path shellcheck.exclude matches (* also matches /,
  # and a leading **/ also matches at the root, as in the path classes).
  while IFS= read -r -d '' file; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    case $file in *.j2 | *.jinja | *.jinja2 | *.tmpl | *.tpl) continue ;; esac
    for pattern in "${exclude[@]}"; do
      # shellcheck disable=SC2053 # the pattern is a glob on purpose
      [[ $file != $pattern && $file != ${pattern#\*\*/} ]] || continue 2
    done
    first=$(head -c 200 -- "$file" | tr -d '\0' | head -n1)
    if [[ $file == *.sh || $file == *.bash || $first =~ $shebang ]]; then files+=("$file"); fi
  done < <(git diff --text -z --name-only --diff-filter=d "$mb" HEAD)
  [ "${#files[@]}" -gt 0 ] || { say shellcheck "no shell script changed"; return; }
  if [ ! -x "$sc" ]; then
    { fetch "https://github.com/koalaman/shellcheck/releases/download/v$SHELLCHECK/shellcheck-v$SHELLCHECK.linux.x86_64.tar.gz" \
        "$SHELLCHECK_SHA256" "$tools/shellcheck.tgz" &&
        tar -xzf "$tools/shellcheck.tgz" -C "$tools" --strip-components=1 "shellcheck-v$SHELLCHECK/shellcheck" &&
        mv "$tools/shellcheck" "$sc"; } 2> "$out/shellcheck.err" ||
      { rc=$?; say shellcheck "not run: cannot install shellcheck: $(why "$rc" "$out/shellcheck.err")"; return; }
  fi
  # Warnings and errors only by default: notes and style must not fail. A repository can lower it
  # with a --severity in its args, which comes later and wins.
  bounded "$sc" --format=json1 --severity=warning "${args[@]}" -- "${files[@]}" > "$out/shellcheck.json" 2> "$out/shellcheck.err"
  rc=$? # 1 means it found something; 3 and 4 mean shellcheck.args in quality.yml are broken
  [ "$rc" != 3 ] && [ "$rc" != 4 ] ||
    { say shellcheck "failed: shellcheck rejects shellcheck.args in .github/quality.yml: $(why "$rc" "$out/shellcheck.err")"; return; }
  [ "$rc" -le 1 ] || { say shellcheck "not run: shellcheck $(why "$rc" "$out/shellcheck.err")"; return; }
  # JSON rather than an errorformat, so a file name with a space or a newline stays whole.
  jq -c '.comments[] | {
      message: "\(.level): \(.message) [SC\(.code)]",
      location: {path: .file, range: {start: {line: .line, column: .column}}},
      severity: "ERROR"
    }' "$out/shellcheck.json" > "$out/shellcheck.all.rdjsonl" 2> "$out/shellcheck.err" ||
    { rc=$?; say shellcheck "not run: cannot read shellcheck's output: $(why "$rc" "$out/shellcheck.err")"; return; }
  filter shellcheck . error -f=rdjsonl < "$out/shellcheck.all.rdjsonl"
}

check_jscpd() {
  local rc ignore paths=()
  mapfile -t paths < <(cfg '.duplicates.paths // ["."] | .[]')
  ignore=$(cfg '.duplicates.ignore // [] | join(",")')
  node_tools 2> "$out/jscpd.err" || { rc=$?; say jscpd "not run: cannot install jscpd: $(why "$rc" "$out/jscpd.err")"; return; }
  rm -rf "$out/jscpd"
  bounded "$(node_bin jscpd)" --reporters sarif --output "$out/jscpd" ${ignore:+--ignore "$ignore"} \
    "${paths[@]}" > /dev/null 2> "$out/jscpd.err" ||
    { rc=$?; say jscpd "not run: jscpd $(why "$rc" "$out/jscpd.err")"; return; }
  # jscpd reports a clone once, at one of its copies; report it at both so an added copy survives the filter.
  jq '.runs[].results |= [.[] | ., (.relatedLocations[0]? as $copy | select($copy)
      | .message.text = "Duplicates \(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine)"
      | .locations = [{physicalLocation: $copy.physicalLocation}] | del(.relatedLocations))]' \
    "$out/jscpd/jscpd-report.sarif" > "$out/jscpd.sarif" 2> "$out/jscpd.err" ||
    { rc=$?; say jscpd "not run: jscpd output is not SARIF ($(why "$rc" "$out/jscpd.err"))"; return; }
  filter jscpd . none -f=sarif < "$out/jscpd.sarif"
}

check_ruff() {
  local rc root roots=()
  enabled python || { say ruff "not configured"; return; }
  mapfile -t roots < <(cfg '.python.roots // ["."] | .[]')
  for root in "${roots[@]}"; do # ruff only warns about a missing path, and would pass having checked nothing
    [ -e "$root" ] || { say ruff "failed: python.roots in .github/quality.yml names $root, which does not exist"; return; }
  done
  python_tools 2> "$out/ruff.err" || { rc=$?; say ruff "not run: cannot install ruff: $(why "$rc" "$out/ruff.err")"; return; }
  # --select F replaces the repository's rule selection; its per-file-ignores, excludes and noqa comments still apply.
  bounded "$(python_bin ruff)" check --no-cache --select F --output-format sarif "${roots[@]}" \
    > "$out/ruff.sarif" 2> "$out/ruff.err"
  rc=$? # 1 means it found something; 2 means the repository's configuration or roots are broken
  [ "$rc" != 2 ] || { say ruff "failed: ruff reports a configuration error: $(why "$rc" "$out/ruff.err")"; return; }
  [ "$rc" -le 1 ] || { say ruff "not run: ruff $(why "$rc" "$out/ruff.err")"; return; }
  filter ruff . error -f=sarif < "$out/ruff.sarif"
}

check_vulture() {
  local rc key value roots=() args=() unread
  enabled python || { say vulture "not configured"; return; }
  mapfile -t roots < <(cfg '.python.roots // ["."] | .[]')
  for key in ignore_names ignore_decorators exclude; do
    value=$(cfg ".python.$key // [] | join(\",\")")
    [ -z "$value" ] || args+=("--${key//_/-}" "$value")
  done
  python_tools 2> "$out/vulture.err" ||
    { rc=$?; say vulture "not run: cannot install vulture: $(why "$rc" "$out/vulture.err")"; return; }
  bounded "$(python_bin vulture)" --min-confidence 60 "${args[@]}" "${roots[@]}" > "$out/vulture.txt" 2> "$out/vulture.err"
  rc=$? # 3 means it found unused code; 1 also when it could not read a file
  # Files vulture could not read: a syntax error or a bad encoding.
  sed -nE "s/^(.+):[0-9]+: invalid syntax at .*/\1/p; s#^Error: Could not read file ($PWD/)?(.+) - \$#\2#p" \
    "$out/vulture.err" | sed 's#^\./##' | sort -u > "$out/vulture.unread"
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { [ "$rc" = 1 ] && [ -s "$out/vulture.unread" ]; } ||
    { say vulture "not run: vulture $(why "$rc" "$out/vulture.err")"; return; }
  # Converted to JSON rather than read with an errorformat, so a path with a space stays whole.
  jq -cR 'capture("^(?<path>.+?):(?<line>[0-9]+): (?<message>.*)$")
    | {message, location: {path, range: {start: {line: (.line | tonumber)}}}}' \
    "$out/vulture.txt" > "$out/vulture.all.rdjsonl" 2> "$out/vulture.err" ||
    { rc=$?; say vulture "not run: cannot read vulture's output: $(why "$rc" "$out/vulture.err")"; return; }
  filter vulture . none -f=rdjsonl < "$out/vulture.all.rdjsonl"
  # The measure is partial when a file it could not read is one this pull request changes.
  unread=$(git diff --text --name-only "$mb" HEAD | grep -Fxf "$out/vulture.unread" | paste -sd, - | sed 's/,/, /g')
  [ -z "$unread" ] || grep -q '^not run' "$out/vulture.status" ||
    say vulture "partial, could not read $unread: $(cat "$out/vulture.status")"
}

check_semgrep() {
  local rc path paths=() rules=() targets=() scanned=() configs=(--config "$here/rules/banned-patterns.yml") gaveup
  enabled semgrep || { say semgrep "not configured"; return; }
  mapfile -t paths < <(cfg '.semgrep.paths // ["."] | .[]')
  mapfile -t rules < <(cfg '.semgrep.rules // [] | .[]')
  for path in "${paths[@]}" "${rules[@]}"; do # a missing path would pass having checked nothing
    [ -e "$path" ] || { say semgrep "failed: semgrep in .github/quality.yml names $path, which does not exist"; return; }
  done
  for path in "${rules[@]}"; do configs+=(--config "$path"); done
  if [ "$mode" = audit ]; then
    mapfile -d '' -t targets < <(git ls-files -z -- "${paths[@]}")
  else # every rule reads one file at a time, so only the files the pull request changes need reading
    mapfile -d '' -t targets < <(git diff --text -z --name-only --diff-filter=d "$mb" HEAD -- "${paths[@]}")
  fi
  # With no code changed, a changed rule file still loads, against an empty file, so a broken one
  # fails the pull request that broke it. The audit always loads them.
  if [ "${#targets[@]}" = 0 ]; then
    [ "$mode" = audit ] || { [ "${#rules[@]}" -gt 0 ] && [ -n "$(git diff --text --name-only "$mb" HEAD -- "${rules[@]}")" ]; } ||
      { say semgrep passed; return; }
    : > "$out/empty.py"
    targets=("$out/empty.py")
  fi
  python_tools semgrep-requirements.txt 2> "$out/semgrep.err" ||
    { rc=$?; say semgrep "not run: cannot install semgrep: $(why "$rc" "$out/semgrep.err")"; return; }
  # One job: taint analysis gives up on a long function when it shares the CPU, and a large file
  # needs more than semgrep's 5 seconds per rule. What it still gives up on is named below.
  bounded env SEMGREP_ENABLE_VERSION_CHECK=0 "$(python_bin semgrep semgrep-requirements.txt)" scan "${configs[@]}" \
    --metrics off --disable-version-check --jobs 1 --timeout 120 --max-target-bytes 0 --quiet \
    --sarif-output "$out/semgrep.sarif" --json-output "$out/semgrep.json" -- "${targets[@]}" > /dev/null 2> "$out/semgrep.err"
  rc=$? # 0 with or without findings; 4, 5, 7 or 8 when a rule file does not load; 2 for a bad pattern or a crash
  if [ "${#rules[@]}" -gt 0 ] && { [[ $rc =~ ^[4578]$ ]] || { [ "$rc" = 2 ] &&
      jq -e 'any(.errors[]?; .type == "Rule parse error")' "$out/semgrep.json" > /dev/null 2>&1; }; }; then # rules/ is tested here, so it is the repository's file
    say semgrep "failed: semgrep cannot load the rule files: $(jq -r '.errors[0].message // empty' "$out/semgrep.json" 2> /dev/null | head -n1)"
    return
  fi
  [ "$rc" = 0 ] || { say semgrep "not run: semgrep $(why "$rc" "$out/semgrep.err")"; return; }
  if [ "$mode" = audit ]; then
    jq -r '.results[] | "\(.path):\(.start.line): \(.check_id | split(".") | last)"' "$out/semgrep.json" > "$out/semgrep.audit"
    say semgrep "$(wc -l < "$out/semgrep.audit") in the tree"
    awk -F ': ' '{ print $NF }' "$out/semgrep.audit" | sort | uniq -c | sort -rn
  else
    # semgrep honours " nosem" or " nosemgrep" in any case, on the finding's line or alone on the line
    # above (semgrep 1.179, semgrep/constants.py: NOSEM_INLINE_RE and NOSEM_PREVIOUS_LINE_RE). One that
    # names no rule hides every finding there, and one with no reason gives review nothing to check, so
    # an added line in a scanned file that carries the token in any other form than
    # `nosemgrep: <rule-id>[, <rule-id>...] -- <reason>` fails like a finding. A semgrep rule cannot find
    # it, because the comment hides that rule's finding too.
    mapfile -d '' -t scanned < <(jq -j '.paths.scanned[]? + "\u0000"' "$out/semgrep.json")
    for path in "${scanned[@]}"; do
      # grep numbers the lines: jq's input_line_number misses a last line without a newline.
      grep -n --text -i -E ' nosem(grep)?' -- "$path" | jq -Rc --arg path "$path" 'capture("^(?<n>[0-9]+):(?<text>.*)$")
        | select(.text | sub(" nosemgrep: [A-Za-z0-9._-]+(, ?[A-Za-z0-9._-]+)* -- \\S.*$"; "") | test(" nosem(grep)?"; "i"))
        | {ruleId: "ep-nosemgrep-form", level: "error",
           message: {text: "ep-nosemgrep-form: a nosemgrep comment names no rule or gives no reason. Write `# nosemgrep: <rule-id> -- <reason>`, which review checks."},
           locations: [{physicalLocation: {artifactLocation: {uri: $path}, region: {startLine: (.n | tonumber)}}}]}'
    done > "$out/nosemgrep.json"
    # An ERROR finding fails on an added line; a WARNING is listed for the reviewer. A nosemgrep comment keeps one out.
    jq --slurpfile form "$out/nosemgrep.json" '.runs[0].results += $form' "$out/semgrep.sarif" > "$out/semgrep.gate.sarif"
    filter semgrep . error -f=sarif < "$out/semgrep.gate.sarif"
  fi
  gaveup=$(jq -r '(.errors[]? | select(.type == "Timeout") | .path // empty),
      (.time.fixpoint_timeouts[]?.message | capture("analysis at (?<path>[^:]+):").path)' "$out/semgrep.json" |
    sort -u | paste -sd, - | sed 's/,/, /g')
  [ -z "$gaveup" ] || grep -q '^not run' "$out/semgrep.status" ||
    say semgrep "$(cat "$out/semgrep.status"); partial, semgrep gave up on part of $gaveup"
}

for check in "${checks[@]}"; do rm -f "$out/$check.status" "$out/$check.findings"; done
reason=$(setup)
case $? in
  0)
    rm -f "$out/setup.reason"
    [ "$mode" = audit ] || mb=$(cat "$out/merge_base")
    for check in "${checks[@]}"; do "check_$check"; done
    ;;
  2) # the repository's own config is broken: the gate fails, the measures do not run
    printf '%s\n' "$reason" > "$out/setup.reason"
    for check in "${checks[@]}"; do
      if [ "$mode" = gate ]; then say "$check" "failed: $reason"; else say "$check" "not run: $reason"; fi
    done
    ;;
  *)
    printf '%s\n' "$reason" > "$out/setup.reason"
    for check in "${checks[@]}"; do say "$check" "not run: $reason"; done
    ;;
esac

if [ "$mode" = gate ]; then
  for check in "${checks[@]}"; do
    if grep -qs '^failed' "$out/$check.status"; then
      echo "::error::The gate failed; see the findings above and the Quality report."
      exit 1
    fi
  done
fi
exit 0
