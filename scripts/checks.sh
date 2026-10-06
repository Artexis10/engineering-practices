#!/usr/bin/env bash
# shellcheck disable=SC2329 # the check_* functions are called as "check_$check"
# Run the dead-code gate or the review measures on the repository in the
# current directory, over the diff between the pull request's base and HEAD.
#
#   checks.sh gate       knip (TS/JS), deadcode (Go) and ruff's F rules (Python);
#                        exits 1 when one reports a finding on a line the diff
#                        adds, or reports that the repository's own input is broken
#   checks.sh measures   jscpd and vulture; never fails
#
# Each check writes $EP_OUT/<check>.status ("passed", "failed: ...",
# "N on added lines", "not configured" or "not run: <reason>") and
# $EP_OUT/<check>.findings (one "path:line: message" per finding).
# A download, install or timeout failure is "not run", never a failure: the
# tools and dependencies come from the network, and an outage must not freeze
# every merge. Input the repository owns (quality.yml, its lockfile, its code
# and its knip configuration) fails the gate when it is broken.
#
# Environment: EP_BASE and EP_HEAD (the pull request's base and head commits), EP_BASE_REF (its base
# branch), EP_OUT and EP_TOOLS
# (default under $RUNNER_TEMP). Needs bash, git, curl, jq and python3; node for
# knip and jscpd; go for deadcode. Linux x86_64 only.
set -uo pipefail

# Pinned tools. knip and jscpd are pinned with their whole dependency tree by
# tools/package-lock.json, ruff and vulture by tools/requirements.txt. Moving a version is
# a change to these files, gated by the fixture tests.
REVIEWDOG=0.21.2 REVIEWDOG_SHA256=30413aa3c7443e9c3c157fe5766cad40e3bb39a32e210ee69b710a8d5c4b8e51
YQ=4.54.1 YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
DEADCODE=0.51.0 # golang.org/x/tools; go install checks it against the Go checksum database
TIMEOUT=600     # seconds, per tool command

mode=${1:-}
case $mode in
  gate) checks=(knip deadcode ruff) ;;
  measures) checks=(jscpd vulture) ;;
  *) echo "usage: checks.sh gate|measures" >&2; exit 2 ;;
esac
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${EP_OUT:-${RUNNER_TEMP:?}/engineering-practices/out}
tools=${EP_TOOLS:-${RUNNER_TEMP:?}/engineering-practices/tools}
mkdir -p "$out" "$tools"
rd=$tools/reviewdog-$REVIEWDOG yq=$tools/yq-$YQ

# say <check> <status>: record a check's result, one line
say() {
  local status=${2%%$'\n'*}
  printf '%s\n' "$status" > "$out/$1.status"
  echo "$1: $status"
  [[ $status != "not run"* ]] || echo "::warning::$1: ${status//%/%25}"
}

# why <exit code> <stderr file>: one line saying why a command gave no result
why() {
  if [ "$1" = 124 ]; then echo "timed out after ${TIMEOUT}s"; return; fi
  local line
  line=$({ grep -m1 -i error "$2" || head -n1 "$2"; } 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  echo "exit $1: ${line:-no output}"
}

cfg() { jq -r "$1" "$out/config.json"; }
enabled() { jq -e --arg key "$1" '(. // {}) | has($key)' "$out/config.json" > /dev/null; }

# fetch <url> <sha256> <dest>: download a pinned file and check its digest
fetch() {
  curl -sSfL --retry 2 --connect-timeout 30 --max-time 300 -o "$3.part" "$1" || return
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
    timeout "$TIMEOUT" npm ci --ignore-scripts --no-audit --no-fund --prefix "$dir" > /dev/null && touch "$dir/installed"
}
node_bin() { echo "$tools/node-$(sha256sum < "$here/tools/package-lock.json" | cut -c1-12)/node_modules/.bin/$1"; }

# python_tools: install ruff and vulture exactly as tools/requirements.txt pins them
python_tools() {
  local venv
  venv=$(dirname "$(dirname "$(python_bin ruff)")")
  [ -f "$venv/installed" ] && return
  python3 -m venv "$venv" &&
    timeout "$TIMEOUT" "$venv/bin/pip" install -q --require-hashes --only-binary=:all: \
      -r "$here/tools/requirements.txt" > /dev/null &&
    touch "$venv/installed"
}
python_bin() { echo "$tools/python-$(sha256sum < "$here/tools/requirements.txt" | cut -c1-12)/bin/$1"; }

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
  if [ -f "$dir/package.json" ]; then
    timeout "$TIMEOUT" env -C "$dir" npm ci --ignore-scripts --no-audit --no-fund > /dev/null 2> "$out/knip.err" || {
      rc=$?
      # A lockfile out of step with package.json, or one that does not parse, is the repository's own input.
      if grep -qE '^npm (ERR!|error) code (EUSAGE|EJSONPARSE)$' "$out/knip.err"; then
        say knip "failed: npm ci rejects the repository's package files: $(why "$rc" "$out/knip.err")"
      else
        say knip "not run: npm ci $(why "$rc" "$out/knip.err")"
      fi
      return
    }
  fi
  node_tools 2> "$out/knip.err" || { rc=$?; say knip "not run: cannot install knip: $(why "$rc" "$out/knip.err")"; return; }
  if [ "$(cfg '.javascript.knip | type')" = object ]; then
    jq .javascript.knip "$out/config.json" > "$out/knip.json"
    config=(--config "$out/knip.json")
  fi
  # knip's Lefthook plugin asks git for the hooks path; the machine's own git config (a global core.hooksPath)
  # would become entry globs outside the repository, so knip sees only the repository's config, as on a hosted runner.
  timeout "$TIMEOUT" env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
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
  local dir goos rc gover bin moddir gooses=()
  local each='{{$.Dir}}/{{.}}{{"\n"}}'
  enabled go || { say deadcode "not configured"; return; }
  dir=$(cfg '.go.root // "."')
  mapfile -t gooses < <(cfg '.go.goos // "linux" | if type == "array" then .[] else . end')
  # Download first (this also fetches any toolchain go.mod asks for): a network failure is "not run".
  env -C "$dir" timeout "$TIMEOUT" go mod download 2> "$out/deadcode.err" || {
    rc=$?
    if grep -q 'errors parsing go.mod' "$out/deadcode.err"; then
      say deadcode "failed: go.mod does not parse: $(grep -m1 -A1 'errors parsing go.mod' "$out/deadcode.err" | tail -n1)"
    else
      say deadcode "not run: cannot download the Go modules or toolchain: $(why "$rc" "$out/deadcode.err")"
    fi
    return
  }
  # deadcode type-checks with the Go it was built with, so build it with the Go this module selects
  # (+auto lets it go newer if x/tools itself needs that).
  gover=$(env -C "$dir" go env GOVERSION 2> "$out/deadcode.err") ||
    { rc=$?; say deadcode "not run: cannot tell which Go the module selects: $(why "$rc" "$out/deadcode.err")"; return; }
  bin=$tools/deadcode-$DEADCODE-$gover/deadcode
  [ -x "$bin" ] || GOBIN=$(dirname "$bin") GOTOOLCHAIN=$gover+auto timeout "$TIMEOUT" \
    go install "golang.org/x/tools/cmd/deadcode@v$DEADCODE" 2> "$out/deadcode.err" ||
    { rc=$?; say deadcode "not run: cannot install deadcode with $gover: $(why "$rc" "$out/deadcode.err")"; return; }
  moddir=$(dirname "$(env -C "$dir" go env GOMOD)")
  : > "$out/deadcode.runs"
  for goos in "${gooses[@]}"; do
    # With the network off, a load failure is the repository's own code.
    env -C "$dir" GOOS="$goos" GOPROXY=off timeout "$TIMEOUT" "$bin" -test ./... > "$out/deadcode.$goos.txt" 2> "$out/deadcode.err"
    rc=$?
    [ "$rc" != 124 ] || { say deadcode "not run: deadcode (GOOS=$goos) $(why "$rc" "$out/deadcode.err")"; return; }
    [ "$rc" = 0 ] || { say deadcode "failed: deadcode cannot load the packages (GOOS=$goos): $(why "$rc" "$out/deadcode.err")"; return; }
    # The files this GOOS builds ("built<TAB>GOOS<TAB>path", relative to the module like deadcode's
    # paths), then its findings ("dead<TAB>finding").
    env -C "$dir" GOOS="$goos" GOPROXY=off go list -f \
      "{{range .GoFiles}}$each{{end}}{{range .CgoFiles}}$each{{end}}{{range .TestGoFiles}}$each{{end}}{{range .XTestGoFiles}}$each{{end}}" \
      ./... 2> "$out/deadcode.err" |
      awk -v prefix="$moddir/" -v goos="$goos" 'index($0, prefix) == 1 { print "built\t" goos "\t" substr($0, length(prefix) + 1) }' \
      >> "$out/deadcode.runs" ||
      { rc=$?; say deadcode "failed: go list cannot load the packages (GOOS=$goos): $(why "$rc" "$out/deadcode.err")"; return; }
    sed 's/^/dead\t/' "$out/deadcode.$goos.txt" >> "$out/deadcode.runs"
  done
  # A function is dead only if every GOOS that builds its file reports it: a helper in a shared file
  # called only from one platform's files is live in that platform's build.
  awk -F '\t' '
    $1 == "built" { built[$2, $3] = 1; gooses[$2] = 1; next }
    { finding = substr($0, 6); if (!(finding in hits)) order[++m] = finding; hits[finding]++ }
    END {
      for (j = 1; j <= m; j++) {
        split(order[j], part, ":"); need = 0
        for (g in gooses) need += ((g, part[1]) in built)
        if (hits[order[j]] == need) print order[j]
      }
    }' "$out/deadcode.runs" > "$out/deadcode.txt"
  cfg '.go.ignore // [] | .[]' > "$out/deadcode.ignore"
  grep -Ev -f "$out/deadcode.ignore" "$out/deadcode.txt" > "$out/deadcode.kept" 2> "$out/deadcode.err"
  rc=$?
  [ "$rc" -le 1 ] || { say deadcode "failed: go.ignore in .github/quality.yml is not a valid regex list ($(why "$rc" "$out/deadcode.err"))"; return; }
  filter deadcode "$dir" error -efm='%f:%l:%c: %m' < "$out/deadcode.kept"
}

check_jscpd() {
  local rc ignore paths=()
  mapfile -t paths < <(cfg '.duplicates.paths // ["."] | .[]')
  ignore=$(cfg '.duplicates.ignore // [] | join(",")')
  node_tools 2> "$out/jscpd.err" || { rc=$?; say jscpd "not run: cannot install jscpd: $(why "$rc" "$out/jscpd.err")"; return; }
  rm -rf "$out/jscpd"
  timeout "$TIMEOUT" "$(node_bin jscpd)" --reporters sarif --output "$out/jscpd" ${ignore:+--ignore "$ignore"} \
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
  timeout "$TIMEOUT" "$(python_bin ruff)" check --no-cache --select F --output-format sarif "${roots[@]}" \
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
  timeout "$TIMEOUT" "$(python_bin vulture)" --min-confidence 60 "${args[@]}" "${roots[@]}" > "$out/vulture.txt" 2> "$out/vulture.err"
  rc=$? # 3 means it found unused code; 1 also when it could not read a file
  # Files vulture could not read: a syntax error or a bad encoding.
  sed -nE "s/^(.+):[0-9]+: invalid syntax at .*/\1/p; s#^Error: Could not read file ($PWD/)?(.+) - \$#\2#p" \
    "$out/vulture.err" | sed 's#^\./##' | sort -u > "$out/vulture.unread"
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { [ "$rc" = 1 ] && [ -s "$out/vulture.unread" ]; } ||
    { say vulture "not run: vulture $(why "$rc" "$out/vulture.err")"; return; }
  filter vulture . none -efm='%f:%l: %m' < "$out/vulture.txt"
  # The measure is partial when a file it could not read is one this pull request changes.
  unread=$(git diff --text --name-only "$mb" HEAD | grep -Fxf "$out/vulture.unread" | paste -sd, - | sed 's/,/, /g')
  [ -z "$unread" ] || grep -q '^not run' "$out/vulture.status" ||
    say vulture "partial, could not read $unread: $(cat "$out/vulture.status")"
}

for check in "${checks[@]}"; do rm -f "$out/$check.status" "$out/$check.findings"; done
reason=$(setup)
case $? in
  0)
    rm -f "$out/setup.reason"
    mb=$(cat "$out/merge_base")
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

if [ "$mode" = gate ] && grep -qs '^failed' "$out/knip.status" "$out/deadcode.status" "$out/ruff.status"; then
  echo "::error::The dead-code gate failed; see the findings above and the Quality report."
  exit 1
fi
exit 0
