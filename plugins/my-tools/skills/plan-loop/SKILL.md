---
name: plan-loop
description: Hybrid plan builder — clarify scope, generate divergent plans + judge-synthesize, then loop [verify-against-code + review → fix] until claims check out and reviews are clean, then write it and present for approval. Use when the user asks to plan / analyse / design an implementation and wants it hardened against gaps and factual errors.
---

You are the **orchestrator** for a hybrid plan-hardening loop. You do NOT plan, review, verify, or fix anything yourself — your jobs are (1) run the cheap clarification gate, (2) launch the Workflow, (3) handle its result. Everything substantive happens in **separate fresh sessions**.

This skill hardens a plan in four stages, each targeting a common failure of naive planning:
- **Clarification gate** (this file, before launch) — confirms scope with you first, so the loop can't spend 15+ min hardening a wrong-scope plan because the planner guessed the topic.
- **Divergent generation + judge** — generates N plans from different framings and synthesizes the best, exploring the approach space rather than polishing a single first draft.
- **Code-grounded verification stage** — an agent **proves or refutes each factual claim against the actual code** (`file:line` evidence); a refuted claim is a blocker. This is the core of the loop: "clean" means a reviewer found nothing AND no claim contradicts the code, not merely that a reviewer stopped objecting.
- **Honest stop signal** — stops on *verification-backed* clean reviews, with a churn guard that stops when the fixer's edits shrink to noise (diminishing returns) instead of pretending it converged.

## Arguments

$ARGUMENTS

Parse from the arguments:
- **request** — everything that is not a flag. Plan text, a path to an existing plan file (read it and pass its contents), or a "plan X for me" request. Required, non-empty.
- `--planners <N>` — divergent planners in the generation phase. Default `3` (MVP-first, risk-first, alternative-architecture framings). `1` skips divergence (single planner, no judge).
- `--rounds <N>` — max verify→review→fix cycles. Default `3` (kept low because quality is front-loaded by divergence + judge; raise it for large/complex plans). Cap, not floor.
- `--stop-after-clean <K>` — finalize after K consecutive rounds with zero refuted claims and zero blocker/major review findings. Default `2`.
- `--reviewers <M>` — reviewer panel size per round. Default `1` (combined lens). `3` splits into completeness/correctness/risk.
- `--no-clarify` — skip the clarification gate (use when scope is already precise or you're scripting it).
- `--out <path>` — final plan location. Default `.claude/plans/<slug>.md`.

If **request** is empty, ask what to plan and stop.

## Step 0 — Clarification gate (skip if `--no-clarify`)

Before launching anything expensive: read the request. If it is already precise and unambiguous (e.g. it points at a specific file/feature with a clear goal), skip straight to Step 1 and note that you did.

Otherwise, ground a quick interpretation (a brief `Explore` agent is fine if you need to confirm what subsystem this touches), then call `AskUserQuestion` with **2–3 scoping questions** that would change the plan's direction — e.g. the target platform/surface, the in-scope vs out-of-scope boundary, or a fork in approach. Recommend a default option for each. Fold the user's answers into a single sharpened **request** string (state the interpretation explicitly at the top of it), and pass that to the Workflow. This is the cheap insurance against hardening the wrong plan.

## Step 1 — Launch the Workflow

Call `Workflow` with the script below in the **`script`** parameter (inline, not `scriptPath`), and the parsed/clarified arguments in **`args`** as an actual JSON object:

```json
{ "request": "<the clarified request text>", "planners": 3, "maxRounds": 3, "stopAfterClean": 2, "reviewers": 1 }
```

Omit `out` from args — you write the file in Step 2. Runs in the **background**; you're notified on completion. Do not poll.

### Workflow script

```javascript
export const meta = {
  name: 'plan-loop',
  description: 'Divergent planners -> judge -> loop[verify-against-code + review -> fix] with verification-backed early stop',
  phases: [
    { title: 'Plan', detail: 'N divergent planners (different framings)' },
    { title: 'Judge', detail: 'synthesize the best single plan' },
    { title: 'Verify', detail: 'prove/refute each factual claim against the code' },
    { title: 'Review', detail: 'reviewer panel per round' },
    { title: 'Fix', detail: 'correct refuted claims + address findings' },
  ],
}

const A = typeof args === 'string' ? JSON.parse(args) : args || {}
const plannerCount = A.planners || 3
const maxRounds = A.maxRounds || 3
const stopAfterClean = A.stopAfterClean || 2
const reviewerCount = A.reviewers || 1
const request = (A.request || '').trim()
if (!request) {
  throw new Error('plan-loop: empty request — aborting so no agent can guess a target.')
}

const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['plan_markdown'],
  properties: { plan_markdown: { type: 'string', description: 'The full plan as markdown' } },
}

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['verdict', 'findings', 'summary'],
  properties: {
    verdict: { type: 'string', enum: ['clean', 'has_findings'] },
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'area', 'problem', 'suggested_fix'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          area: { type: 'string' },
          problem: { type: 'string' },
          suggested_fix: { type: 'string' },
        },
      },
    },
  },
}

const VERIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['claims', 'summary'],
  properties: {
    summary: { type: 'string' },
    claims: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['claim', 'verdict', 'evidence', 'correction'],
        properties: {
          claim: { type: 'string' },
          verdict: { type: 'string', enum: ['confirmed', 'refuted', 'unverifiable'] },
          evidence: { type: 'string', description: 'file:line or command output proving the verdict' },
          correction: { type: 'string', description: 'the correct fact if refuted, else empty string' },
        },
      },
    },
  },
}

const FRAMINGS = [
  { key: 'mvp', angle: 'Bias to the SMALLEST shippable slice: minimize scope and risk, defer everything non-essential, get a working end-to-end path the fastest.' },
  { key: 'robust', angle: 'Bias to RISK and CORRECTNESS first: enumerate the hard constraints, auth/security/edge cases and failure modes up front, and design so they cannot bite later.' },
  { key: 'alt-arch', angle: 'Explore the ARCHITECTURE space: lay out 2-3 genuinely distinct technical approaches with their tradeoffs, then recommend one with justification — do not assume the obvious approach is best.' },
]

function planners(n) {
  if (n <= 1) return [{ key: 'single', angle: 'Produce the single best implementation-ready plan you can.' }]
  const out = []
  for (let i = 0; i < n; i += 1) out.push(FRAMINGS[i % FRAMINGS.length])
  return out
}

const COMBINED_LENS = {
  key: 'all',
  focus:
    'Cover ALL FOUR before returning: (1) COMPLETENESS & GAPS — missing steps, undefined success criteria, vague hand-waving, unstated dependencies/assumptions. (2) TECHNICAL CORRECTNESS & FEASIBILITY — claims that contradict the codebase, infeasible steps, contract mistakes, steps that would not achieve the goal. (3) RISK, EDGE CASES & SEQUENCING — ordering problems, irreversible actions without safeguards, missing rollback/verification, security/data concerns, edge cases. (4) TESTABILITY & E2E — whether the plan specifies tests at every layer (unit/integration/e2e) and, crucially, HOW the e2e/integration tests obtain credentials and test data (creating temporary test users, a sandbox, seed data, secrets); a missing or hand-wavy e2e/credential-provisioning plan is a major gap.',
}
const LENSES = [
  { key: 'completeness', focus: 'COMPLETENESS & GAPS. Missing steps, unhandled cases, undefined success criteria, vague hand-waving, unstated dependencies/assumptions, anything an implementer would still have to guess. Also treat a missing or vague TESTING plan as a major gap — it must cover unit/integration/e2e and especially HOW e2e/integration credentials and test data are provisioned (temporary test users, sandbox, seed data, secrets).' },
  { key: 'correctness', focus: 'TECHNICAL CORRECTNESS & FEASIBILITY. Verify claims against the actual codebase: wrong assumptions, infeasible steps, API/schema/contract mistakes, steps that would not achieve the goal.' },
  { key: 'risk', focus: 'RISK, EDGE CASES & SEQUENCING. Ordering problems, irreversible actions without safeguards, missing rollback/verification, security/data concerns, edge cases that break the happy path.' },
]
function panel(n) {
  if (n <= 1) return [COMBINED_LENS]
  const out = []
  for (let i = 0; i < n; i += 1) out.push(LENSES[i % LENSES.length])
  return out
}

function planPrompt(framing) {
  return [
    'Produce a thorough, implementation-ready plan for the request below.',
    'Explore and research the codebase first — ground every step in how this repo actually works, citing file:line for load-bearing facts. Define clear success criteria. Do NOT implement; output only the plan.',
    'The plan MUST include an explicit TESTING section covering every layer the change touches (unit, integration, end-to-end). For the integration/e2e layer, specify the exact test data and CREDENTIALS the tests need and HOW to provision them — standing up a personal sandbox, creating temporary/throwaway test users (e.g. Cognito test users), seeding the data the flow needs, and which secrets/env vars are required — so an implementer can actually run e2e without being blocked. If a credential or test user is needed, say how to CREATE it; never assume it already exists. Missing credentials never justify skipping e2e.',
    `Framing for THIS plan: ${framing.angle}`,
    'Return the plan as well-structured markdown.',
    '', '--- REQUEST ---', request,
  ].join('\n')
}

function judgePrompt(candidates) {
  const blocks = candidates.map((p, i) => `\n===== CANDIDATE PLAN ${i + 1} =====\n${p}`).join('\n')
  return [
    'You are synthesizing the SINGLE best implementation-ready plan from the candidate plans below, which were written from different framings.',
    'Take the strongest base and graft the best grounded ideas from the others. Where candidates contradict each other on a fact about the codebase, resolve it by checking the actual code (cite file:line). Drop ideas that are weak or unverifiable.',
    'The synthesized plan MUST retain an explicit TESTING section covering unit + integration + e2e, including how the e2e/integration tests provision credentials and test data (creating temporary test users, a sandbox, seed data, required secrets). If candidates differ here, keep the most concrete version.',
    'Define clear success criteria. Do NOT implement. Return ONE complete plan as markdown.',
    '', '--- REQUEST ---', request, blocks,
  ].join('\n')
}

function verifyPrompt(plan) {
  return [
    'You are a FACT-CHECKER for a plan (not a reviewer of style). Extract the load-bearing factual claims the plan makes about THIS codebase — file paths, line numbers, function/field/table names, IAM grants, schema shapes, config values, and especially negative claims ("X does not exist", "Y has no access to Z"). Focus on the ~15 claims the plan\'s correctness most depends on; skip trivia.',
    'For EACH claim, verify it by actually reading the referenced code (open the file, grep, check the resource). Return verdict confirmed | refuted | unverifiable, with concrete evidence (file:line or what you found). If refuted, put the CORRECT fact in `correction`. Be strict: if you cannot find supporting evidence, it is not "confirmed".',
    '', '--- PLAN ---', plan,
  ].join('\n')
}

function priorBlock(prior) {
  if (!prior || !prior.length) return 'None — this is the first review of the plan.'
  return prior.map((f, i) => `${i + 1}. [${f.severity}] (${f.area}) ${f.problem}`).join('\n')
}

function reviewPrompt(lens, plan, prior, confirming) {
  return [
    'You are reviewing a PLAN (not code). Be skeptical but FAIR. Hold a CONSISTENT bar across rounds: do not escalate stylistic nitpicks to blocker/major. A blocker means the plan genuinely fails without the fix; a major is a significant, concrete gap.',
    confirming
      ? 'CONFIRMATION PASS: a prior reviewer already passed this plan as CLEAN. Raise an issue ONLY if it is a genuine blocker/major that would actually cause the plan to fail. Do NOT introduce new preferences or reworded already-handled points. If the plan is sound, return "clean".'
      : '',
    'Read the plan, then investigate the codebase as needed. (A separate fact-checker is verifying factual claims in parallel — focus your effort on logic, completeness, sequencing, and feasibility rather than re-checking every file:line.)',
    `Your review lens: ${lens.focus}`,
    '',
    'Issues raised in the PREVIOUS round (the plan was then revised to address them):',
    priorBlock(prior),
    'Re-raise a previous issue ONLY if still unresolved; do not reword resolved issues as new. Otherwise report only genuinely NEW blocker/major problems.',
    '',
    'Severity: blocker = plan fails without it; major = significant gap; minor = nice-to-have. Report ONLY issues in your lens, each with severity, area, concrete problem, specific suggested fix. No blocker/major issues -> verdict "clean".',
    '', '--- PLAN ---', plan,
  ].join('\n')
}

function fixPrompt(plan, findings) {
  const list = findings
    .map((f, i) => `${i + 1}. [${f.severity}] (${f.area}) ${f.problem}\n   Suggested fix: ${f.suggested_fix}`)
    .join('\n')
  return [
    'You are improving a PLAN (not implementing it). Below is the current plan and findings. The findings include FACTUAL CORRECTIONS (refuted claims with the correct fact and evidence) — those are mandatory: fix the plan to state the verified-correct fact.',
    'Address every blocker and major finding, and minor ones where cheap. Keep what already works — do NOT drop existing detail or rewrite wholesale. Preserve file:line citations that were confirmed.',
    'Return the COMPLETE updated plan as markdown.',
    '', '--- CURRENT PLAN ---', plan, '', '--- FINDINGS ---', list,
  ].join('\n')
}

function refutedToFindings(verifyRes) {
  if (!verifyRes || !verifyRes.claims) return []
  return verifyRes.claims
    .filter((c) => c.verdict === 'refuted')
    .map((c) => ({
      severity: 'blocker',
      area: 'factual accuracy (verified against code)',
      problem: `Plan claims: "${c.claim}" — REFUTED. ${c.correction ? 'Correct: ' + c.correction : ''}`,
      suggested_fix: `State the verified fact: ${c.correction || 'remove/correct the claim'} (evidence: ${c.evidence})`,
    }))
}

// --- Phase 1: divergent generation ---
phase('Plan')
const candidates = (
  await parallel(planners(plannerCount).map((fr) => () =>
    agent(planPrompt(fr), { label: `plan:${fr.key}`, phase: 'Plan', schema: PLAN_SCHEMA, agentType: 'Plan' }),
  ))
).filter((p) => !!p).map((p) => p.plan_markdown)

if (!candidates.length) throw new Error('plan-loop: all planners failed.')

// --- Phase 2: judge / synthesize ---
let plan
if (candidates.length === 1) {
  plan = candidates[0]
} else {
  phase('Judge')
  const judged = await agent(judgePrompt(candidates), { label: 'judge', phase: 'Judge', schema: PLAN_SCHEMA, agentType: 'Plan' })
  plan = judged ? judged.plan_markdown : candidates[0]
}

// --- Phase 3: verify + review -> fix loop ---
let consecutiveClean = 0
let roundsRun = 0
let stopReason = 'reached round cap'
let priorBlocking = []
let lowChurnStreak = 0
const changelog = []
const openMinor = []
const seenMinor = {}

for (let round = 1; round <= maxRounds; round += 1) {
  roundsRun = round
  const confirming = consecutiveClean >= 1

  const reviewThunks = panel(reviewerCount).map((lens, i) => () =>
    agent(reviewPrompt(lens, plan, priorBlocking, confirming), {
      label: `review:${lens.key}#${i + 1}`, phase: 'Review', schema: REVIEW_SCHEMA,
    }),
  )
  const checks = await parallel([
    () => agent(verifyPrompt(plan), { label: 'verify', phase: 'Verify', schema: VERIFY_SCHEMA }),
    ...reviewThunks,
  ])
  const verifyRes = checks[0]
  const reviews = checks.slice(1).filter((r) => !!r)

  const reviewFindings = reviews.flatMap((r) => r.findings || [])
  const factFindings = refutedToFindings(verifyRes)
  const blocking = reviewFindings
    .filter((f) => f.severity === 'blocker' || f.severity === 'major')
    .concat(factFindings)
  const refutedCount = factFindings.length

  reviewFindings.filter((f) => f.severity === 'minor').forEach((m) => {
    const k = `${m.area}|${m.problem}`.toLowerCase().slice(0, 160)
    if (!seenMinor[k]) { seenMinor[k] = true; openMinor.push({ round, ...m }) }
  })

  log(`Round ${round}: ${refutedCount} refuted-claim, ${blocking.length - refutedCount} review blocker/major, ${reviews.length} reviewer(s)`)

  if (blocking.length === 0) {
    consecutiveClean += 1
    changelog.push({ round, action: 'clean', blocking: 0, refuted: 0, note: `verified-clean ${consecutiveClean}/${stopAfterClean}` })
    if (consecutiveClean >= stopAfterClean) {
      stopReason = `stable: ${consecutiveClean} consecutive verification-backed clean reviews`
      break
    }
    continue
  }

  consecutiveClean = 0
  const before = plan.length
  const fixed = await agent(fixPrompt(plan, blocking), { label: `fix:round${round}`, phase: 'Fix', schema: PLAN_SCHEMA })
  if (fixed && fixed.plan_markdown) plan = fixed.plan_markdown
  priorBlocking = blocking

  const churn = before ? Math.abs(plan.length - before) / before : 1
  if (churn < 0.02) { lowChurnStreak += 1 } else { lowChurnStreak = 0 }
  changelog.push({
    round, action: 'fixed', blocking: blocking.length, refuted: refutedCount,
    churn: Math.round(churn * 1000) / 10,
    addressed: blocking.map((f) => `[${f.severity}] ${f.area}: ${f.problem}`),
  })
  if (lowChurnStreak >= 2) {
    stopReason = 'diminishing returns: fixer changed the plan <2% for 2 consecutive rounds while findings persist (likely irreducible disagreement) — surfacing for human decision'
    break
  }
}

return { finalPlan: plan, changelog, roundsRun, stopReason, openMinorFindings: openMinor }
```

## Step 2 — Finalize (after the Workflow returns)

Result is `{ finalPlan, changelog, roundsRun, stopReason, openMinorFindings }`.

1. Write `finalPlan` to `--out` (default `.claude/plans/<slug>.md`); create the dir if needed.
2. Present via **plan mode** (`ExitPlanMode`) for approval — do NOT implement. In the summary include: where it was written; rounds run and `stopReason`; the per-round changelog (note `refuted` counts and `churn` %); and any `openMinorFindings`.
3. If `stopReason` is the "diminishing returns" case, flag it clearly — it means the loop could not fully satisfy the reviewer and is handing an irreducible disagreement to you, rather than pretending it converged.

Only implement if the user explicitly approves.

## Notes

- **Verification is the core value.** A refuted claim is treated as a blocker, so the plan cannot finalize while it asserts something the code contradicts. "Clean" here means *both* "no blocker/major review findings" *and* "no refuted claims" — a real signal, not reviewer fatigue.
- **Divergence costs more up front, less overall.** ~`planners` + 1 judge + per round `(1 verify + reviewers + 1 fix)`. Defaults (3 planners + judge + up to 3 rounds × ~3) ≈ 13–16 sessions — front-loaded into quality (divergence + verification) rather than spent on repeated subjective review.
- Verify and review run **in parallel** each round; reviewers are told the fact-checker covers file:line accuracy so they don't duplicate it.
- The churn guard stops honest dead-ends instead of burning the full cap on edits that no longer move the plan.
