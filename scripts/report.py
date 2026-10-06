#!/usr/bin/env python3
"""Render the Quality report and publish it: the job summary and one sticky PR comment.

Reads what scripts/checks.sh left in EP_OUT, measures proof weight with git and
test-job runtime with the GitHub Actions API. It never fails the job: a measure
it cannot compute says "not run" and why, never zero.
"""

import fnmatch
import json
import os
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

MARKER = "<!-- engineering-practices:quality-report -->"
AUTHOR = "github-actions[bot]"  # the GITHUB_TOKEN's identity, which owns the report comment
REGISTRY = "https://github.com/Artexis10/engineering-practices/blob/v1/PRACTICES.md"
GATE = [
    ("knip", "Unused files, exports and dependencies (knip)"),
    ("deadcode", "Unreachable Go functions (deadcode)"),
    ("ruff", "Unused imports and variables, undefined names, redefinitions (ruff F rules)"),
]
MEASURES = [
    ("jscpd", "New duplicate code, exact token clones (jscpd)"),
    ("vulture", "Python definitions nothing references (vulture, confidence 60+)"),
]
NOT_PROOF = {"product", "docs", "generated"}  # every other path class counts as proof
# Lockfiles at any depth are always "generated", whatever configured class also matches them.
LOCKFILES = [
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb",
    "Cargo.lock", "go.sum", "uv.lock", "poetry.lock", "Pipfile.lock", "composer.lock", "Gemfile.lock",
]
SHOWN = 30  # findings listed per check
SAMPLES, MINIMUM = 5, 3  # main runs in the runtime median; fewer than MINIMUM is not comparable

env = os.environ.get
OUT = Path(env("EP_OUT") or Path(os.environ["RUNNER_TEMP"]) / "engineering-practices" / "out")
# The checks share one time budget from their first start; the report may run RESERVE seconds past it
# to post, and the runtime measure stops POSTING seconds before that so posting keeps its time.
RESERVE, POSTING = 60, 20
_started = OUT / "started"
DEADLINE = int(_started.read_text()) + int(env("EP_BUDGET") or 720) + RESERVE if _started.exists() else None


class BudgetSpent(Exception):
    def __str__(self):
        return "time budget used up"


def cell(value):
    """A value safe inside a Markdown table cell: one line, pipes escaped."""
    return " ".join(str(value).split()).replace("|", "\\|")


def read(name):
    path = OUT / name
    return path.read_text().strip() if path.exists() else None


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=False)


def api(path, method="GET", body=None, keep=0):
    """Call the GitHub API, leaving `keep` seconds of the deadline for later work."""
    left = 30 if DEADLINE is None else min(30, DEADLINE - keep - time.time())
    if left <= 0:
        raise BudgetSpent
    request = urllib.request.Request(
        env("GITHUB_API_URL", "https://api.github.com") + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {env('GITHUB_TOKEN')}", "Accept": "application/vnd.github+json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=left) as response:
            return json.load(response)
    except (TimeoutError, urllib.error.URLError) as error:
        if DEADLINE is not None and time.time() >= DEADLINE - keep:
            raise BudgetSpent from error
        raise


def checks(rows):
    """A result table for checks.sh checks, then each check's findings."""
    table = ["| Check | Result |", "|---|---|"]
    details = []
    for name, label in rows:
        table.append(f"| {label} | {cell(read(name + '.status') or 'not run: the step recorded no result')} |")
        findings = (read(name + ".findings") or "").splitlines()
        if findings:
            more = [f"... and {len(findings) - SHOWN} more"] if len(findings) > SHOWN else []
            # An indented code block has no closing fence for a finding to forge.
            details += ["", f"**{label}**", "", *("    " + line for line in findings[:SHOWN] + more)]
    return table + details


def verdict():
    statuses = [read(name + ".status") or "not run" for name, _ in GATE]
    ran = [s for s in statuses if s != "not configured"]
    missing = [s for s in ran if s.startswith("not run")]
    if any(s.startswith("failed") for s in statuses):
        return "failed"
    if not ran:
        return "not configured"
    if len(missing) == len(ran):
        return "not run"
    return "passed where it ran; a check did not run" if missing else "passed"


def matches(path, pattern):
    # `*` crosses directories; a leading `**/` also matches at the root.
    return fnmatch.fnmatchcase(path, pattern) or (pattern.startswith("**/") and fnmatch.fnmatchcase(path, pattern[3:]))


def proof_weight(config, base):
    if not base:
        return [f"Not run: {read('setup.reason') or 'no merge base was recorded'}."]
    diff = git("diff", "--numstat", "-z", "-M", base, "HEAD")
    if diff.returncode:
        return [f"Not run: git diff failed ({(diff.stderr.strip().splitlines() or ['no output'])[0]})."]
    classes = {
        name: [globs] if isinstance(globs, str) else (globs or [])
        for name, globs in (config.get("classes") or {}).items()
    }
    totals = {}  # class: [files, lines added, lines removed, binary files]
    fields = diff.stdout.split("\0")
    i = 0
    while i < len(fields) - 1:
        added, removed, path = fields[i].split("\t", 2)
        if path:
            i += 1
        else:  # a rename: the old path, then the new one
            path, i = fields[i + 2], i + 3
        name = "generated" if path.rsplit("/", 1)[-1] in LOCKFILES else None
        name = name or next((c for c, globs in classes.items() if any(matches(path, g) for g in globs)), "product")
        row = totals.setdefault(name, [0, 0, 0, 0])
        row[0] += 1
        if added == "-":
            row[3] += 1
        else:
            row[1] += int(added)
            row[2] += int(removed)
    if not totals:
        return ["No files changed against the base."]
    lines = ["| Class | Files | Lines added | Lines removed |", "|---|---:|---:|---:|"]
    for name in [c for c in dict.fromkeys([*classes, "generated", "product"]) if c in totals]:
        files, added, removed, binary = totals[name]
        files = f"{files} ({binary} binary, lines not counted)" if binary else files
        lines.append(f"| {cell(name)} | {files} | {added} | {removed} |")
    proof = [c for c in totals if c not in NOT_PROOF]
    product = totals.get("product", [0, 0])[1]
    proof_added = sum(totals[c][1] for c in proof)
    return lines + [
        "",
        (
            f"Product +{product} lines against proof +{proof_added} lines"
            f" ({cell(', '.join(proof)) or 'no proof classes changed'})."
        ),
        "A file that matches no class counts as product; lockfiles and other generated files, and docs, count as neither.",
        "Proof that outweighs the product it covers needs a reason in review.",
    ]


def seconds(job):
    start, end = (datetime.fromisoformat(job[key].replace("Z", "+00:00")) for key in ("started_at", "completed_at"))
    return (end - start).total_seconds()


def duration(value):
    return f"{int(value // 60)}m {int(value % 60):02d}s"


def runner(job):
    # GitHub-hosted runners get a new name per job, so they compare by label; self-hosted ones by name.
    return ", ".join(job.get("labels") or []) if job.get("runner_group_id") == 0 else job.get("runner_name")


def runtime(config):
    names = config.get("test_jobs") or []
    if not names:
        return ["Not configured: no `test_jobs` in `.github/quality.yml`."]
    repo, run_id, branch = env("GITHUB_REPOSITORY"), env("GITHUB_RUN_ID"), env("EP_DEFAULT_BRANCH")
    if not (env("GITHUB_TOKEN") and repo and run_id and branch):
        return ["Not run: no GitHub Actions context (token, repository, run and default branch)."]
    try:
        jobs = api(f"/repos/{repo}/actions/runs/{run_id}/jobs?per_page=100", keep=POSTING)["jobs"]
        current = {job["name"]: job for job in jobs}
        workflow = api(f"/repos/{repo}/actions/runs/{run_id}", keep=POSTING)["workflow_id"]
        runs = api(
            f"/repos/{repo}/actions/workflows/{workflow}/runs?branch={branch}&event=push&status=completed&per_page=20",
            keep=POSTING,
        )["workflow_runs"]
        history = {name: [] for name in names}
        for run in runs:
            if all(len(past) == SAMPLES for past in history.values()):
                break
            for job in api(f"/repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100", keep=POSTING)["jobs"]:
                mine, past = current.get(job["name"]), history.get(job["name"])
                if (
                    past is not None
                    and mine
                    and len(past) < SAMPLES
                    and job["conclusion"] == "success"
                    and runner(job) == runner(mine)
                ):
                    past.append(seconds(job))
    except BudgetSpent:
        return ["Not run: time budget used up."]
    except Exception as error:  # noqa: BLE001 - an API or data surprise leaves this measure "not run"
        return [f"Not run: could not read job times from the GitHub Actions API ({error!r})."]
    lines = [
        (
            f"This run against the median of the last {SAMPLES} successful `{branch}` runs of this workflow"
            " on the same runner, from the GitHub Actions API."
        ),
        "",
        f"| Job | This run | Median on {branch} | Change |",
        "|---|---:|---:|---:|",
    ]
    for name in names:
        job, past = current.get(name), history[name]
        if not job:
            lines.append(f"| {cell(name)} | not run: no job of that name in this run | | |")
        elif job["status"] != "completed":
            lines.append(f"| {cell(name)} | not run: still running; list it in the quality job's `needs` | | |")
        elif len(past) < MINIMUM:
            where = cell(f"{len(past)} {branch} runs on {runner(job)}")
            lines.append(f"| {cell(name)} | {duration(seconds(job))} | not comparable: {where} | |")
        else:
            now, median = seconds(job), statistics.median(past)
            change = f"{(now - median) / median:+.0%}" if median else "not comparable: median is 0s"
            lines.append(f"| {cell(name)} | {duration(now)} | {duration(median)} ({len(past)} runs) | {change} |")
    return lines


def render():
    config = json.loads(read("config.json") or "null")
    config = config if isinstance(config, dict) else {}
    base = read("merge_base")
    head = git("rev-parse", "--short", "HEAD").stdout.strip()
    against = f"against base `{base[:7]}`" if base else "with no base"
    return "\n".join(
        [
            MARKER,
            "## Quality report",
            "",
            (
                f"`{head}` {against}. Only the dead-code gate fails this check; the rest informs review."
                f" Why each check exists: [PRACTICES.md]({REGISTRY})."
            ),
            "",
            f"### Dead-code gate: {verdict()}",
            "",
            "Dead code on lines this pull request adds. Silence a false positive in `.github/quality.yml`.",
            "",
            *checks(GATE),
            "",
            "### Proof weight",
            "",
            "Lines added and removed per path class, from `git diff --numstat` against the base.",
            "",
            *proof_weight(config, base),
            "",
            "### Measures on added lines",
            "",
            *checks(MEASURES),
            "",
            "### Test runtime",
            "",
            *runtime(config),
        ]
    )


def publish(body):
    """Create or update the one comment carrying MARKER. Returns why it was not posted, or None."""
    repo, number = env("GITHUB_REPOSITORY"), env("EP_PR_NUMBER")
    if not (env("GITHUB_TOKEN") and repo and number):
        return "Not posted as a pull request comment: no pull request context."
    try:
        comments, page = [], 1
        while True:
            batch = api(f"/repos/{repo}/issues/{number}/comments?per_page=100&page={page}")
            comments += batch
            if len(batch) < 100:
                break
            page += 1
        mine = next(
            (c for c in comments if MARKER in (c.get("body") or "") and (c.get("user") or {}).get("login") == AUTHOR),
            None,
        )
        if mine:
            api(f"/repos/{repo}/issues/comments/{mine['id']}", "PATCH", {"body": body})
        else:
            api(f"/repos/{repo}/issues/{number}/comments", "POST", {"body": body})
    except urllib.error.HTTPError as error:
        try:
            message = json.load(error).get("message")
        except Exception:  # noqa: BLE001 - the body is only detail for the note
            message = None
        detail = cell(f"{error.code} {message or error.reason}")
        return f"Not posted as a pull request comment: GitHub answered HTTP {detail}. This summary is the report."
    except BudgetSpent:
        return "Not posted as a pull request comment: time budget used up. This summary is the report."
    except Exception as error:  # noqa: BLE001 - a network or data surprise leaves the summary as the report
        return f"Not posted as a pull request comment: {error!r}. This summary is the report."
    return None


def main():
    try:
        body = render()
    except Exception as error:  # noqa: BLE001 - a report bug must not block a merge
        print(f"::warning::Quality report not rendered: {error!r}")
        return
    note = publish(body)
    summary = body + (f"\n\n> {note}" if note else "")
    if env("GITHUB_STEP_SUMMARY"):
        with open(env("GITHUB_STEP_SUMMARY"), "a") as handle:
            handle.write(summary + "\n")
    print(summary)


if __name__ == "__main__":
    main()
