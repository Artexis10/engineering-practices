"""Fixture tests for the quality action; they gate moving the v1 tag.

Each test builds a throwaway repository with a base and a head commit and runs
scripts/checks.sh or scripts/report.py in it, as the action does on a pull
request. The first run downloads the pinned tools (set EP_TOOLS to reuse them).

    python3 -m unittest discover -s tests -v
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
TOOLS = os.environ.get("EP_TOOLS") or tempfile.mkdtemp(prefix="ep-tools-")

PACKAGE = '{"name": "fixture", "version": "1.0.0", "private": true, "main": "src/index.ts"}\n'
LOCK = (
    '{"name": "fixture", "version": "1.0.0", "lockfileVersion": 3, "requires": true,'
    ' "packages": {"": {"name": "fixture", "version": "1.0.0"}}}\n'
)
UTIL = "export function used() {\n  return 1;\n}\n\nexport function oldDead() {\n  return 2;\n}\n"
# A TS/JS package in a subdirectory, with an unused export already on main.
JS = {
    ".github/quality.yml": "javascript:\n  root: web\n",
    "web/package.json": PACKAGE,
    "web/package-lock.json": LOCK,
    "web/src/index.ts": 'import { used } from "./util";\nconsole.log(used());\n',
    "web/src/util.ts": UTIL,
}
# A Python package with an unused import already on main.
PY = {
    ".github/quality.yml": "python:\n  roots: [src]\n",
    "src/app.py": "import os\nimport sys\n\nprint(sys.argv)\n",
}
# A Go module whose CI targets windows.
GO = {
    ".github/quality.yml": "go:\n  goos: windows\n",
    "go.mod": "module example.com/fixture\n\ngo 1.22\n",
    "main.go": "package main\n\nfunc main() {}\n",
}
LEFT_PAD = {
    "1.2.0": "sha512-OQadpCyFCT/VLniZQgym8d3/ofIJtuZyw2ibsVeIUOexKgW/osn8+mMFJbwGMPeDC4GnLzD8q115WPCDx4YRWg==",
    "1.3.0": "sha512-XI5MPzVNApjAyhQzphX8BkmKsKUxD4LdyK24iZeQGinBN9yTQT3bFlCBy/aVx2HrNcqQGsdot8ghrjyrvMCoEA==",
}


def left_pad(version):
    """web/package.json and its lockfile declaring left-pad, which no code imports."""
    package, lock = json.loads(PACKAGE), json.loads(LOCK)
    package["dependencies"] = lock["packages"][""]["dependencies"] = {"left-pad": version}
    lock["packages"]["node_modules/left-pad"] = {
        "version": version,
        "resolved": f"https://registry.npmjs.org/left-pad/-/left-pad-{version}.tgz",
        "integrity": LEFT_PAD[version],
    }
    return {"web/package.json": json.dumps(package, indent=2), "web/package-lock.json": json.dumps(lock, indent=2)}


def git(path, *args):
    identity = ["-c", "user.name=fixture", "-c", "user.email=fixture@example.com"]
    return subprocess.run(["git", "-C", str(path), *identity, *args], check=True, capture_output=True, text=True).stdout


def commit(path, files):
    """Write `files` into the repository and commit them; returns the commit."""
    for name, text in files.items():
        (path / name).parent.mkdir(parents=True, exist_ok=True)
        (path / name).write_text(text)
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "change")
    return git(path, "rev-parse", "HEAD").strip()


def repository(base, head):
    """A git repository whose HEAD~1 holds `base` and HEAD adds `head`; returns (path, base commit)."""
    path = Path(tempfile.mkdtemp(prefix="ep-fixture-"))
    git(path, "init", "-q", "-b", "main")
    base_commit = commit(path, base)
    commit(path, head)
    return path, base_commit


def main_moved_on(base, branch, main_later, merge_ref):
    """A pull request checked out after main moved on: returns (path, event base, pull request head).

    main holds `base`, which the event recorded; the pull request branches off it and adds `branch`;
    main then gains `main_later`. With `merge_ref`, HEAD merges the pull request into main as it is
    now, as actions/checkout does. Without, HEAD is the pull request's own head after its branch
    merged main, and origin/main is fetched.
    """
    path = Path(tempfile.mkdtemp(prefix="ep-fixture-"))
    git(path, "init", "-q", "-b", "main")
    event_base = commit(path, base)
    git(path, "checkout", "-q", "-b", "pr")
    head = commit(path, branch)
    git(path, "checkout", "-q", "main")
    commit(path, main_later)
    if merge_ref:
        git(path, "merge", "-q", "--no-ff", "-m", "merge", "pr")
    else:
        git(path, "update-ref", "refs/remotes/origin/main", "main")
        git(path, "checkout", "-q", "pr")
        git(path, "merge", "-q", "--no-ff", "-m", "merge main", "main")
        head = git(path, "rev-parse", "HEAD").strip()
    return path, event_base, head


def row(markdown, name):
    """The cells of the one report table row for `name`; a second row for it is an error."""
    [line] = [line for line in markdown.splitlines() if line.startswith(f"| {name} |")]
    return [cell.strip() for cell in line.strip("|").split("|")]


def run(path, base, *command, **env):
    """Run a script in the repository as the action would; returns (exit code, output dir)."""
    out = Path(tempfile.mkdtemp(prefix="ep-out-"))
    proc = subprocess.run(
        command,
        cwd=path,
        env={**os.environ, "EP_OUT": str(out), "EP_TOOLS": TOOLS, "EP_BASE": base, **env},
        capture_output=True,
        text=True,
        check=False,
    )
    return proc, out


def gate(base, head, **env):
    path, base_commit = repository(base, head)
    proc, out = run(path, base_commit, str(SCRIPTS / "checks.sh"), "gate", **env)
    return proc.returncode, out


def result(out, check):
    findings = out / f"{check}.findings"
    return (out / f"{check}.status").read_text().strip(), findings.read_text() if findings.exists() else ""


class Gate(unittest.TestCase):
    def test_added_unused_export_fails(self):
        code, out = gate(JS, {"web/src/util.ts": UTIL + "\nexport function addedDead() {\n  return 3;\n}\n"})
        status, findings = result(out, "knip")
        self.assertEqual(code, 1, status)
        self.assertIn("web/src/util.ts:9: Unused export: addedDead", findings)

    def test_edit_beside_old_dead_code_passes(self):
        code, out = gate(JS, {"web/src/util.ts": UTIL.replace("return 1;", "return 10;")})
        self.assertIn("oldDead", (out / "knip.sarif").read_text())  # knip still reports it on the head
        self.assertEqual((code, result(out, "knip")[0]), (0, "passed"))

    def test_declared_entry_point_passes(self):
        config = "javascript:\n  root: web\n  knip:\n    entry: [src/worker.ts]\n"
        code, out = gate({**JS, ".github/quality.yml": config}, {"web/src/worker.ts": 'console.log("worker");\n'})
        self.assertEqual((code, result(out, "knip")[0]), (0, "passed"))

    def test_added_unused_file_fails(self):
        code, out = gate(JS, {"web/src/worker.ts": 'console.log("worker");\n'})
        status, findings = result(out, "knip")
        self.assertEqual(code, 1, status)
        self.assertIn("web/src/worker.ts:1: Unused file", findings)

    def test_added_unreachable_go_function_fails_for_the_configured_goos(self):
        # Built only for windows, so it is seen only when deadcode runs with the configured GOOS.
        code, out = gate(GO, {"main_windows.go": "package main\n\nfunc unreachable() {}\n"})
        status, findings = result(out, "deadcode")
        self.assertEqual(code, 1, status)
        self.assertIn("main_windows.go:3: unreachable func: unreachable", findings)

    def test_edit_of_already_unused_file_passes(self):
        base = {**JS, "web/src/legacy.ts": "// legacy helper\nconsole.log('x');\n"}
        code, out = gate(base, {"web/src/legacy.ts": "// legacy helper, reworded\nconsole.log('x');\n"})
        self.assertIn("legacy.ts", (out / "knip.sarif").read_text())  # knip still reports it on the head
        self.assertEqual((code, result(out, "knip")[0]), (0, "passed"))

    def test_added_unused_dependency_fails(self):
        code, out = gate(JS, left_pad("1.3.0"))
        status, findings = result(out, "knip")
        self.assertEqual(code, 1, status)
        self.assertIn("Unused dependency: left-pad", findings)

    def test_bump_of_already_unused_dependency_passes(self):
        code, out = gate({**JS, **left_pad("1.2.0")}, left_pad("1.3.0"))
        self.assertIn("left-pad", (out / "knip.sarif").read_text())  # knip still reports it on the head
        self.assertEqual((code, result(out, "knip")[0]), (0, "passed"))

    def test_configuration_error_fails(self):
        config = "javascript:\n  root: web\n  knip:\n    entry: 5\n"
        code, out = gate(JS, {".github/quality.yml": config})
        status, _ = result(out, "knip")
        self.assertEqual(code, 1, status)
        self.assertRegex(status, r"^failed: knip reports a configuration error: exit 2: \S")

    def test_broken_lockfile_fails(self):
        code, out = gate(JS, {"web/package-lock.json": "{\n"})
        status, _ = result(out, "knip")
        self.assertEqual(code, 1, status)
        self.assertRegex(status, r"^failed: npm ci rejects the repository's package files: exit \d+: \S")

    def test_listed_goos_report_only_functions_dead_under_all_of_them(self):
        base = {
            ".github/quality.yml": "go:\n  goos: [linux, windows]\n",
            "go.mod": GO["go.mod"],
            "main.go": "package main\n\nfunc main() { run() }\n",
            "run_windows.go": "package main\n\nfunc run() {}\n",
            "run_other.go": "//go:build !windows\n\npackage main\n\nfunc run() {}\n",
        }
        head = {  # helper is called only from the non-windows build, so it ships in linux
            "run_other.go": "//go:build !windows\n\npackage main\n\nfunc run() { helper() }\n",
            "helper.go": "package main\n\nfunc helper() {}\n\nfunc unused() {}\n",
        }
        code, out = gate(base, head)
        status, findings = result(out, "deadcode")
        self.assertEqual(code, 1, status)
        self.assertIn("helper.go:5: unreachable func: unused", findings)
        self.assertNotIn("unreachable func: helper", findings)

    def test_go_code_that_does_not_load_fails(self):
        code, out = gate(GO, {"main.go": 'package main\n\nimport _ "example.com/fixture/missing"\n\nfunc main() {}\n'})
        status, _ = result(out, "deadcode")
        self.assertEqual(code, 1, status)
        self.assertRegex(status, r"^failed: deadcode cannot load the packages \(GOOS=windows\): exit \d+: \S")

    def test_go_root_below_the_module_root_reports_its_dead_code(self):
        base = {
            ".github/quality.yml": "go:\n  root: cmd/app\n",
            "go.mod": GO["go.mod"],
            "cmd/app/main.go": "package main\n\nfunc main() {}\n",
        }
        code, out = gate(base, {"cmd/app/extra.go": "package main\n\nfunc unreachable() {}\n"})
        status, findings = result(out, "deadcode")
        self.assertEqual(code, 1, status)
        self.assertIn("cmd/app/extra.go:3: unreachable func: unreachable", findings)

    def test_spent_time_budget_is_neutral_and_reported(self):
        code, out = gate(
            JS, {"web/src/util.ts": UTIL + "\nexport function addedDead() {\n  return 3;\n}\n"}, EP_BUDGET="0"
        )
        status, _ = result(out, "knip")
        self.assertEqual(code, 0, status)
        self.assertRegex(status, r"^not run: .*time budget of 0s used up$")

    def test_go_mod_that_does_not_parse_fails(self):
        code, out = gate(GO, {"go.mod": GO["go.mod"] + "\nbogus directive\n"})
        status, _ = result(out, "deadcode")
        self.assertEqual(code, 1, status)
        self.assertRegex(status, r"^failed: go.mod does not parse: go.mod:\d+: unknown directive: bogus")

    def test_added_unused_python_import_fails(self):
        code, out = gate(PY, {"src/app.py": "import json\n" + PY["src/app.py"]})
        status, findings = result(out, "ruff")
        self.assertEqual(code, 1, status)
        self.assertIn("src/app.py:1: `json` imported but unused", findings)

    def test_added_undefined_python_name_fails(self):
        code, out = gate(PY, {"src/app.py": PY["src/app.py"].replace("sys.argv", "sys.argv, missing")})
        status, findings = result(out, "ruff")
        self.assertEqual(code, 1, status)
        self.assertIn("src/app.py:4: Undefined name `missing`", findings)

    def test_edit_beside_old_unused_python_import_passes(self):
        code, out = gate(PY, {"src/app.py": PY["src/app.py"].replace("import sys", "import sys  # arguments")})
        self.assertIn("`os` imported but unused", (out / "ruff.sarif").read_text())  # ruff still reports it
        self.assertEqual((code, result(out, "ruff")[0]), (0, "passed"))

    def test_go_module_download_failure_is_neutral(self):
        # A required module whose host cannot resolve, fetched directly rather than through the proxy.
        head = {"go.mod": GO["go.mod"] + "\nrequire example.invalid/dep v1.0.0\n"}
        code, out = gate(GO, head, GOPRIVATE="example.invalid")
        status, _ = result(out, "deadcode")
        self.assertEqual(code, 0, status)
        self.assertRegex(status, r"^not run: cannot download the Go modules or toolchain: exit \d+: \S")

    def test_tool_error_is_neutral_and_reported(self):
        # The registry is down and nothing is cached, so npm ci cannot install a dependency.
        env = {"npm_config_registry": "http://127.0.0.1:9/", "npm_config_fetch_retries": "0"}
        code, out = gate(JS, left_pad("1.3.0"), npm_config_cache=tempfile.mkdtemp(prefix="ep-npm-"), **env)
        status, _ = result(out, "knip")
        self.assertEqual(code, 0, status)
        self.assertRegex(status, r"^not run: npm ci exit \d+: \S")


class Base(unittest.TestCase):
    """main gains an unused export and a file after the pull request opens; only its own line counts."""

    def check_only_the_pull_requests_line_counts(self, merge_ref):
        base = {**JS, ".github/quality.yml": JS[".github/quality.yml"] + "classes:\n  product: ['web/src/*']\n"}
        main_later = {
            "web/src/util.ts": UTIL + "\nexport function mainDead() {\n  return 4;\n}\n",
            "web/src/more.ts": "1\n2\n",
        }
        branch = {"web/src/index.ts": JS["web/src/index.ts"] + 'console.log("pull request");\n'}
        path, event_base, head = main_moved_on(base, branch, main_later, merge_ref)
        proc, out = run(path, event_base, str(SCRIPTS / "checks.sh"), "gate", EP_HEAD=head, EP_BASE_REF="main")
        report, _ = run(path, event_base, "python3", str(SCRIPTS / "report.py"), EP_OUT=str(out))
        self.assertIn("mainDead", (out / "knip.sarif").read_text())  # knip reports main's new dead code on HEAD
        self.assertEqual((proc.returncode, result(out, "knip")[0]), (0, "passed"))
        self.assertEqual(row(report.stdout, "product"), ["product", "1", "1", "0"])  # only the pull request's line

    def test_on_the_merge_ref(self):
        self.check_only_the_pull_requests_line_counts(merge_ref=True)

    def test_on_a_head_whose_branch_merged_main(self):
        self.check_only_the_pull_requests_line_counts(merge_ref=False)


class Report(unittest.TestCase):
    def report(self, base, head):
        path, base_commit = repository(base, head)
        _, out = run(path, base_commit, str(SCRIPTS / "checks.sh"), "gate")
        return run(path, base_commit, "python3", str(SCRIPTS / "report.py"), EP_OUT=str(out))[0].stdout

    def test_reports_proof_weight_per_class(self):
        config = "classes:\n  tests: ['tests/*']\n  product: ['src/*']\n"
        base = {".github/quality.yml": config, "src/app.py": "x = 1\n"}
        head = {"src/app.py": "x = 2\ny = 3\n", "tests/test_app.py": "a\nb\nc\n", "notes.txt": "n\n"}
        report = self.report(base, head)
        self.assertEqual(row(report, "product"), ["product", "2", "3", "1"])  # notes.txt matches no class
        self.assertEqual(row(report, "tests"), ["tests", "1", "3", "0"])
        self.assertIn("Product +3 lines against proof +3 lines (tests)", report)

    def test_lockfiles_count_as_generated(self):
        base = {".github/quality.yml": "classes:\n  tests: ['tests/*']\n", "web/package-lock.json": "{\n}\n"}
        report = self.report(base, {"web/package-lock.json": '{\n  "a": 1,\n  "b": 2\n}\n', "src/app.ts": "a\nb\n"})
        self.assertEqual(row(report, "generated"), ["generated", "1", "2", "0"])
        self.assertIn("Product +2 lines against proof +0 lines", report)


if __name__ == "__main__":
    unittest.main()
