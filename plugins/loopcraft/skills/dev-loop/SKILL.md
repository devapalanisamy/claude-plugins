---
name: dev-loop
description: Implement a change and autonomously loop implement → verify (unit/integration/e2e) → code-review → fix until an independent review is clean. Project-agnostic — detects the stack and test commands from the repo. Use when the user asks to implement/fix something and wants it driven to a verified, review-clean state without babysitting.
---

Run the full autonomous dev loop for the task below. Do NOT pause for user input between steps or rounds — the user only reads the final report. The only exceptions where you may stop and ask: a needed credential/login the environment can't provide (ask the user to run it via the `!` prefix), an action that would touch a shared/production environment without permission, or a genuine scope decision only the user can make.

**Missing credentials are NEVER a reason to skip e2e.** If the e2e/integration layer needs a login, a sandbox, or a test user you don't have, STOP and ask the developer to provide it via the `!` prefix, then stand up the project's local/sandbox environment, create the required test user, seed any data the flow needs, and run the suite. Reporting e2e as "skipped — credential-blocked" is not allowed; pause for the login instead.

## Arguments

$ARGUMENTS

Parse from the arguments:
- The task description (everything that is not a flag).
- `--effort <low|medium|high|max>` — code-review effort level. Default: `high`.
- `--max-loops <N>` — maximum review/fix rounds. Default: `3`.

## Step 0 — Orient to THIS repo (do this first)

Before any work, learn the project's own rules and tooling — do not assume:
- Read `CLAUDE.md` / `AGENTS.md` / `.cursorrules` / `README` and any contributing guide. **Project conventions override this skill** wherever they conflict.
- Detect the stack and the real test/lint commands from the repo, e.g. `package.json` scripts, `Makefile`, `Justfile`, `pyproject.toml`, `pubspec.yaml`, `go.mod`, `Cargo.toml`, CI config (`.github/workflows`, etc.). Use what the project actually defines; never invent command names.
- Note any environment/safety rules (which branches/envs are off-limits, how to run a local/sandbox env, how to get test credentials).

## Loop protocol

### Step 1 — Implement
TDD, non-negotiable, at EVERY layer the change touches — unit, integration, and end-to-end: write the failing test(s) first (a new/changed user-facing flow gets a failing e2e/integration test first, not unit tests alone), run them to confirm they fail for the right reason, then write the minimum code to pass, then refactor. Bug fixes reproduce with a failing test before patching.

If the environment provides a specialized implementation skill/agent that matches the work (e.g. a framework- or language-specific skill), route through it, passing the task description. Otherwise implement directly. Either way: minimum code that solves the problem, touch only what you must, and follow the repo's own style (comment density, naming, structure).

### Step 2 — Verify (runs EVERY round, after implementation and after every fix round)
For each touched component, run the project's automated suites at ALL applicable layers and confirm they pass:
- **Unit / component** tests for the touched files.
- **Integration** tests (against a local/sandbox environment — never a shared/production one).
- **Lint / typecheck / format** as the project defines them.
- Any project-specific validation for the kind of file you changed (schemas, migrations, generated code, IaC, etc.).

Then **live end-to-end verification of the changed behaviour**, using whatever surface the change has:
- UI change → build/launch the app locally (or on a simulator/device for mobile) and exercise the changed flow yourself via the available automation (browser/mobile MCP tools), capturing evidence (screenshots/output).
- Backend/service/CLI with no UI → exercise via local/sandbox API calls, direct invocation, or the CLI itself.
- **e2e is never skipped for missing credentials** — pause for the login (`!` prefix), provision the test user/data, then run it. The only legitimate e2e skips are a non-deterministic external dependency (e.g. live LLM output) or a change with no user-facing/integration surface; record either explicitly.
- For any other e2e check that genuinely cannot be run safely, do NOT silently skip it — record exactly what was skipped and why for the final report.

Any failure found here: fix it (failing test first for bug-class failures), then re-run this step from the top before proceeding.

### Step 3 — Review
Invoke a code-review skill/agent if the environment provides one, at the chosen effort level (default `high`). If none is available, spawn a fresh reviewer subagent (Agent tool, general-purpose) that sees only the diff + acceptance criteria and reports concrete findings. Do not use a paid/billed "deep" review tier unless the user explicitly asks.

### Step 4 — Act on findings
- For each valid finding: apply the fix. Bug-class findings get a failing test first. Route substantial rework through the same path as Step 1; trivial fixes may be applied directly.
- You may NOT unilaterally reject a finding about code you wrote. If you believe a finding is invalid, spawn a fresh reviewer subagent (Agent tool, general-purpose) whose prompt contains only: the finding, the relevant code/diff excerpt, and your counter-argument. That subagent's verdict is final: if it upholds the finding, fix it; if it agrees it is invalid, record the finding, your reasoning, and the adjudicator's verdict for the report.
- If any code changed, return to Step 2.

### Step 5 — Final independent review (fresh, independent context)
Once Step 3 returns no findings (or every remaining finding was adjudicated invalid), run ONE review in a fresh context that never saw the implementation reasoning. Pick the mechanism by what's available:

1. Collect the full change set: `git diff HEAD` plus the full content of any untracked new files (`git status --porcelain` to find them).
2. Check whether the `claude` CLI is on PATH (e.g. `command -v claude`).
   - **If available — headless session (preferred):** pipe the change set to a new session: `git diff HEAD | claude -p "Review this diff for correctness bugs, security issues, and anything blocking merge. The repo is at <repo root>; read surrounding files for context if needed. Reply with a numbered list of concrete findings, or exactly CLEAN if none." --allowedTools "Read,Grep,Glob"` (append untracked-file contents to the piped input).
   - **If NOT available — in-session fresh subagent (fallback):** spawn a fresh reviewer via the Agent tool (`general-purpose`) whose prompt contains ONLY the change set (diff + untracked-file contents), the repo root path, and the same instruction (find concrete correctness/security/merge-blocking issues; reply with a numbered list or exactly CLEAN). It gets none of your implementation reasoning, so it reviews independently.
3. If the chosen reviewer replies CLEAN: the loop is done.
4. If it returns findings: treat them exactly like Step 3 findings (Step 4 rules apply) and return to Step 2. This counts as a new round against `--max-loops`.

### Step 6 — Terminate
Stop looping when the final independent review replies CLEAN (success), or the loop cap (`--max-loops`) is reached with findings still open (report them as open).

NEVER `git commit`, create branches, or open PRs unless the user explicitly asks — leave all changes uncommitted in the working tree. When the user DOES ask you to commit, never bypass pre-commit hooks (`--no-verify`/`-n` or any hook skip); if a hook fails, fix the underlying cause and re-commit.

## Final report (the only output the user reads)
- What was implemented, with the key files changed.
- Every verification command run, with exact pass/fail counts per round, broken out by layer (unit, integration, e2e) for each touched component.
- E2e evidence: what was exercised and what was observed (reference screenshots/output).
- Review rounds: findings raised, fixed, and adjudicated invalid (with your reasoning AND the adjudicator's verdict).
- The final independent review's verdict (CLEAN, or its findings and how they were resolved).
- Anything skipped, with the reason — never claim "verified" for a skipped check.
- If the loop cap was hit: the remaining open findings, clearly listed.
