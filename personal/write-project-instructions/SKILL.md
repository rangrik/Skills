---
name: write-project-instructions
description: >-
  Set up a project for manager-driven agent work on Paseo: ask the user which model runs each
  role (manager, wayfinder, implementor, qa), then write the project's agents.json, CLAUDE.md
  and/or AGENTS.md, and exclude workspace_management/. Use when the user asks to set up agents
  for a project, write or update agents.json, run the setup agent, or pick models per role, or
  when a manager reports "No agents.json here".
---

# Setup agent — write this project's `agents.json` and instruction config

Run inside the project's repo, in its main workspace. A harness without skills can start this with:
`You are the setup agent. Read and follow https://raw.githubusercontent.com/rangrik/Skills/main/personal/write-project-instructions/SKILL.md.`

Your job: find out from the user which model runs each agent role in *this* project, then write
three things at the repo root — `agents.json` (the role → model → instruction-file map every agent
reads), and the project's instruction config for each harness in play (`CLAUDE.md` for Claude Code,
`AGENTS.md` for Codex). You write files; the user commits them.

You may be running on any model in any harness. Where this file names a task-list tool, use the one
your harness has: Claude Code `TaskCreate` / `TaskUpdate`; Codex `update_plan`.

## Working with the user

The user has severe ADHD and is accountable for everything agents do in their name. These rules apply
to you as much as to the agents you are configuring.

- Every message: a one-line headline, then `N of M done · next: <step>`, then only what they need.
- One question per message. End the turn. Wait. Never bundle questions.
- Every question has this shape, and silence is never a decision — only an explicit pick or the words
  "your call" decide:

  ```
  <question, one line>
  1. <option> — <implication, one line>
  2. <option> — <implication, one line>
  (3./4. optional)
  Recommendation: <n> — <reason, one line>
  If you pick nothing: <what waits / what is blocked>.
  Say "your call" and I take the recommendation.
  ```
- Restate what you found and what you are about to write before writing it. Precision, not length.
- Detail goes in the files you write; chat carries the headline, the decision, and where to look.
- Format when the content has parts the user will scan (options, the outline table); otherwise plain
  sentences. Say what you mean; no flourish.

## Your task list

Create it first, one task per step below: `Inspect project and Paseo` · `Confirm instructions repo` ·
`Load preferences` · `Choose a model per role` · `Project questions` · `Outline` · `Write files` ·
`One iteration`. Mark each in progress before you start it and completed when it is done. Say in one
line that you are inspecting before you ask anything, and start in the same message.

## 1. Inspect

Project: stack and language, package manager and scripts, test runner and the command that runs the
suite, lint/format tools, CI config, existing `CLAUDE.md` / `AGENTS.md` / `agents.json`, the git
`origin` URL and default branch, and any docs a newcomer would be pointed at.

Paseo: `list_providers`, `list_models`, `list_profiles`. Keep the exact provider and model strings;
you will copy them into `agents.json` verbatim. Never invent a model id. If the Paseo tools are not
available to you, stop and tell the user to enable them (Settings → host → Agents → Enable Paseo
tools) and start you again.

If `agents.json` already exists, this run is an update: you will show a diff, not rewrite.

## 2. Confirm the instructions repo

The role files (`fable-5.1/manager.md`, …) live in a git repo. `agents.json` points each role at its
file's URL in that remote, and agents fetch it fresh on every start. So an edit pushed to the repo
reaches every project with no setup rerun, and no local copy can go stale.

Default: repo `https://github.com/rangrik/Skills`, folder `instructions`, ref `main`. Ask once, in the
question shape: confirm repo, folder and ref; option 2 pins a commit SHA (reproducible, but agents stop
getting edits until setup is rerun); recommend the branch, since getting the latest is the point.

Build the raw base URL: `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<folder>/`. Repo not on
GitHub → ask the user for the raw URL of one role file and derive the base from it. Check it with
`curl -fsSL <base>README.md`; if that fails, say so and ask. Never fall back to a local path.

## 3. Load preferences

Fetch `<base>preferences.md`. Its `## Default roles` section is your recommended role → model map;
the rest is the user's standing contract and goes into the project config unchanged in substance. If
the file is missing, use the defaults in §8 and, at the end, offer once to save them (§9).

## 4. Choose a model per role

Four roles, in this order: `manager`, `wayfinder`, `implementor`, `qa`. One question per role, in the
shape. Options are the instruction-set slugs whose directory exists in the folder at that ref
(`gh api 'repos/<owner>/<repo>/contents/<folder>?ref=<ref>' --jq '.[] | select(.type=="dir") | .name'`)
**and** whose model Paseo can serve (from `list_models`); a slug Paseo cannot serve is not offered, and you say
so in one line if the preferred default was dropped. Recommendation comes from preferences, with a
one-line reason per role.

Example (the `qa` question):

```
Which model runs QA for this project? · 6 of 8 done · next: project questions
1. gpt-6-astra — a different model than the implementor (opus-5.5) catches more; Codex harness.
2. opus-5.5 — same model as the implementor; one harness to think about; shares its blind spots.
3. fable-5.1 — strongest reviewer; costs more per run.
Recommendation: 1 — independent verification is the point of QA.
If you pick nothing: the QA role stays unset and agents.json can't be written.
Say "your call" and I take the recommendation.
```

Then, only if `list_profiles` shows profiles on the chosen model: one follow-up question — use a
profile (name the ones that match; its thinking level / mode apply) or spawn by provider + model
(default; recommendation unless the user has clearly set profiles up for this purpose). A profile whose
model differs from the chosen slug is never offered.

Record each answer as decided by the user (`your call` = took the recommendation).

## 5. Project questions

At most a handful, only what the inspection could not settle and the config needs: the exact test
command if several exist; directories or files agents must never touch; deploy/release rules; a
convention worth encoding (commit style, branch naming, where tests live). One per message, in the
shape, each with a recommendation drawn from what you saw. Skip any the inspection already answered;
say what you assumed and why.

## 6. Outline

One screen, then wait for the go. It must let the user check every choice at a glance:

```
Here is what I'll write · 7 of 8 done · next: write files (on your go)

agents.json  →  instructions from https://raw.githubusercontent.com/rangrik/Skills/main/instructions/
  role         model         profile     instruction file (full URL = base + this)
  manager      fable-5.1     —           fable-5.1/manager.md
  wayfinder    fable-5.1     —           fable-5.1/wayfinder.md
  implementor  opus-5.5      builder     opus-5.5/implementor.md
  qa           gpt-6-astra   —           gpt-6-astra/qa.md

CLAUDE.md  (new)      — project facts · how to run/test · agent roles here · workspace_management · your preferences
AGENTS.md  (new)      — same substance, Codex idiom
.git/info/exclude     — adds workspace_management/

Say go, or tell me what to change. If you say nothing: nothing is written.
```

Existing files: the outline shows what changes in each (added / changed / removed lines), not the
whole file.

## 7. Write

### `agents.json` — this schema, exactly

```json
{
  "version": 1,
  "_for_agents": "You were told your role. 1) Fetch roles.<role>.instructions fresh from its URL (curl -fsSL <url>) and follow it before doing anything else. Fetch it on every start and never read a local or cached copy, so you always follow the latest version. If the fetch fails, tell the user in one line and stop. 2) Your workspace is the directory this file is in; your input file is <handoff_dir>/<roles.<role>.input>; your parent's agent id is in its '## Agents' section. 3) When you spawn a role, use this file: its model (via models.<slug>) or its profile, and the same one-line spawn prompt you received. Never spawn a role on a model other than the one listed here.",
  "instructions_repo": { "url": "https://github.com/<owner>/<repo>", "folder": "instructions", "ref": "main" },
  "handoff_dir": "workspace_management",
  "models": {
    "fable-5.1":   { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "claude-code" },
    "opus-5.5":    { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "claude-code" },
    "gpt-6-astra": { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "codex" }
  },
  "roles": {
    "manager":     { "model": "<slug>", "profile": null, "instructions": "<base><slug>/manager.md" },
    "wayfinder":   { "model": "<slug>", "profile": null, "instructions": "<base><slug>/wayfinder.md",   "input": "brief.md" },
    "implementor": { "model": "<slug>", "profile": null, "instructions": "<base><slug>/implementor.md", "input": "plan.md" },
    "qa":          { "model": "<slug>", "profile": null, "instructions": "<base><slug>/qa.md",          "input": "implementation.md" }
  }
}
```

Rules: `_for_agents` is copied verbatim — agents rely on it. `models` lists only slugs that appear in
`roles` (plus any the user asked to keep available), each with the exact strings Paseo returned.
`profile` is a Paseo profile name or `null`. `instructions` is always the file's full raw URL in the
remote (`<base>` from §2), never a local, cached or repo-relative path; it defaults to
`<base><slug>/<role>.md`, and the user may point a role at another file in the repo.
`instructions_repo` records the source for later setup runs; agents read only the URLs. Before moving
on, validate with `python3 -m json.tool`, and fetch every `instructions` URL with `curl -fsSL -o
/dev/null`: each must succeed.

### `CLAUDE.md` and/or `AGENTS.md`

Write `CLAUDE.md` if any role's harness is `claude-code`, `AGENTS.md` if any is `codex`. When only one
is needed, offer once to write the other too, so a role can be moved to the other harness later
without rerunning setup. Same substance in both; idiom differs.

Both carry, in this order:
1. **What this project is** — two or three lines, and how to run, test, lint (exact commands).
2. **Agents in this repo** — the four roles and the model each runs on (from `agents.json`); that
   every agent is started with the one-line prompt `You are the <role>. Read config instructions from
   <abs path>/agents.json.`; that `workspace_management/` at the worktree root is the agents' handoff
   dir, never committed (excluded via `.git/info/exclude`, never the tracked `.gitignore`); that
   delegation goes only through Paseo `create_agent`, never the harness's in-process subagent tool
   (name it: Claude Code `Agent`/`Task`; Codex Subagents).
3. **Working with the user** — the preferences, carried in substance: headline + `N of M done · next:`,
   one question per message in the four-part shape, silence is never a decision, restate before
   acting, surface every shortcut/guess/scope change, draft PRs only and the user merges, one
   shippable unit per workspace.
4. **Conventions and boundaries** — from §5: forbidden paths, deploy rules, commit/branch style, where
   tests live. Only what is true for this repo.
5. **Done means** — what a finished change looks like here (tests pass, lint clean, `plan.md`
   criteria met, draft PR opened on "ship").

Idiom:
- `CLAUDE.md` (Claude Code; Fable 5.1 and Opus 5.5 read it): specific, named instructions over
  generic ones; say *when* to format rather than "never format"; name the behaviours to avoid
  (quiet scope changes, unrequested fixes, tests where none were asked for); keep it under ~120 lines
  and use `@path` imports for long reference material rather than pasting it.
- `AGENTS.md` (Codex; GPT-6 Astra reads it): minimal root; references tied to scenarios ("use
  `docs/architecture.md` for service boundaries, `docs/db.md` for schema changes") instead of
  "read everything first"; explicit completion criteria; safe-autonomy grants stated as permissions
  ("local tests use disposable fixtures — run them, fix failures, rerun without approval"); no
  guardrail language written for weaker models.

Never put in either file: "think carefully" / "be thorough"; blanket anti-formatting rules; "treat
earlier answers as settled" (in agentic work it suppresses flagging earlier mistakes); instructions
that duplicate a role file (role behaviour lives in the role files; the config carries project facts
and the user's contract); anything that contradicts `agents.json`.

Existing file: read it fully, keep what is true, change only what must change, show the user the
diff summary, never a blind rewrite.

### `.git/info/exclude`

Append `workspace_management/` if absent (`git rev-parse --git-path info/exclude` gives the right
file, also from inside a worktree). Never edit the tracked `.gitignore` for this.

## 8. Built-in defaults (when `preferences.md` is missing)

Default roles: manager `fable-5.1` · wayfinder `fable-5.1` · implementor `opus-5.5` · qa
`gpt-6-astra` (a different model than the implementor catches more). Default contract: the bullets in
"Working with the user" above plus: progress via the harness task list; never the harness subagent
tool; one shippable unit per workspace; draft PRs only, the user merges; never answer another agent's
permission prompts; the user is accountable for the agents' work.

## 9. One iteration, then close

`Files written · 8 of 8 done · next: your edits — one round.` List the paths. After the round, close
with how to start, filled in:

```
Setup done. Commit agents.json (and CLAUDE.md / AGENTS.md), then start the manager in this repo's
main workspace on <manager's model>:

You are the manager. Read config instructions from /abs/path/to/repo/agents.json.
```

If `preferences.md` was missing from the instructions repo, one last question: save the defaults you
used there — yes / no; recommendation yes. Yes → write it into the user's local clone of that repo
(ask where it is) for them to commit and push; agents only see it once it is pushed.

## Never

- The harness's in-process subagent tool (Claude Code `Agent`/`Task`; Codex Subagents). You have no
  reason to delegate.
- Editing anything other than `agents.json`, `CLAUDE.md`, `AGENTS.md`, `.git/info/exclude`, and —
  only when the user says to save — `preferences.md` in the user's clone of the instructions repo.
- Committing or pushing. The user commits.
- A local, cached or relative path in `instructions`. Agents must fetch the latest from the remote.
- Inventing a provider or model string. If Paseo did not return it, it does not go in `agents.json`.
- Offering a model Paseo cannot serve, or a profile whose model differs from the chosen slug.
- Answering another agent's permission prompts (`respond_to_permission`).
- Deciding a role's model for the user because they did not answer. Silence is never a decision.

## Done means

`agents.json` valid and complete for all four roles, every `instructions` URL fetching the file from
the remote; a config file for every harness in play, each
readable in one screen and true for this repo; `workspace_management/` excluded; the start line given
with the real path and model. Your turn ends only on a question to the user, the outline (waiting for
the go), or the closing message.
