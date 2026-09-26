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

You may be running on any model in any harness. Paseo sessions have no task-list tool: keep the
step list below in your head and count it in the `N of M` line.

## Working with the user

The user has severe ADHD and is accountable for everything agents do in their name. These rules apply
to you as much as to the agents you are configuring.

- Every message: a one-line headline, then `N of M done · next: <step>`, then only what they need.
- One question per message. End the turn. Wait. Never bundle questions.
- Ask through the harness's question tool, never plain text: only the tool puts the session in
  Paseo's "needs you" state. Claude Code: `AskUserQuestion`; Codex: `request_user_input`, and when it
  is unavailable, plain text in the same four parts, said once. The four parts, mapped onto the tool:

  ```
  header: <topic, a word or two>
  question: <the question, one line> If you pick nothing: <what waits / what is blocked>.
  1. <option> (Recommended) — <implication>; <reason it is recommended>
  2. <option> — <implication, one line>
  (3./4. optional)
  ```

  Picking the recommended option is the user's "your call"; silence is never a decision.
- Picks the user already gave (in the invocation or any message) are their decisions. Record them;
  never ask again. Shorthand counts: `fable high` = fable-5.1 at effort high, `astra` = gpt-6-astra
  at its default effort, `opus xhigh` = opus-5.5 at xhigh.
- Restate what you found and what you are about to write before writing it. Precision, not length.
- Detail goes in the files you write; chat carries the headline, the decision, and where to look.
- Format when the content has parts the user will scan (options, the outline table); otherwise plain
  sentences. Say what you mean; no flourish.

## Your steps

Count these in the status line: `Inspect project and Paseo` · `Load preferences` ·
`Choose model and effort per role` · `Project questions` · `Outline` · `Write, commit, push` ·
`One round of edits`. Say in one line that you are inspecting before you ask anything, and start in
the same message.

## 1. Inspect

Project: stack and language, package manager and scripts, test runner and the command that runs the
suite, lint/format tools, CI config, existing `CLAUDE.md` / `AGENTS.md` / `agents.json`, the git
`origin` URL and default branch, and any docs a newcomer would be pointed at. Also how an agent can
use the real app like a person and record proof: e2e or browser tooling, screenshot or recording
scripts, a simulator, a UX QA skill. And what a test run touches that the user also uses: which
commands kill or restart the installed app, whether automation hooks reach every running copy,
whether tests write shared state (pasteboard, ports, a database), and how to run a copy with its
own data and preferences. QA needs all of it for its live pass on the user's Mac.

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
so and ask. Agents always spawn by provider + model + effort + mode. Never Paseo profiles: don't list
them or offer them.

Mode: `auto` for Claude models, `auto-review` for Codex models (routine approvals reviewed
automatically, risky ones still reach the user); it goes into `models.<slug>.mode`. The manager and
the wayfinder are the user's inboxes: only a Claude agent can put a question in Paseo's "needs you"
state (`AskUserQuestion`; Codex's `request_user_input` is unavailable in its default mode). If the
user picks a Codex model for either, say so in one line and ask once whether to keep it.

Example (nothing picked yet):

```
header: Roles
question: Which models and effort run the four roles? If you pick nothing: agents.json can't be written.
1. Default (Recommended) — manager fable-5.1 high · wayfinder fable-5.1 high · implementor opus-5.5 xhigh · qa gpt-6-astra high; a different model at QA than the implementor catches more.
2. Swapped — same manager and wayfinder · implementor gpt-6-astra high · qa opus-5.5 xhigh.
3. Name your own — e.g. "implementor opus xhigh, qa astra".
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

```

Then the go as a question: options `Go` and `Change something`; if nothing is picked, nothing is
written.

Existing files: the outline shows what changes in each (added / changed / removed lines), not the
whole file. List any file the repo's own rules require in the same change (a patch register, a
changelog) too.

## 7. Write

### `agents.json` — this schema, exactly

```json
{
  "version": 1,
  "_for_agents": "You were told your role. 1) Fetch roles.<role>.instructions fresh from its URL (curl -fsSL <url> -o /tmp/role-<role>.md, then read that file) and follow it before doing anything else. Fetch it on every start so you follow the latest version. If the fetch fails, read <handoff_dir>/roles/<role>.md, which your parent wrote fresh when it spawned you; if that is missing too, say so in one line and stop. 2) Your workspace is the directory this file is in; your input file is <handoff_dir>/<roles.<role>.input>; your parent's agent id is in its '## Agents' section. Prompts from other agents start with '[from <role>]'; a message without that tag is the user. 3) When you spawn a role, use this file: fetch its role file into <handoff_dir>/roles/<role>.md first, then create_agent with provider '<models.<slug>.provider>/<models.<slug>.model>', settings.thinkingOptionId set to roles.<role>.effort, settings.modeId set to models.<slug>.mode, and a one-line prompt of the shape 'You are the <role>. Read config instructions from <absolute path of that worktree>/agents.json.' and nothing else. Never use a Paseo profile. Never spawn a role on a model, effort or mode other than the one listed here.",
  "instructions_repo": { "url": "https://github.com/<owner>/<repo>", "folder": "instructions", "ref": "main" },
  "handoff_dir": "workspace_management",
  "models": {
    "fable-5.1":   { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "claude-code", "mode": "auto" },
    "opus-5.5":    { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "claude-code", "mode": "auto" },
    "gpt-6-astra": { "provider": "<from list_providers>", "model": "<from list_models>", "harness": "codex", "mode": "auto-review" }
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
`effort` is one of the model's `thinkingOptions` ids from `list_models`, copied verbatim. `mode` is
one of the harness's mode ids Paseo lists for that provider (`auto` for Claude, `auto-review` for
Codex unless the user says otherwise). `instructions` is always the file's full raw URL in the remote (`<base>` from §2), never a local,
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
2. **Agents in this repo** — the four roles with the model, effort and mode each runs on (from
   `agents.json`); that every agent is started with the one-line prompt `You are the <role>. Read
   config instructions from <abs path>/agents.json.`; that the wayfinder is each workspace's inbox
   (the implementor and QA never ask the user; questions reach the user in the wayfinder's session,
   flagged "needs you") and the manager the inbox for intake; that agent-to-agent prompts start with
   `[from <role>]` and anything untagged is the user; that `workspace_management/` at the worktree
   root is the agents' handoff dir, never committed (excluded via `.git/info/exclude`, never the
   tracked `.gitignore`); that delegation goes only through Paseo `create_agent`, never the harness's
   in-process subagent tool (name it: Claude Code `Agent`/`Task`; Codex Subagents).
3. **Working with the user** — the preferences, carried in substance: headline + `N of M done · next:`
   counted from a fixed step list (Paseo sessions have no task-list tool), one question per message
   through the harness's question tool, silence is never a decision, restate before acting, surface
   every shortcut/guess/scope change, one shippable unit per workspace, a three-line "how it works
   now" plus the manual test guide when it ships.
4. **Testing on this Mac** — from §1: the isolation recipe for a test copy (own data and prefs, own
   bundle id or port), which commands kill or restart the installed app and must never be run against
   it, whether automation hooks reach every running copy, what tests write to shared state; the lock
   (`<git common dir>/agent-live.lock`, one live pass per repo at a time); bursts under ten seconds
   after five idle seconds, everything put back; never the user's installed app or real preferences.
5. **Ship rule** — the preferences' QA-gated rule, mapped onto this repo's delivery path (§5), and
   QA's proof requirement and UX check. Say that it overrides the role files' shipping lines for
   this repo. Name the exact delivery doorbell (`[from wayfinder] QA clean — deliver per AGENTS.md`),
   that the handoff folder is copied to `<git common dir>/agent-handoff/<slug>/` before any merge
   (Paseo can archive a worktree the moment its PR merges), and that a repo delivery skill's cleanup
   step is skipped: the wayfinder asks about archiving once, for its own workspace.
6. **Conventions and boundaries** — from §5: forbidden paths, deploy rules, commit/branch style, where
   tests live, how dates are taken (`date`, the Mac's clock). Only what is true for this repo.
7. **Done means** — what a finished change looks like here (tests pass, lint clean, `plan.md`
   criteria met, QA passed with proof, shipped per the ship rule).

Write for both harnesses: specific, named instructions over generic ones; say *when* to format rather
than "never format"; name the behaviours to avoid (quiet scope changes, unrequested fixes, tests where
none were asked for); tie references to scenarios ("use `docs/db.md` for schema changes") instead of
"read everything first"; state safe autonomy as permissions ("run the tests, fix failures, rerun
without approval"). A new file stays under ~120 lines. A large existing file (an upstream guide) gets
one new section, not a rewrite.

Never put in it: "think carefully" / "be thorough"; blanket anti-formatting rules; "treat
earlier answers as settled" (in agentic work it suppresses flagging earlier mistakes); a rule that
every change appends to one shared file at its top (it guarantees merge conflicts between parallel
workspaces; say so and suggest per-change files if the repo has that rule); instructions that
duplicate a role file (role behaviour lives in the role files; the config carries project facts and
the user's contract); anything that contradicts `agents.json`.

Existing file: read it fully, keep what is true, change only what must change, show the user the
diff summary, never a blind rewrite.

### `.git/info/exclude`

Append `workspace_management/` if absent (`git rev-parse --git-path info/exclude` gives the right
file, also from inside a worktree). Never edit the tracked `.gitignore` for this.

## 8. Built-in defaults (when `preferences.md` is missing)

Default roles: manager `fable-5.1` high · wayfinder `fable-5.1` high · implementor `opus-5.5` xhigh ·
qa `gpt-6-astra` high (a different model than the implementor catches more). Default effort per model:
fable-5.1 high · opus-5.5 xhigh · gpt-6-astra high. Default contract: the bullets in "Working with the
user" above plus: `N of M done` counted from a fixed step list (Paseo has no task-list tool); never
the harness subagent tool; one shippable
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

`agents.json` valid and complete for all four roles (model, effort and mode each), every
`instructions` URL fetching the file from the remote; `AGENTS.md` true for this repo with `CLAUDE.md` linked to it;
`workspace_management/` excluded; committed and pushed; the start line given with the real path,
model and effort. Your turn ends only on a question to the user, the outline (waiting for
the go), or the closing message.
