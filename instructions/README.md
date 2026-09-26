# Agent instructions — manager-driven work on Paseo, any model per role

This folder lives in `rangrik/Skills` on GitHub. Each project's `agents.json` says which model runs each
role there and gives the role file's URL in this repo. Agents fetch that URL fresh on every start, so a
push here reaches every project at once and nothing needs to exist on the machine running them.

## Layout

```
README.md                        this file
preferences.md                   your standing contract + default role → model map
fable-5.1/                       manager.md · wayfinder.md · implementor.md · qa.md   (Claude Fable 5.1, Claude Code)
opus-5.5/                        manager.md · wayfinder.md · implementor.md · qa.md   (Claude Opus 5.5, Claude Code)
gpt-6-astra/                     manager.md · wayfinder.md · implementor.md · qa.md   (GPT-6 Astra, Codex)
```

Same behaviour in every set, written in each model's idiom. Mix freely: manager on Fable, implementor
on Opus, QA on Astra.

## Flow

```
you         → manager       say what you want; it restates, nudges, asks "Go?"
manager     → wayfinder     new worktree workspace + brief.md
wayfinder   → you           the simplest UX first (Mobbin references), then N decisions, one at a time; then "What you asked / What you'll get" → your go
wayfinder   → implementor   plan.md; it builds, tests, one short smoke; its questions come back to you through the wayfinder
wayfinder   → QA            fresh agent, often on another model; the only full live pass; qa-report.md with proof, a UX check + a test guide
wayfinder   → implementor   fix first → sent back on its own; clean → delivery per the repo's ship rule
wayfinder   → you           shipped: how it works now in three lines, the test guide, and one question: archive the workspace?
```

## Once per project — setup

1. Paseo → Settings → host → Agents → **Enable Paseo tools**.
2. In the repo's main workspace, start an agent (any model) and run the `write-project-instructions`
   skill (`personal/write-project-instructions/` in this repo). Without skills, send:
   `You are the setup agent. Read and follow https://raw.githubusercontent.com/rangrik/Skills/main/personal/write-project-instructions/SKILL.md`
3. It asks which model and effort run manager / wayfinder / implementor / QA (defaults from
   `preferences.md`; picks you give up front, like `qa opus xhigh`, are taken as is), and a few
   project facts it couldn't find itself.
4. It writes `agents.json` and `AGENTS.md` (`CLAUDE.md` a symlink to it), excludes
   `workspace_management/`, then commits and pushes on the current branch.

Effort lives in `agents.json` per role and is passed to Paseo as the thinking level at spawn.
Paseo profiles are not used.

## Every day

- Start the manager in the repo's main workspace, on the model `agents.json` names for it:
  `You are the manager. Read config instructions from /abs/path/to/repo/agents.json.`
- Talk to it. Children appear in its **Subagents track**; open any of them to steer it. Every agent
  starts with the same one-line prompt — who it is + the config path.
- **Where's what's left**: every message starts with `N of M done · next: <step>` (Paseo sessions
  have no task-list tool, so that line is the dashboard).
- Every question comes through the harness's question tool with options, the recommended one first,
  and what waits if you don't answer, so Paseo flags the session "needs you". Only the manager and
  the wayfinders ask; the implementor and QA route theirs through the wayfinder. Silence never
  decides anything.
- Ship: the project's `AGENTS.md` sets the rule and overrides the role files. With the default in
  `preferences.md`, clean QA ships on its own and failing QA goes back to the implementor. You say
  **ship** in the wayfinder's session only when QA asks you to test it yourself.
- Live testing: one pass per repo at a time on a lock, short bursts, your installed app and real
  preferences untouched. Nobody asks you who goes first.
- Codex agents cannot flag "needs you" (their question tool is off in the default mode); keep the
  manager and wayfinder on Claude models.

## `workspace_management/` (worktree root, never committed)

| File                | Written by  | Read by     | Holds                                                     |
|---------------------|-------------|-------------|-----------------------------------------------------------|
| `brief.md`          | manager     | wayfinder   | your ask, restatement, out of scope, addenda, agent ids   |
| `plan.md`           | wayfinder   | implementor | what you asked / what you'll get, decisions, acceptance criteria, `- [ ]` subtasks |
| `implementation.md` | implementor | QA, wayfinder | `Status:` / `Revision:`, what changed, how to run, tested |
| `qa-report.md`      | QA          | wayfinder, you | `Verdict:`, evidence table, manual test guide, issues   |
| `qa-evidence/`      | QA          | you         | logs and screenshots the report points to                 |
| `questions.md`      | everyone    | everyone    | Q&A log; agent-answered entries are marked as such        |
| `roles/<role>.md`   | the parent  | the child   | the child's role file, fetched fresh at spawn (for sandboxed children) |
| `delivery.md`       | implementor | wayfinder   | `Status:`, then one line of evidence per delivery step    |

Before any merge the whole folder is copied to `<repo>/.git/agent-handoff/<slug>/`, because Paseo can
delete a worktree the moment its PR merges. The live-test lock lives at `<repo>/.git/agent-live.lock`.
