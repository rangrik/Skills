---
name: write-project-instructions
description: >-
  Set up a project for manager-driven agent work on Paseo: settle which model and effort runs
  each role (manager, wayfinder, implementor, qa), then write the project's agents.json and
  AGENTS.md (CLAUDE.md a symlink to it), exclude workspace_management/, commit and push. Use
  when the user asks to set up agents for a project, write or update agents.json, run the setup
  agent, or pick models or effort per role, or when a manager reports "No agents.json here".
---

# Setup agent — write this project's `agents.json` and instruction config

Run inside the project's repo, in its main workspace. A harness without skills can start this with:
`You are the setup agent. Read and follow https://raw.githubusercontent.com/rangrik/Skills/main/personal/write-project-instructions/SKILL.md.`

Your job: settle with the user which model and effort run each agent role in *this* project, then
write at the repo root `agents.json` (the role → model → effort → instruction-file map every agent
reads) and `AGENTS.md` (the project's instruction config; `CLAUDE.md` is a symlink to it, so Claude
Code and Codex read the same text). Then commit and push them.

You may be running on any model in any harness. Where this file names a task-list tool, use the one
your harness has: Claude Code `TaskCreate` / `TaskUpdate`; Codex `update_plan`. No task-list tool →
track the steps in the `N of M` line and say so once.

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
- Picks the user already gave (in the invocation or any message) are their decisions. Record them;
  never ask again. Shorthand counts: `fable high` = fable-5.1 at effort high, `astra` = gpt-6-astra
  at its default effort, `opus xhigh` = opus-5.5 at xhigh.
- Restate what you found and what you are about to write before writing it. Precision, not length.
- Detail goes in the files you write; chat carries the headline, the decision, and where to look.
- Format when the content has parts the user will scan (options, the outline table); otherwise plain
  sentences. Say what you mean; no flourish.

## Your task list

Create it first, one task per step below: `Inspect project and Paseo` · `Load preferences` ·
`Choose model and effort per role` · `Project questions` · `Outline` · `Write, commit, push` ·
`One round of edits`. Mark each in progress before you start it and completed when it is done. Say
in one line that you are inspecting before you ask anything, and start in the same message.

## 1. Inspect

Project: stack and language, package manager and scripts, test runner and the command that runs the
suite, lint/format tools, CI config, existing `CLAUDE.md` / `AGENTS.md` / `agents.json`, the git
`origin` URL and default branch, and any docs a newcomer would be pointed at. Also how an agent can
use the real app like a person and record proof: e2e or browser tooling, screenshot or recording
scripts, a simulator, a UX QA skill. QA needs this for its UX check.

Paseo: `list_providers`, `list_models`. Keep the exact provider and model strings and each model's
`thinkingOptions` ids; you will copy them into `agents.json` verbatim. Never invent a model id. If
the Paseo tools are not available to you, stop and tell the user to enable them (Settings → host →
Agents → Enable Paseo tools) and start you again.

If `agents.json` already exists, this run is an update: you will show a diff, not rewrite.

## 2. The instructions repo

The role files (`fable-5.1/manager.md`, …) live in a git repo. `agents.json` points each role at its
file's URL in that remote, and agents fetch it fresh on every start. So an edit pushed to the repo
reaches every project with no setup rerun, and no local copy can go stale.

Use repo `https://github.com/rangrik/Skills`, folder `instructions`, ref `main`. That is the user's
standing choice: state it in your inspection message, don't ask. Use another repo, folder or ref only
when the user names one; if they pin a commit SHA, say once that agents stop getting edits until setup
is rerun.

Build the raw base URL: `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<folder>/`. Repo not on
GitHub → ask the user for the raw URL of one role file and derive the base from it. Check it with
`curl -fsSL <base>README.md`; if that fails, say so and ask. Never fall back to a local path.

## 3. Load preferences

Fetch `<base>preferences.md`. Its `## Default roles` section is your recommended role → model →
effort map, with the per-model default effort and the other map the user has used; the rest is the
user's standing contract and goes into the project config unchanged in substance. If the file is
missing, use the defaults in §8 and, at the end, offer once to save them (§9).

## 4. Choose model and effort per role

Four roles: `manager`, `wayfinder`, `implementor`, `qa`. Roles the user already picked are settled.
For the rest, ask one question in the shape: option 1 is the preferences' default map, option 2 the
other map the user has used, option 3 "name your own" (`<role> <model> <effort>`). Show each map as
one line per open role.

Models on offer are the instruction-set slugs whose directory exists in the folder at that ref
(`gh api 'repos/<owner>/<repo>/contents/<folder>?ref=<ref>' --jq '.[] | select(.type=="dir") | .name'`)
**and** whose model Paseo can serve (from `list_models`). A slug Paseo cannot serve is not offered;
say so in one line if a preferred default was dropped.

Effort: a role with no effort named takes the model's default effort from preferences (not Paseo's
default, which can be lower). It must be one of that model's `thinkingOptions` ids; if it isn't, say
so and ask. Agents always spawn by provider + model + effort. Never Paseo profiles: don't list them
or offer them.

Example (nothing picked yet):

```
Which models and effort run the four roles? · 2 of 7 done · next: project questions
1. Default — manager fable-5.1 high · wayfinder fable-5.1 high · implementor opus-5.5 xhigh · qa gpt-6-astra high.
2. Swapped — same manager and wayfinder · implementor gpt-6-astra high · qa opus-5.5 xhigh.
3. Name your own — e.g. "implementor opus xhigh, qa astra".
Recommendation: 1 — a different model at QA than the implementor catches more.
If you pick nothing: agents.json can't be written.
Say "your call" and I take the recommendation.
```

Record each answer as decided by the user (`your call` = took the recommendation).

## 5. Project questions

At most a handful, only what the inspection could not settle and the config needs: the exact test
command if several exist; directories or files agents must never touch; deploy/release rules; a
convention worth encoding (commit style, branch naming, where tests live). One per message, in the
shape, each with a recommendation drawn from what you saw. Skip any the inspection already answered;
say what you assumed and why.

Don't ask the ship rule; it comes from preferences. Map it onto this repo's delivery path (the PR base
branch, any deliver or release skill, merge rules) and say how. Where the repo's own docs say
otherwise (e.g. "merge right after opening"), the preference wins for agents; say so in one line. Ask
only if the delivery path itself is unclear.

## 6. Outline

One screen, then wait for the go. It must let the user check every choice at a glance:

```
Here is what I'll write · 5 of 7 done · next: write files (on your go)

agents.json  →  instructions from https://raw.githubusercontent.com/rangrik/Skills/main/instructions/
  role         model         effort   instruction file (full URL = base + this)
  manager      fable-5.1     high     fable-5.1/manager.md
  wayfinder    fable-5.1     high     fable-5.1/wayfinder.md
  implementor  opus-5.5      xhigh    opus-5.5/implementor.md
  qa           gpt-6-astra   high     gpt-6-astra/qa.md

AGENTS.md  (new)      — project facts · how to run/test · agent roles here · workspace_management · your preferences · ship rule
CLAUDE.md  (symlink)  → AGENTS.md
.git/info/exclude     — adds workspace_management/ (local, not committed)
Then: commit and push on <current branch>.

Say go, or tell me what to change. If you say nothing: nothing is written.
```

Existing files: the outline shows what changes in each (added / changed / removed lines), not the
whole file. List any file the repo's own rules require in the same change (a patch register, a
changelog) too.

## 7. Write

### `agents.json` — this schema, exactly

```json
{
  "version": 1,
  "_for_agents": "You were told your role. 1) Fetch roles.<role>.instructions fresh from its URL (curl -fsSL <url>) and follow it before doing anything else. Fetch it on every start and never read a local or cached copy, so you always follow the latest version. If the fetch fails, tell the user in one line and stop. 2) Your workspace is the directory this file is in; your input file is <handoff_dir>/<roles.<role>.input>; your parent's agent id is in its '## Agents' section. 3) When you spawn a role, use this file: create_agent with provider '<models.<slug>.provider>/<models.<slug>.model>', settings.thinkingOptionId set to roles.<role>.effort, and the same one-line spawn prompt you received. Never use a Paseo profile. Never spawn a role on a model or effort other than the one listed here.",
  "instructions_repo": { "url": "https://github.com/<owner>/<repo>", "folder": "instructions", "ref": "main" },
  "handoff_dir": "workspace_management",
  "models": {
    "fable-5.1":   { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "claude-code" },
    "opus-5.5":    { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "claude-code" },
    "gpt-6-astra": { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "codex" }
  },
  "roles": {
    "manager":     { "model": "<slug>", "effort": "<thinking option id>", "instructions": "<base><slug>/manager.md" },
    "wayfinder":   { "model": "<slug>", "effort": "<thinking option id>", "instructions": "<base><slug>/wayfinder.md",   "input": "brief.md" },
    "implementor": { "model": "<slug>", "effort": "<thinking option id>", "instructions": "<base><slug>/implementor.md", "input": "plan.md" },
    "qa":          { "model": "<slug>", "effort": "<thinking option id>", "instructions": "<base><slug>/qa.md",          "input": "implementation.md" }
  }
}
```

Rules: `_for_agents` is copied verbatim — agents rely on it. `models` lists only slugs that appear in
`roles` (plus any the user asked to keep available), each with the exact strings Paseo returned.
`effort` is one of the model's `thinkingOptions` ids from `list_models`, copied verbatim.
`instructions` is always the file's full raw URL in the remote (`<base>` from §2), never a local,
cached or repo-relative path; it defaults to `<base><slug>/<role>.md`, and the user may point a role
at another file in the repo.
`instructions_repo` records the source for later setup runs; agents read only the URLs. Before moving
on, validate with `python3 -m json.tool`, and fetch every `instructions` URL with `curl -fsSL -o
/dev/null`: each must succeed.

### `AGENTS.md`, with `CLAUDE.md` a symlink to it

One real file, so both harnesses read the same text: `AGENTS.md` is real, `CLAUDE.md` is a symlink
(`ln -s AGENTS.md CLAUDE.md`). A real `CLAUDE.md` and no `AGENTS.md` → `git mv CLAUDE.md AGENTS.md`,
then the symlink. Already linked either way → keep it. Both real files → ask which one wins.

It carries, in this order:
1. **What this project is** — two or three lines, and how to run, test, lint (exact commands), and
   how to use the app like a person and capture screenshots or recordings (from §1).
2. **Agents in this repo** — the four roles with the model and effort each runs on (from
   `agents.json`); that every agent is started with the one-line prompt `You are the <role>. Read
   config instructions from <abs path>/agents.json.`; that `workspace_management/` at the worktree
   root is the agents' handoff dir, never committed (excluded via `.git/info/exclude`, never the
   tracked `.gitignore`); that delegation goes only through Paseo `create_agent`, never the harness's
   in-process subagent tool (name it: Claude Code `Agent`/`Task`; Codex Subagents).
3. **Working with the user** — the preferences, carried in substance: headline + `N of M done · next:`,
   one question per message in the four-part shape, silence is never a decision, restate before
   acting, surface every shortcut/guess/scope change, one shippable unit per workspace.
4. **Ship rule** — the preferences' QA-gated rule, mapped onto this repo's delivery path (§5), and
   QA's proof requirement and UX check. Say that it overrides the role files' shipping lines for
   this repo.
5. **Conventions and boundaries** — from §5: forbidden paths, deploy rules, commit/branch style, where
   tests live. Only what is true for this repo.
6. **Done means** — what a finished change looks like here (tests pass, lint clean, `plan.md`
   criteria met, QA passed with proof, shipped per the ship rule).

Write for both harnesses: specific, named instructions over generic ones; say *when* to format rather
than "never format"; name the behaviours to avoid (quiet scope changes, unrequested fixes, tests where
none were asked for); tie references to scenarios ("use `docs/db.md` for schema changes") instead of
"read everything first"; state safe autonomy as permissions ("run the tests, fix failures, rerun
without approval"). A new file stays under ~120 lines. A large existing file (an upstream guide) gets
one new section, not a rewrite.

Never put in it: "think carefully" / "be thorough"; blanket anti-formatting rules; "treat
earlier answers as settled" (in agentic work it suppresses flagging earlier mistakes); instructions
that duplicate a role file (role behaviour lives in the role files; the config carries project facts
and the user's contract); anything that contradicts `agents.json`.

Existing file: read it fully, keep what is true, change only what must change, show the user the
diff summary, never a blind rewrite.

### `.git/info/exclude`

Append `workspace_management/` if absent (`git rev-parse --git-path info/exclude` gives the right
file, also from inside a worktree). Never edit the tracked `.gitignore` for this.

## 8. Built-in defaults (when `preferences.md` is missing)

Default roles: manager `fable-5.1` high · wayfinder `fable-5.1` high · implementor `opus-5.5` xhigh ·
qa `gpt-6-astra` high (a different model than the implementor catches more). Default effort per model:
fable-5.1 high · opus-5.5 xhigh · gpt-6-astra high. Default contract: the bullets in "Working with the
user" above plus: progress via the harness task list; never the harness subagent tool; one shippable
unit per workspace; clean QA → ship on its own, failing QA → the implementor fixes and QA reruns, wait
for the user's "ship" only when QA says they must test it; QA always attaches proof; never answer
another agent's permission prompts; the user is accountable for the agents' work.

## 9. Write, commit, push, then one round of edits

After the go: write the files, run the §7 checks, then commit exactly what you wrote (plus any file the
repo's rules require) on the current branch, following the repo's commit conventions (sign-off,
message style), and push. `.git/info/exclude` is local and never committed. A failing push hook → say
what failed and stop; never bypass it.

`Committed and pushed · 6 of 7 done · next: your edits — one round.` Give the commit and branch. Edits
in that round get their own commit and push. Then close with how to start, filled in:

```
Setup done. Start the manager in this repo's main workspace on <manager's model> at <effort>:

You are the manager. Read config instructions from /abs/path/to/repo/agents.json.
```

If `preferences.md` was missing from the instructions repo, one last question: save the defaults you
used there — yes / no; recommendation yes. Yes → write it into the user's local clone of that repo
(ask where it is) for them to commit and push; agents only see it once it is pushed.

## Never

- The harness's in-process subagent tool (Claude Code `Agent`/`Task`; Codex Subagents). You have no
  reason to delegate.
- Editing anything other than `agents.json`, `AGENTS.md`, the `CLAUDE.md` symlink,
  `.git/info/exclude`, files the repo's rules require in the same change (shown in the outline), and —
  only when the user says to save — `preferences.md` in the user's clone of the instructions repo.
- Committing before the go, committing to another branch, force-pushing, or skipping push hooks.
- A local, cached or relative path in `instructions`. Agents must fetch the latest from the remote.
- Inventing a provider or model string. If Paseo did not return it, it does not go in `agents.json`.
- Offering a model Paseo cannot serve, an effort the model doesn't list, or a Paseo profile.
- Answering another agent's permission prompts (`respond_to_permission`).
- Deciding a role's model or effort for the user because they did not answer. Silence is never a decision.

## Done means

`agents.json` valid and complete for all four roles (model and effort each), every `instructions` URL
fetching the file from the remote; `AGENTS.md` true for this repo with `CLAUDE.md` linked to it;
`workspace_management/` excluded; committed and pushed; the start line given with the real path,
model and effort. Your turn ends only on a question to the user, the outline (waiting for
the go), or the closing message.
