# Engineering practices

The practices Hugo's agents follow in every repository, what enforces each one, and what that
enforcer costs when it fires wrongly. Agent instructions link this file instead of restating it.
Cite a practice by its ID (for example, "T3") in reviews and pull requests.

**Enforcers**

- **gate**: a check fails the pull request or refuses the merge.
- **report**: the [quality action](README.md) measures it in the Quality report on every pull request.
  Nothing fails; the reviewer must answer it or say why not.
- **review**: a row the independent reviewer checks.
- **instruction**: agent instructions only.

A practice whose only enforcers are review or instruction is listed under [Gaps](#gaps).

## Tests

| ID | Practice | Source | Enforcer | Prevents | Wrong-fire cost | Who pays |
|---|---|---|---|---|---|---|
| T1 | A test names the realistic failure only it catches. No such failure, no test. | [Hugo 10-01]; [Vocke], avoid test duplication | review; report (proof weight) | Tests that add runtime and upkeep but catch nothing another test or check does not | The author states a needed test's failure in one line | Author agent, minutes |
| T2 | Test what someone depends on: user-visible behaviour, auth, tenant isolation, money, stored data, through public interfaces. Not markup bytes, call order or private helpers. | [Hugo 10-01]; [SWE 12], test via public APIs, test state not interactions; [Beck], structure-insensitive; [Vocke], test observable behaviour | review | Tests that break on harmless refactors and miss real regressions | A test of a genuinely tricky internal is questioned; the author says why it earns its place | Author agent, minutes |
| T3 | One case per behaviour that differs. Parametrise only where the code branches. | [Hugo 10-01]; [SWE 12], test behaviours, not methods | review; report (proof weight) | Cases and fixtures multiplied across combinations | A real branch loses its case; the reviewer restores it | Reviewer, minutes |
| T4 | The pyramid: a few end-to-end tests, each driving one whole user workflow through every layer and naming it; integration tests at the boundaries (API, database, auth, tenant); unit and contract tests where logic branches. No ratio is enforced. | [Vocke]; [SWE 11], test sizes; [SWE 14]; [Hugo 10-01] | report (test runtime against main); review (a new end-to-end test names its workflow) | Slow suites built from tests at the wrong level | Runner noise reads as a slowdown; the reviewer checks the median and the run count | Reviewer, minutes |
| T5 | A test exercises real code and asserts something a realistic defect would change. Prefer real implementations to mocks. | [Hugo 10-01]; [SWE 13], prefer realism over isolation | review | Tests that pass whatever the code does | A justified mock (network, clock) is questioned; the author names the reason | Author agent, minutes |
| T6 | DAMP in tests: each test reads on its own; repeat setup rather than hide its meaning in shared helpers. | [SWE 12], DAMP, not DRY; [Beck], readable | instruction; review | Tests whose meaning lives several files away | Duplicate test code appears in the report (C2) and is accepted, not deduplicated | Reviewer, seconds |
| T7 | "Nothing changes" means it works the same: prove a port or refactor by its workflows and data, not by snapshots of its output. | [Hugo 10-01] | review | Byte-for-byte snapshot suites that outweigh the change | A snapshot that pins a real contract (a wire format) is questioned; the author names the contract | Author agent, minutes |
| T8 | Coverage percentages gate nothing. | [Fowler]; [SWE 11], code coverage; [Hugo 10-05] | review (a new threshold is refused) | Tests written to execute lines rather than catch failures | None from the rule; a coverage drop goes unflagged, and T1 to T5 carry the judgement | Nobody |

## Code

| ID | Practice | Source | Enforcer | Prevents | Wrong-fire cost | Who pays |
|---|---|---|---|---|---|---|
| C1 | No new dead code: no unused file, export or dependency (TS/JS), no unreachable function (Go), and no unused import or variable, undefined name or redefinition (Python) on the lines a pull request adds. | [Hugo 10-05] | gate (knip, deadcode, ruff's F rules on added lines); report (vulture for unreferenced Python definitions) | Dead weight that the 2026-10-05 audit removed by the thousand lines | An entry point the tool cannot see (framework file, dynamic dispatch) blocks the PR until an ignore entry lands in `.github/quality.yml`, where review sees it. Editing the declaration line of an export, function or import that was already unused also fails; the remedy is deleting it | Author agent, minutes |
| C2 | DRY of knowledge in product code: one source for each rule, value or vendored file. A second copy needs an import, generator or dependency that keeps it in step, or names the change that deletes it. | [PragProg], DRY is about knowledge; [Hugo 10-01] | report (jscpd duplicate code, exact token clones, on added lines); review | Copies that drift apart | jscpd flags copies that encode different knowledge (boilerplate, DAMP tests); the reviewer dismisses it (see C3, T6) | Reviewer, seconds |
| C3 | Prefer duplication over the wrong abstraction. Do not merge code that merely looks alike; inline an abstraction that has grown a parameter per caller. | [Metz] | review | Shared helpers bent to fit every caller | Real shared knowledge stays duplicated; the test is whether the copies encode the same rule (C2) | Reviewer, minutes |
| C4 | Copying is not a justification, and new code sets the pattern the next change copies. Name an unsound existing pattern and propose a better shape. | [Hugo 10-01] | instruction; gate (C6, for the patterns copied most); audit (`checks.sh audit` lists the old instances a change must not copy) | Unsound patterns spreading by imitation | The author spends minutes on a pattern that was fine, or keeps a closed set with a reason | Author agent, minutes |
| C5 | No new lint findings on the lines a pull request adds: no ESLint error under the repository's own config, no staticcheck finding (Go), no ShellCheck warning or error in a changed shell script. Each linter is turned on per repository in `.github/quality.yml`. | [Hugo 10-06] | gate (ESLint, staticcheck, ShellCheck on added lines) | ESLint: code that breaks the rules the repository's own config sets. staticcheck: Go bugs (ignored errors, impossible conditions, misused standard library calls) and needless complexity. ShellCheck: quoting, word-splitting and portability bugs in the scripts that build, deploy and operate the product | A rule the team disagrees with, or a check that misreads the code, blocks the PR until a disable comment or config entry lands, where review sees it. Editing a line that already had a finding also fails; the remedy is fixing that line. ShellCheck notes and style findings (such as SC2086 quoting) do not count unless `shellcheck.args` lowers the severity | Author agent, minutes |
| C6 | Code does not decide what a person meant with a word list or a word regex, does not read a generated structured language (SQL, HTML, XML) with a regex, and does not fix in code knowledge that is or will become configurable or evolving (stages, statuses, entity or relation types, domain vocabularies). A check of a field's format and a closed machine format are fine. | [Hugo 10-07] | gate (semgrep, `rules/banned-patterns.yml` plus the repository's own rules, on added lines: a set, search or membership test of three or more words whatever the names, a word list over a value named for a person's text, a regex over SQL or markup; and a `nosemgrep` comment without a rule and a reason); audit (`checks.sh audit` lists every old instance); review (each `# nosemgrep: <rule> -- <reason>`) | Word lists that miss phrasings and grow one case at a time, regexes that break when a model's output changes shape, values a customer cannot change without a deploy | A closed set (a grammar's operators, a provider's enum, a format) fails the line that adds it until the author keeps it with a reason that review accepts. On a production Python service, about half of the word sets, one in seven word searches and three in four word membership tests were closed sets | Author agent, minutes; reviewer, seconds per reason |

## Weight and tooling

| ID | Practice | Source | Enforcer | Prevents | Wrong-fire cost | Who pays |
|---|---|---|---|---|---|---|
| W1 | Weight is a finding: report a diff's product lines against its proof (tests, fixtures, evaluation, tooling, scripts, specs). Proof that outweighs the product it covers needs a reason. | [Hugo 10-01] | report (proof weight per path class); review (the reviewer names the failures the extra proof catches, or blocks it) | Proof growing faster than the product it protects | A proof-heavy change that is right (tests for untested auth code) needs a one-line reason | Author agent, minutes |
| W2 | Tooling earns its place: a custom lint, validator, harness or generator needs a problem an off-the-shelf tool or a line of config cannot solve. | [Hugo 10-01] | review | Tooling larger than what it checks | A needed tool is questioned; the author names the off-the-shelf options it beats | Author agent, minutes |
| W3 | Answer a finding by simplifying first: ask whether the mechanism it guards should exist before adding a guard. Deleting a test, harness or control that protects nothing is legitimate work. | [Hugo 10-01]; [Hugo 09-04] | instruction; review | Each finding answered with one more guard | A guard that was needed is removed; review of the deletion catches it | Reviewer, minutes |

## Controls

| ID | Practice | Source | Enforcer | Prevents | Wrong-fire cost | Who pays |
|---|---|---|---|---|---|---|
| K1 | Before adding a gate, refusal, required approval or fail-closed branch, state what it prevents, what it costs when it fires wrongly, and who pays. A control that needs a human names why automation cannot do it. | [Hugo 09-04] | review | Controls whose wrong fires cost more than what they prevent | The author writes three lines for an obvious control | Author agent, minutes |
| K2 | Never gate the internal on the external: a third party's requirement may gate what that party controls, never Hugo's own users, admission or releases. | [Hugo 09-04] | instruction | Releases blocked on another organisation's process | None | Nobody |
| K3 | Fail closed where an unexpected state means something is wrong (parsers, authentication, money, schema validation), not where the environment is eventually consistent (Kubernetes, cloud APIs, network-fetched tools). | [Hugo 09-04] | instruction; review | Outages and normal drift turned into merge or deploy freezes | A real fault passes as drift; monitoring, not the gate, catches it | Hugo, when it surfaces |
| K4 | Size governance to blast radius. Removing a control is legitimate work, argued with the same evidence as adding one. | [Hugo 09-04] | instruction | Controls that only ratchet up | None | Nobody |

## Delivery

| ID | Practice | Source | Enforcer | Prevents | Wrong-fire cost | Who pays |
|---|---|---|---|---|---|---|
| D1 | Every merge has an independent review: a reviewer that did not author the change and reads the Quality report. | [Hugo delivery]; [SWE 9] | gate (the yadm merge guard requires an independent approval note) | Self-reviewed merges | A trivial change waits for a reviewer lane | Orchestrating agent, minutes |
| D2 | Merges wait for the repository's own CI: every GitHub Actions check on the head concluded success, skipped or neutral. Failed and cancelled refuse; pending refuses unless the approval note says `CI unavailable: <reason>`. Other apps' checks are not read. | [Hugo 10-05] | gate (the yadm merge guard) | Merging untested or failing code, as after a cancelled run on 2026-10-05 | A queued run makes an agent wait; with no runner online, the escape line is visible on the PR and counted by the weekly audit | Merging agent, minutes |

## Gaps

These practices have no automated enforcer; they rely on the author and the independent reviewer.

- **Review, with or without an instruction:** T1, T2, T3 (proof weight hints at T1 and T3 but cannot
  judge them), T5, T6, T7, T8, C3, W2, W3, K1, K3.
- **Instruction only:** K2, K4.
- **Partly covered:** C1 does not catch a callee left dead when a pull request removes its caller in another
  file; the monthly gardener sweeps that. For Python the gate covers ruff's F rules only; unreferenced
  definitions are the vulture measure, which a reviewer judges.
- **Partly covered:** C4 is gated only for the patterns C6 names. C6 reads Python only. Its word rules miss
  words held in a dict, a default argument or a prompt string; a chain such as `x == "a" or x == "b"`; a
  verbose-mode or capitalised regex, or one built with `"|".join(...)`; a `for` statement over words; and
  a word list that also holds a key, code, digit or capital. One or two words are found only in a value
  named for a person's text. Review covers the rest.

An automated enforcer for a gap is welcome when it passes K1: what it prevents must outweigh what its
wrong fires cost.

## Changing this registry

A practice and its enforcer change in the same pull request. The `v1` tag moves only after this
repository's CI passes on `main` (see the [README](README.md)).

## Sources

- [Vocke]: Ham Vocke, [The Practical Test Pyramid](https://martinfowler.com/articles/practical-test-pyramid.html),
  martinfowler.com, 2018. Many fast unit tests, fewer integration tests at the boundaries, very few
  end-to-end tests for the journeys that carry the product's value; test observable behaviour, not
  internal structure; push each test as far down the pyramid as it can go and avoid duplicating it at
  higher levels.
- [SWE 9], [SWE 11], [SWE 12], [SWE 13], [SWE 14]: Titus Winters, Tom Manshreck, Hyrum Wright,
  [Software Engineering at Google](https://abseil.io/resources/swe-book), O'Reilly, 2020. Chapters
  [9, Code Review](https://abseil.io/resources/swe-book/html/ch09.html);
  [11, Testing Overview](https://abseil.io/resources/swe-book/html/ch11.html) (test sizes and scope, code coverage);
  [12, Unit Testing](https://abseil.io/resources/swe-book/html/ch12.html) (test via public APIs, test state
  not interactions, test behaviours not methods, DAMP not DRY);
  [13, Test Doubles](https://abseil.io/resources/swe-book/html/ch13.html) (prefer realism over isolation);
  [14, Larger Testing](https://abseil.io/resources/swe-book/html/ch14.html).
- [Beck]: Kent Beck, [Test Desiderata](https://testdesiderata.com/), 2019. The properties good tests trade
  off, among them behavioural (fail when behaviour changes), structure-insensitive (survive refactoring)
  and readable.
- [Metz]: Sandi Metz, [The Wrong Abstraction](https://sandimetz.com/blog/2016/1/20/the-wrong-abstraction), 2016.
  Duplication costs less than an abstraction that no longer fits; when one has grown conditionals per
  caller, inline it and start again.
- [PragProg]: Andrew Hunt and David Thomas,
  [The Pragmatic Programmer, 20th anniversary edition](https://pragprog.com/titles/tpp20/the-pragmatic-programmer-20th-anniversary-edition/),
  2019, topic 9 "DRY: The Evils of Duplication". DRY concerns knowledge and intent, not identical-looking code.
- [Fowler]: Martin Fowler, [TestCoverage](https://martinfowler.com/bliki/TestCoverage.html), 2012. Coverage
  helps find untested code; as a numeric target it says little about how good the tests are.
- [Hugo 10-01]: Hugo's engineering rules, 2026-10-01, "Tests and tooling must justify themselves".
- [Hugo 09-04]: Hugo's engineering rules, 2026-09-04, "Controls must justify themselves".
- [Hugo 10-07]: Hugo's ruling, 2026-10-07, after two reviewed changes copied word lists and regexes over SQL and
  HTML: ban them or restrain them hard. Context decides: a format check or a closed machine format is fine.
- [Hugo 10-05]: Hugo's ruling, 2026-10-05, after the audit of every repository: dead-code gate, no coverage
  gates, merges wait for their own CI.
- [Hugo 10-06]: Hugo's approval, 2026-10-06, of automatic checks across all repositories: linters on added lines join the gate.
- [Hugo delivery]: Hugo's delivery rules: author-independent review during implementation and before merge.
