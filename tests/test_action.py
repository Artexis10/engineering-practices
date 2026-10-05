"""Fixture tests for the quality action; they gate moving the v1 tag.

Each test builds a throwaway repository with a base and a head commit and runs
scripts/checks.sh or scripts/report.py in it, as the action does on a pull
request. The first run downloads the pinned tools (set EP_TOOLS to reuse them).

    python3 -m unittest discover -s tests -v
"""

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


def repository(base, head):
    """A git repository whose HEAD~1 holds `base` and HEAD adds `head`; returns (path, base commit)."""
    path = Path(tempfile.mkdtemp(prefix="ep-fixture-"))

    def git(*args):
        return subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True, text=True).stdout

    git("init", "-q", "-b", "main")
    for files in (base, head):
        for name, text in files.items():
            (path / name).parent.mkdir(parents=True, exist_ok=True)
            (path / name).write_text(text)
        git("add", "-A")
        git("-c", "user.name=fixture", "-c", "user.email=fixture@example.com", "commit", "-q", "-m", "change")
    return path, git("rev-parse", "HEAD~1").strip()


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
    path, commit = repository(base, head)
    proc, out = run(path, commit, str(SCRIPTS / "checks.sh"), "gate", **env)
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
        base = {
            ".github/quality.yml": "go:\n  goos: windows\n",
            "go.mod": "module example.com/fixture\n\ngo 1.22\n",
            "main.go": "package main\n\nfunc main() {}\n",
        }
        # Built only for windows, so it is seen only when deadcode runs with the configured GOOS.
        code, out = gate(base, {"main_windows.go": "package main\n\nfunc unreachable() {}\n"})
        status, findings = result(out, "deadcode")
        self.assertEqual(code, 1, status)
        self.assertIn("main_windows.go:3: unreachable func: unreachable", findings)

    def test_tool_error_is_neutral_and_reported(self):
        # The registry is unreachable and the lockfile lacks a dependency, so npm ci cannot install.
        package = PACKAGE.replace('"private": true', '"private": true, "dependencies": {"left-pad": "1.3.0"}')
        code, out = gate(
            JS, {"web/package.json": package}, npm_config_registry="http://127.0.0.1:9/", npm_config_fetch_retries="0"
        )
        status, _ = result(out, "knip")
        self.assertEqual(code, 0, status)
        self.assertRegex(status, r"^not run: npm ci exit \d+: \S")


class Report(unittest.TestCase):
    def test_reports_proof_weight_per_class(self):
        config = "classes:\n  tests: ['tests/*']\n  product: ['src/*']\n"
        base = {".github/quality.yml": config, "src/app.py": "x = 1\n"}
        head = {"src/app.py": "x = 2\ny = 3\n", "tests/test_app.py": "a\nb\nc\n", "notes.txt": "n\n"}
        path, commit = repository(base, head)
        _, out = run(path, commit, str(SCRIPTS / "checks.sh"), "gate")
        proc, _ = run(path, commit, "python3", str(SCRIPTS / "report.py"), EP_OUT=str(out))

        def row(name):
            line = next(line for line in proc.stdout.splitlines() if line.startswith(f"| {name} |"))
            return [cell.strip() for cell in line.strip("|").split("|")]

        self.assertEqual(row("product"), ["product", "1", "2", "1"])
        self.assertEqual(row("tests"), ["tests", "1", "3", "0"])
        self.assertEqual(row("unclassified"), ["unclassified", "1", "1", "0"])
        self.assertIn("Product +2 lines against proof +3 lines (tests)", proc.stdout)


if __name__ == "__main__":
    unittest.main()
