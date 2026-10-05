#!/usr/bin/env bash
# shellcheck disable=SC2329 # the check_* functions are called as "check_$check"
# Run the dead-code gate or the review measures on the repository in the
# current directory, over the diff between the merge base and HEAD.
#
#   checks.sh gate       knip (TS/JS) and deadcode (Go); exits 1 when either
#                        reports a finding on a line the diff adds
#   checks.sh measures   jscpd and vulture; never fails
#
# Each check writes $EP_OUT/<check>.status ("passed", "failed: ...",
# "N on added lines", "not configured" or "not run: <reason>") and
# $EP_OUT/<check>.findings (one "path:line: message" per finding).
# A tool that errors or times out is "not run", never a failure: the tools
# come from the network, and an outage must not freeze every merge.
#
# Environment: EP_BASE (the pull request's base commit), EP_OUT and EP_TOOLS
# (default under $RUNNER_TEMP). Needs bash, git, curl, jq and python3; node for
# knip and jscpd; go for deadcode. Linux x86_64 only.
set -uo pipefail

# Pinned tools. Moving a version is a change to this file, gated by the fixture tests.
REVIEWDOG=0.21.2 REVIEWDOG_SHA256=30413aa3c7443e9c3c157fe5766cad40e3bb39a32e210ee69b710a8d5c4b8e51
YQ=4.54.1 YQ_SHA256=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
KNIP=6.39.0 DEADCODE=0.51.0 JSCPD=5.4.0 VULTURE=2.16
TIMEOUT=600 # seconds, per tool command

mode=${1:-}
case $mode in
  gate) checks=(knip deadcode) ;;
  measures) checks=(jscpd vulture) ;;
  *) echo "usage: checks.sh gate|measures" >&2; exit 2 ;;
esac
out=${EP_OUT:-${RUNNER_TEMP:?}/engineering-practices/out}
tools=${EP_TOOLS:-${RUNNER_TEMP:?}/engineering-practices/tools}
mkdir -p "$out" "$tools"
rd=$tools/reviewdog-$REVIEWDOG yq=$tools/yq-$YQ

# say <check> <status>: record a check's result
say() { printf '%s\n' "$2" > "$out/$1.status"; echo "$1: $2"; }

# why <exit code> <stderr file>: one line saying why a command gave no result
why() {
  if [ "$1" = 124 ]; then echo "timed out after ${TIMEOUT}s"; return; fi
  local line
  line=$(grep -m1 -i error "$2" 2>/dev/null || head -n1 "$2" 2>/dev/null)
  echo "exit $1: ${line:-no output}"
}

cfg() { jq -r "$1" "$out/config.json"; }
enabled() { jq -e --arg key "$1" '(. // {}) | has($key)' "$out/config.json" > /dev/null; }

# fetch <url> <sha256> <dest>: download a pinned file and check its digest
fetch() {
  curl -sSfL --retry 2 -o "$3.part" "$1" && echo "$2  $3.part" | sha256sum -c --quiet - && mv "$3.part" "$3"
}

# setup: install reviewdog and yq, read the config, find the merge base.
# Prints the reason and fails when the checks cannot run at all.
setup() {
  local rc err=$out/setup.err
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
    { rc=$?; echo "cannot read .github/quality.yml: $(why "$rc" "$err")"; return 1; }
  [ -n "${EP_BASE:-}" ] || { echo "no pull request base commit; the action runs on pull_request events"; return 1; }
  git merge-base "$EP_BASE" HEAD > "$out/merge_base" 2> "$err" ||
    { rc=$?; echo "no merge base with $EP_BASE ($(why "$rc" "$err")); check out with fetch-depth: 0"; return 1; }
}

# filter <check> <dir> <fail level> <reviewdog input flags...> < tool output
# Keeps the findings on lines the diff adds. Runs in <dir>, where the tool ran,
# so that reviewdog maps the tool's relative paths onto the diff.
filter() {
  local check=$1 dir=$2 level=$3 rc n
  shift 3
  env -C "$dir" "$rd" "$@" -name="$check" -reporter=rdjsonl -filter-mode=added -fail-level="$level" \
    -diff="git diff $(cat "$out/merge_base") HEAD" > "$out/$check.rdjsonl" 2> "$out/$check.err"
  rc=$?
  if [ "$rc" -ne 0 ] && [ ! -s "$out/$check.rdjsonl" ]; then
    say "$check" "not run: reviewdog $(why "$rc" "$out/$check.err")"
    return
  fi
  jq -r --arg dir "$dir" '"\(if $dir == "." then "" else $dir + "/" end)\(.location.path):\(.location.range.start.line // 1): \(.message)"' \
    "$out/$check.rdjsonl" > "$out/$check.findings"
  n=$(wc -l < "$out/$check.findings")
  if [ "$level" = none ]; then
    if [ "$n" -gt 0 ]; then say "$check" "$n on added lines"; else say "$check" "none on added lines"; fi
  elif [ "$rc" -ne 0 ]; then
    say "$check" "failed: $n on added lines"
  else
    say "$check" passed
  fi
  sed 's/^/  /' "$out/$check.findings"
}

check_knip() {
  local dir rc config=()
  enabled javascript || { say knip "not configured"; return; }
  dir=$(cfg '.javascript.root // "."')
  if [ -f "$dir/package.json" ]; then
    timeout "$TIMEOUT" env -C "$dir" npm ci --ignore-scripts --no-audit --no-fund > /dev/null 2> "$out/knip.err" ||
      { rc=$?; say knip "not run: npm ci $(why "$rc" "$out/knip.err")"; return; }
  fi
  if [ "$(cfg '.javascript.knip | type')" = object ]; then
    jq .javascript.knip "$out/config.json" > "$out/knip.json"
    config=(--config "$out/knip.json")
  fi
  timeout "$TIMEOUT" npx --yes "knip@$KNIP" --directory "$dir" "${config[@]}" --include files,exports,dependencies \
    --reporter sarif --no-progress > "$out/knip.sarif" 2> "$out/knip.err"
  rc=$?
  [ "$rc" -le 1 ] || { say knip "not run: knip $(why "$rc" "$out/knip.err")"; return; }
  # An unused file's result has no region, and the added-line filter drops results without one.
  jq '(.runs[].results[].locations[]?.physicalLocation | select(.region == null) | .region) = {startLine: 1}' \
    "$out/knip.sarif" > "$out/knip.lines.sarif" 2> "$out/knip.err" ||
    { rc=$?; say knip "not run: knip output is not SARIF ($(why "$rc" "$out/knip.err"))"; return; }
  filter knip "$dir" error -f=sarif < "$out/knip.lines.sarif"
}

check_deadcode() {
  local dir goos rc bin=$tools/deadcode-$DEADCODE/deadcode
  enabled go || { say deadcode "not configured"; return; }
  dir=$(cfg '.go.root // "."')
  goos=$(cfg '.go.goos // "linux"')
  [ -x "$bin" ] || GOBIN=$(dirname "$bin") timeout "$TIMEOUT" go install "golang.org/x/tools/cmd/deadcode@v$DEADCODE" 2> "$out/deadcode.err" ||
    { rc=$?; say deadcode "not run: cannot install deadcode: $(why "$rc" "$out/deadcode.err")"; return; }
  env -C "$dir" GOOS="$goos" timeout "$TIMEOUT" "$bin" -test ./... > "$out/deadcode.txt" 2> "$out/deadcode.err" ||
    { rc=$?; say deadcode "not run: deadcode (GOOS=$goos) $(why "$rc" "$out/deadcode.err")"; return; }
  cfg '.go.ignore // [] | .[]' > "$out/deadcode.ignore"
  grep -Ev -f "$out/deadcode.ignore" "$out/deadcode.txt" > "$out/deadcode.kept" 2> "$out/deadcode.err"
  rc=$?
  [ "$rc" -le 1 ] || { say deadcode "not run: go.ignore in .github/quality.yml is not a valid regex list ($(why "$rc" "$out/deadcode.err"))"; return; }
  filter deadcode "$dir" error -efm='%f:%l:%c: %m' < "$out/deadcode.kept"
}

check_jscpd() {
  local rc ignore paths=()
  mapfile -t paths < <(cfg '.duplicates.paths // ["."] | .[]')
  ignore=$(cfg '.duplicates.ignore // [] | join(",")')
  rm -rf "$out/jscpd"
  timeout "$TIMEOUT" npx --yes "jscpd@$JSCPD" --reporters sarif --output "$out/jscpd" ${ignore:+--ignore "$ignore"} \
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

check_vulture() {
  local rc key value roots=() args=() venv=$tools/vulture-$VULTURE
  enabled python || { say vulture "not configured"; return; }
  mapfile -t roots < <(cfg '.python.roots // ["."] | .[]')
  for key in ignore_names ignore_decorators exclude; do
    value=$(cfg ".python.$key // [] | join(\",\")")
    [ -z "$value" ] || args+=("--${key//_/-}" "$value")
  done
  [ -x "$venv/bin/vulture" ] || { python3 -m venv "$venv" && "$venv/bin/pip" install -q "vulture==$VULTURE"; } > /dev/null 2> "$out/vulture.err" ||
    { rc=$?; say vulture "not run: cannot install vulture: $(why "$rc" "$out/vulture.err")"; return; }
  timeout "$TIMEOUT" "$venv/bin/vulture" --min-confidence 60 "${args[@]}" "${roots[@]}" > "$out/vulture.txt" 2> "$out/vulture.err"
  rc=$? # 3 means it found unused code
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || { say vulture "not run: vulture $(why "$rc" "$out/vulture.err")"; return; }
  filter vulture . none -efm='%f:%l: %m' < "$out/vulture.txt"
}

for check in "${checks[@]}"; do rm -f "$out/$check.status" "$out/$check.findings"; done
if reason=$(setup); then
  rm -f "$out/setup.reason"
  for check in "${checks[@]}"; do "check_$check"; done
else
  printf '%s\n' "$reason" > "$out/setup.reason"
  for check in "${checks[@]}"; do say "$check" "not run: $reason"; done
fi

if [ "$mode" = gate ] && grep -qs '^failed' "$out/knip.status" "$out/deadcode.status"; then
  echo "The pull request adds dead code. Remove it, or declare a real entry point in .github/quality.yml."
  exit 1
fi
exit 0
