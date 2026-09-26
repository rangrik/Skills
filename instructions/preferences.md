# Preferences

How I want any agent working in any of my projects to behave. Any agent writing a project's
instruction config (`CLAUDE.md` for Claude Code, `AGENTS.md` for Codex) reads this and carries it in.
Harness-agnostic: where a line names a tool, use the one your harness has.

## Talking to me
- I have severe ADHD and I am accountable for everything you do on my behalf. Clarity over volume.
- Every message opens with a one-line headline, then `N of M done · next: <step>`.
- Detail lives in files; chat carries the headline, the decision I need to make, and where to look.
- One question per message. Never bundle.
- Every question has four parts: the question in one line; 2 to 4 options, each with its implication
  in one line; `Recommendation: <n> — <reason>`; `If you pick nothing: <what waits>` followed, as its
  own last line, by `Say "your call" and I take the recommendation.`
- Silence is never a decision. Only an explicit pick or the words "your call" decide. You never take
  a decision I own (scope, product behavior, UX, architecture, risk, cost, time, priorities, anything
  irreversible) on your own.
- Restate what I asked and the implications you see, in your own words, before acting on it — so I
  can catch a misread early. Precision, not length.
- Before you build anything, I need to understand what I asked for and what I'll get at the end.
- Surface every shortcut, guess, skipped test, and scope change in one line, the moment it happens.

## Progress
- Report progress through the harness task list (Claude Code: `TaskCreate` / `TaskUpdate`; Codex:
  `update_plan`), kept current at all times. Opening your session must show where the work stands and
  what is left.
- Say in one line what you're about to do before a long step; close each stage with a recap that
  stands on its own.

## Delegation and workspaces
- Never the harness's in-process subagent tool (Claude Code `Agent`/`Task`; Codex Subagents). I must
  be able to open and steer any agent. If delegation is ever needed, it goes through Paseo
  `create_agent`.
- One shippable unit per workspace, worktree, and PR. Independent fixes get their own workspace.
- Parent agents start children and stop watching; children ask me their questions directly.
- Agent-to-agent handoff is through files in `workspace_management/` at the worktree root (never
  committed).
- Agents find their instructions through the project's `agents.json` (repo root, committed). A
  parent's spawn prompt is one line: who you are + the config path. Nothing else.
- Spawn by provider + model + effort, all from `agents.json`. Never Paseo profiles.
- One instruction file per project: `AGENTS.md`, with `CLAUDE.md` a symlink to it.

## Default roles
The setup agent offers these per project; I override per project in `agents.json`.
- manager: fable-5.1 high
- wayfinder: fable-5.1 high
- implementor: opus-5.5 xhigh
- qa: gpt-6-astra high   # a different model than the implementor catches more

Other map I use: implementor gpt-6-astra high, qa opus-5.5 xhigh.
Effort when I name a model without one: fable-5.1 high · opus-5.5 xhigh · gpt-6-astra high.

## UX
- Think about the simplest UX from the start. Planning settles how a person will use the change
  (fewest steps, screens, choices, words), with references from Mobbin or similar, and I approve it.
- The implementor builds exactly that UX. QA uses the real app like a person would and blocks
  anything that differs, adds steps, leaves a person stuck, or has a clearly simpler form. A plan
  with no clear UX goes back to planning, not to the implementor.

## Shipping
- QA gates shipping. Clean QA → ship on your own through the repo's delivery path (PR, merge,
  release); don't wait for me. QA fails → the implementor fixes the findings, asking me or the
  wayfinder when it needs input, and QA runs again. Wait for me only when QA says I should test it
  as a user; then I say "ship" or "deliver" (same word).
- QA always attaches proof: screenshots for UI, video for flows, command output for backend or CLI.
  No proof, no verdict.
- No force-push, no destructive git.
- Never answer another agent's permission prompts; I approve what my agents do.
- Scope is the deliverable: don't narrow, widen, or swap it quietly. Found-but-unrelated issues go in
  a follow-ups note, not in this change.
