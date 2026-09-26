# Agent instructions — manager-driven work on Paseo, any model per role

This folder is a git repo (push it to a remote). Each project's `agents.json` points at that remote and
says which model runs each role there. Agents clone it to `~/.cache/agent-instructions/` and read their
role file from it, so nothing here needs to exist on the machine running them.

## Layout

```
README.md                        this file
preferences.md                   your standing contract + default role → model map
write-project-instructions.md    the setup agent: run once per project, writes agents.json + CLAUDE.md / AGENTS.md
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
wayfinder   → you           N decisions, one at a time; then "What you asked / What you'll get" → your go
wayfinder   → implementor   plan.md; it reports every subtask in its own session
wayfinder   → QA            fresh agent, often on another model; qa-report.md with evidence + a test guide
QA          → you           verdict; open the implementor session and say ship
```

## Once per project — setup

1. Paseo → Settings → host → Agents → **Enable Paseo tools**.
2. In the repo's main workspace, start an agent (any model) and send:
   `You are the setup agent. Read and follow <this repo's git URL>/write-project-instructions.md`
   (or the local path to this folder's copy).
3. It asks: which model for manager / wayfinder / implementor / QA (defaults from `preferences.md`),
   optionally a Paseo profile per role, and a few project facts (test command, no-go paths).
4. It writes `agents.json`, `CLAUDE.md` and/or `AGENTS.md`, excludes `workspace_management/`. You commit.

Profiles are optional — only if you want a role on a specific thinking level or mode. Create them in
Paseo first (Settings → host → Agents → Agent profiles); setup offers the ones on the right model.

## Every day

- Start the manager in the repo's main workspace, on the model `agents.json` names for it:
  `You are the manager. Read config instructions from /abs/path/to/repo/agents.json.`
- Talk to it. Children appear in its **Subagents track**; open any of them to steer it. Every agent
  starts with the same one-line prompt — who it is + the config path.
- **Where's what's left**: any agent's session shows its task list, and every message starts with
  `N of M done · next: <step>`.
- Every question comes with options, a recommendation, and what waits if you don't answer. Say
  **your call** to take the recommendation. Silence never decides anything.
- Ship: read `qa-report.md`, open the implementor session, say **ship** → draft PR; you merge.
  Send it back with **fix QA issues 1, 3**; QA runs again on its own.

## `workspace_management/` (worktree root, never committed)

| File                | Written by  | Read by     | Holds                                                     |
|---------------------|-------------|-------------|-----------------------------------------------------------|
| `brief.md`          | manager     | wayfinder   | your ask, restatement, out of scope, addenda, agent ids   |
| `plan.md`           | wayfinder   | implementor | what you asked / what you'll get, decisions, acceptance criteria, `- [ ]` subtasks |
| `implementation.md` | implementor | QA          | `Status:` / `Revision:`, what changed, how to run, tested |
| `qa-report.md`      | QA          | you         | `Verdict:`, evidence table, manual test guide, issues     |
| `qa-evidence/`      | QA          | you         | logs and screenshots the report points to                 |
| `questions.md`      | everyone    | everyone    | Q&A log; agent-answered entries are marked as such        |
