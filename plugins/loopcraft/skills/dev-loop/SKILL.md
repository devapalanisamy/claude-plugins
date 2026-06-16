---
name: dev-loop
description: Implement a change interactively (with live e2e + the ability to pause for a login), then hand the diff to a deterministic Workflow that runs review → adjudicate → fix → re-verify with fresh independent reviewers until it's clean. Project-agnostic. Use when the user asks to implement/fix something and wants it driven to a verified, review-clean state without babysitting.
---

You are the **driver**. You personally do the interactive work — orient, implement, and *live* verification (running the app/simulator/browser, pausing for a login if needed) — because a background Workflow cannot pause to ask the user or be watched while it drives a UI. You then hand the change set to a **Workflow** that runs the deterministic review/fix loop with fresh, independent reviewers, and you re-verify its output live. This split keeps the e2e guarantees intact while making the review loop deterministic.

## Arguments

$ARGUMENTS

Parse: the task description (everything that is not a flag); `--effort <low|medium|high|max>` (review depth, default `high`); `--max-loops <N>` (max workflow rounds, default `3`).

## Step 0 — Orient to THIS repo
Read `CLAUDE.md` / `AGENTS.md` / `README` and any contributing guide — **project conventions override this skill.** Detect the real test/lint commands from `package.json` scripts, `Makefile`, `pyproject.toml`, `pubspec.yaml`, CI config, etc. Note env/safety rules (off-limits branches/envs, how to run a local/sandbox env, how to get test credentials). **Record the exact automated test + lint commands you find — you will pass them to the Workflow in Step 3.**

**Optional deterministic lint gate (recommended):** loopcraft ships a `PostToolUse` hook that, *only* if the repo root contains a `.loopcraft.json` with a `lintCommand`, runs that lint after every edit and blocks (returns the errors to fix) on failure — a harness-enforced gate that doesn't depend on the model remembering to lint. To enable it in this repo, drop a `.loopcraft.json` like `{ "lintCommand": "<fast lint of changed files>" }` (keep it fast — it runs on every edit). If the file is absent the hook is a no-op, so it never disrupts other repos.

## Step 1 — Implement (you, interactively)
TDD, non-negotiable, at EVERY layer the change touches (unit/integration/e2e): failing test first (a new/changed user-facing flow gets a failing e2e/integration test first, not unit alone), confirm it fails for the right reason, minimum code to pass, refactor. Bug fixes reproduce with a failing test before patching. If a matching specialized implementation skill/agent exists, route through it; else implement directly. Minimum code, touch only what you must, follow the repo's own style.

## Step 2 — Live verify (you, interactively — the part a background Workflow cannot do)
- Run the project's automated suites at all applicable layers (unit/integration) and lint/typecheck. Fix failures (failing test first for bug-class) before continuing.
- **Live e2e of the changed behaviour:** UI → launch the app (simulator/device for mobile, browser for web) and exercise the changed flow yourself via the available MCP automation, capturing evidence. Backend/CLI → exercise via local/sandbox API calls or direct invocation.
- **e2e is never skipped for missing credentials:** if it needs a login/sandbox/test user you lack, STOP and ask the developer to provide it via the `!` prefix, then provision the test user/data and run it. Legitimate skips only: non-deterministic external dependency, or no user-facing/integration surface — record either explicitly. Never touch a shared/production environment without permission.

## Step 3 — Harden via Workflow (deterministic review → adjudicate → fix → re-verify)
Launch the `Workflow` below (inline `script`), passing `args` as a JSON object:
```json
{ "criteria": "<the task + what 'done' looks like>", "verifyCommands": ["<exact test cmd>", "<exact lint cmd>"], "maxRounds": 3, "effort": "high", "adjudicators": 2, "crossModel": "fable" }
```
Use the commands you recorded in Step 0 for `verifyCommands`. `adjudicators` (default 2) is how many independent votes each finding gets before it's accepted — a finding is kept only if a strict majority of votes call it real, which filters false positives. `crossModel` (default `"fable"`) runs one reviewer lens and every other adjudication vote on a **different model family**, so the panel isn't pure same-model self-critique; set it to `""` to disable, or `"sonnet"`/`"opus"` if Fable is unavailable. The Workflow runs in the **background**; wait for the completion notification (don't poll). Its reviewers and fixer run as fresh sessions and edit the working tree while you wait — so do not edit files yourself until it returns.

> Scope note the Workflow honours: it runs **automated** tests/lint only. It does NOT do live UI e2e or anything needing an interactive login — that stays yours (Steps 2 and 4).

### Workflow script
```javascript
export const meta = {
  name: 'dev-loop-harden',
  description: 'Fresh-reviewer review -> consensus + cross-model adjudication -> fix -> re-verify loop over a working-tree diff',
  phases: [
    { title: 'Review', detail: 'fresh independent reviewers on the diff' },
    { title: 'Verify', detail: 'adjudicate findings + run automated tests/lint' },
    { title: 'Fix', detail: 'apply confirmed findings + failing checks' },
  ],
}

const A = typeof args === 'string' ? JSON.parse(args) : args || {}
const maxRounds = A.maxRounds || 3
const effort = A.effort || 'high'
const criteria = (A.criteria || '').trim()
const verifyCommands = Array.isArray(A.verifyCommands) ? A.verifyCommands : []
const adjudicators = A.adjudicators || 2
// Cross-model reviewer to escape shared-model bias (same-model panels are self-critique, not
// independent verification). Default to a different family (Fable); set crossModel:'' to disable,
// or to 'sonnet'/'opus' if Fable is unavailable. (Cross-VENDOR review, e.g. GPT/Codex, is not
// reachable from a workflow — wire it as an external reviewer if you need it.)
const CROSS_MODEL = 'crossModel' in A ? A.crossModel : 'fable'

const DIFF_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['diff'],
  properties: { diff: { type: 'string', description: 'git diff HEAD plus full contents of untracked files' } },
}
const REVIEW_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['findings', 'summary'],
  properties: {
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['severity', 'area', 'file', 'problem', 'suggested_fix'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          area: { type: 'string' }, file: { type: 'string' },
          problem: { type: 'string' }, suggested_fix: { type: 'string' },
        },
      },
    },
  },
}
const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['real', 'reason'],
  properties: { real: { type: 'boolean' }, reason: { type: 'string' } },
}
const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['passed', 'summary', 'failures'],
  properties: { passed: { type: 'boolean' }, summary: { type: 'string' }, failures: { type: 'array', items: { type: 'string' } } },
}

const LENSES = [
  { key: 'correctness', focus: 'CORRECTNESS & BUGS — logic errors, wrong edge-case handling, off-by-one, null/undefined, race conditions, broken contracts, regressions vs the code being changed.' },
  { key: 'security', focus: 'SECURITY & DATA — injection, missing authz/authn, unsafe deserialization, secret/PII leakage, unvalidated input, unsafe defaults.' },
  { key: 'tests', focus: 'TESTS & COVERAGE — was the change made TDD (failing test first)? Are the new/changed paths actually covered at the right layer? Are tests meaningful (not asserting trivia / not over-mocked)? Flag missing integration/e2e coverage for user-facing changes.' },
  { key: 'simplicity', focus: 'SIMPLICITY, REUSE & CONVENTIONS — duplication, dead code, needless complexity, ignoring an existing helper, and violations of the repo conventions (read CLAUDE.md/AGENTS.md). Flag comments that state WHAT instead of WHY if the repo forbids them.' },
]

function effortNote(e) {
  if (e === 'low' || e === 'medium') return 'Report only HIGH-CONFIDENCE blocker/major issues; skip speculative nitpicks.'
  return 'Be thorough; surface uncertain issues as major/minor and let adjudication filter them.'
}

const COLLECT_PROMPT = [
  'Output the current working-tree change set with NO commentary.',
  'Run `git diff HEAD`. Then run `git status --porcelain` and for each untracked (??) file, append a section with its path and full contents.',
  'Return it all in the `diff` field.',
].join('\n')

function reviewPrompt(lens, diff) {
  return [
    'You are an independent reviewer of a code change. You did NOT write it. Be skeptical but fair: a blocker means the change is wrong/unsafe/broken; a major is a significant concrete gap; minor is nice-to-have.',
    effortNote(effort),
    `Your lens: ${lens.focus}`,
    criteria ? `What the change is supposed to do: ${criteria}` : '',
    'Read the diff below; open surrounding files in the repo as needed to judge correctly. Report ONLY issues in your lens, each with severity, area, file, the concrete problem, and a specific suggested fix.',
    '', '--- CHANGE SET (diff + untracked files) ---', diff,
  ].join('\n')
}

function adjudicatePrompt(f, diff) {
  return [
    'You are an adversarial adjudicator. A reviewer raised the finding below on a code change. Decide if it is REAL (genuinely worth fixing) or a false positive. Default to real=false if you cannot substantiate it from the actual code.',
    'Investigate the repo as needed to confirm. Set real=true only if the problem genuinely holds and matters.',
    `Finding: [${f.severity}] (${f.area}) ${f.file} — ${f.problem}`,
    `Suggested fix: ${f.suggested_fix}`,
    '', '--- CHANGE SET ---', diff,
  ].join('\n')
}

function fixPrompt(problems) {
  const list = problems.map((p, i) => `${i + 1}. [${p.severity}] (${p.area}) ${p.file} — ${p.problem}\n   Suggested fix: ${p.suggested_fix}`).join('\n')
  return [
    'Apply fixes to the working tree for the confirmed problems below. Follow the repo conventions (read CLAUDE.md/AGENTS.md first). TDD for bug-class problems: add/repair a failing test first, then fix. Keep changes minimal; do not rewrite unrelated code. Do not git commit.',
    'After editing, briefly state what you changed.',
    '', '--- CONFIRMED PROBLEMS ---', list,
  ].join('\n')
}

function verifyPrompt() {
  const cmds = verifyCommands.length
    ? `Run EXACTLY these commands from the repo root and report results:\n${verifyCommands.map((c) => `- ${c}`).join('\n')}`
    : 'Detect the project test and lint commands (package.json scripts, Makefile, pyproject, pubspec, etc.) and run them from the repo root.'
  return [
    'You run the project\'s AUTOMATED checks only (unit/integration tests, lint, typecheck). Do NOT attempt live UI e2e or anything needing an interactive login.',
    cmds,
    'Set passed=true only if every command exits successfully. On failure, put concise failure excerpts in `failures`.',
  ].join('\n')
}

function voteThunks(f, diff) {
  const thunks = []
  for (let i = 0; i < adjudicators; i += 1) {
    const opts = { schema: VERDICT_SCHEMA, phase: 'Verify', label: 'adjudicate' }
    if (i % 2 === 1 && CROSS_MODEL) opts.model = CROSS_MODEL
    thunks.push(() => agent(adjudicatePrompt(f, diff), opts))
  }
  return thunks
}

let stopReason = 'reached round cap with problems still open'
let roundsRun = 0
const changelog = []
const openMinor = []
const seenMinor = {}

for (let round = 1; round <= maxRounds; round += 1) {
  roundsRun = round
  const ctx = await agent(COLLECT_PROMPT, { schema: DIFF_SCHEMA, phase: 'Review', label: 'collect-diff' })
  const diff = (ctx && ctx.diff ? ctx.diff : '').trim()
  if (!diff) { stopReason = 'no changes in working tree to review'; break }

  const reviews = (
    await parallel(LENSES.map((l) => () => {
      const opts = { schema: REVIEW_SCHEMA, phase: 'Review', label: `review:${l.key}` }
      if (l.key === 'simplicity' && CROSS_MODEL) opts.model = CROSS_MODEL
      return agent(reviewPrompt(l, diff), opts)
    }))
  ).filter((r) => !!r)
  const allFindings = reviews.flatMap((r) => r.findings || [])
  const candidate = allFindings.filter((f) => f.severity === 'blocker' || f.severity === 'major')
  allFindings.filter((f) => f.severity === 'minor').forEach((m) => {
    const k = `${m.file}|${m.problem}`.toLowerCase().slice(0, 160)
    if (!seenMinor[k]) { seenMinor[k] = true; openMinor.push({ round, ...m }) }
  })

  const judged = await parallel(candidate.map((f) => () =>
    parallel(voteThunks(f, diff)).then((votes) => {
      const realVotes = votes.filter((v) => v && v.real).length
      return { f, keep: realVotes * 2 >= adjudicators }
    })))
  const confirmed = judged.filter((x) => x && x.keep).map((x) => x.f)

  const v = await agent(verifyPrompt(), { schema: VERIFY_SCHEMA, phase: 'Verify', label: `verify:round${round}` })
  const verifyOk = !!(v && v.passed)

  log(`Round ${round}: ${confirmed.length} confirmed finding(s) (of ${candidate.length} raised), automated checks ${verifyOk ? 'PASS' : 'FAIL'}`)

  if (confirmed.length === 0 && verifyOk) {
    stopReason = 'clean: fresh independent review found nothing and automated checks pass'
    changelog.push({ round, action: 'clean' })
    break
  }

  const problems = confirmed.slice()
  if (!verifyOk) {
    problems.push({
      severity: 'blocker', area: 'failing automated checks', file: '',
      problem: `Automated tests/lint failed: ${(v && v.failures ? v.failures : []).join('; ').slice(0, 800)}`,
      suggested_fix: 'Make all automated test/lint commands pass (failing test first for any bug-class failure).',
    })
  }
  await agent(fixPrompt(problems), { phase: 'Fix', label: `fix:round${round}` })
  changelog.push({
    round, action: 'fixed', confirmedFindings: confirmed.length, verifyBefore: verifyOk ? 'pass' : 'fail',
    addressed: problems.map((p) => `[${p.severity}] ${p.area}: ${p.problem}`.slice(0, 200)),
  })
}

return { stopReason, roundsRun, changelog, openMinorFindings: openMinor }
```

## Step 4 — Re-verify live (you, interactively)
When the Workflow returns: if it changed any files (`git status` / its changelog), **re-run your Step 2 live e2e on the final state** — the Workflow re-ran automated tests, but live UI/login-required e2e is yours and the fixer's edits may have altered behaviour. Fix any live failure (failing test first); if the live failure is substantial, re-launch the Step 3 Workflow on the new diff.

If the Workflow's `stopReason` was the cap (problems still open) or `openMinorFindings` remain, decide what to address vs. report.

## Step 5 — Terminate & report
Stop when the Workflow reports clean AND your live e2e passes, or the loop cap is hit (report open items). NEVER `git commit`, branch, or open a PR unless the user explicitly asks; leave changes uncommitted. If asked to commit, never bypass pre-commit hooks — fix the cause and re-commit.

**Final report (the only output the user reads):** what was implemented + key files; every verification command run with pass/fail per layer (incl. your live e2e evidence/screenshots); the Workflow's per-round changelog (`confirmed` findings fixed, automated-check status); the final clean/cap status; anything skipped and why; and any remaining open findings.
