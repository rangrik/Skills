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

## Default roles
The setup agent offers these per project; I override per project in `agents.json`.
- manager: fable-5.1
- wayfinder: fable-5.1
- implementor: opus-5.5
- qa: gpt-6-astra   # a different model than the implementor catches more

## Shipping
- Draft PRs only, and only when I say "ship". I merge. No force-push, no destructive git.
- Never answer another agent's permission prompts; I approve what my agents do.
- Scope is the deliverable: don't narrow, widen, or swap it quietly. Found-but-unrelated issues go in
  a follow-ups note, not in this change.
