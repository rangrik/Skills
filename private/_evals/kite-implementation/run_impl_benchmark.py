#!/usr/bin/env python3
"""Run kite-implementation benchmark children serially.

This runner is intentionally local to the eval suite. It launches one Codex
child at a time, captures enough evidence for grading, and removes each
throwaway appsmith-v2 worktree after its run is graded.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path("/Users/pranavkanade/Skills")
APP_MAIN = Path("/Users/pranavkanade/kite/appsmith-v2")
WORKTREE_ROOT = Path("/private/tmp/kite-skill-evals/appsmith-impl")
SKILL_DIR = ROOT / "private/kite-implementation"
SKILL_MD = SKILL_DIR / "SKILL.md"
SUITE_DIR = ROOT / "private/_evals/kite-implementation/suite"
SUITE_JSON = SUITE_DIR / "evals.json"
RESULTS_ROOT = ROOT / "private/_evals/kite-implementation/results"
SESSIONS_DIR = Path("/Users/pranavkanade/.codex/sessions")


def run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    if check and proc.returncode:
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(cmd)}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
        )
    return proc


def slug_eval(ev: dict[str, Any]) -> str:
    return f"eval-{ev['id']}-{ev.get('name') or 'unnamed'}"


def worktree_path(iteration: int, ev: dict[str, Any], config: str, run_number: int) -> Path:
    return WORKTREE_ROOT / f"e{ev['id']}_{config}_i{iteration}_r{run_number}"


def run_dir(iteration: int, ev: dict[str, Any], config: str, run_number: int) -> Path:
    return RESULTS_ROOT / f"iteration-{iteration}" / slug_eval(ev) / config / f"run-{run_number}"


def ensure_worktree(path: Path) -> None:
    if path.exists():
        subprocess.run(["git", "-C", str(APP_MAIN), "worktree", "remove", "--force", str(path)], text=True)
        if path.exists():
            shutil.rmtree(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "-C", str(APP_MAIN), "worktree", "add", "--detach", str(path), "HEAD"])
    run(["git", "-C", str(path), "reset", "--hard", "HEAD"])
    run(["git", "-C", str(path), "clean", "-fdx"])


def remove_worktree(path: Path) -> None:
    subprocess.run(["git", "-C", str(APP_MAIN), "worktree", "remove", "--force", str(path)], text=True)
    if path.exists():
        shutil.rmtree(path)
    alt_git = path.with_suffix(".git")
    if alt_git.exists():
        shutil.rmtree(alt_git)


def copy_fixture(ev: dict[str, Any], outdir: Path) -> Path:
    fixture_rel = ev.get("files", [None])[0]
    if not fixture_rel:
        raise ValueError(f"Eval {ev['id']} has no fixture")
    fixture = SUITE_DIR / fixture_rel
    dest = outdir / Path(fixture_rel).name
    shutil.copy2(fixture, dest)
    return dest


def build_prompt(
    *,
    ev: dict[str, Any],
    config: str,
    iteration: int,
    outdir: Path,
    plan_copy: Path,
    wt: Path,
) -> str:
    skill_block = ""
    if config == "with_skill":
        skill_block = f"""
Use the kite-implementation skill for this run. The full skill text is included
here so the prompt is self-contained; treat it as authoritative for this run:

<kite_implementation_skill path="{SKILL_MD}">
{SKILL_MD.read_text()}
</kite_implementation_skill>

When this skill tells you to run architecture or scenario checks, use the
available kite-arch-compass and kite-scenario-check skills. If you spawn any
nested child agent for those checks, it must also use model gpt-5.5, reasoning
effort xhigh, and service tier priority.
"""
    else:
        skill_block = """
This is the without_skill baseline. Do not open, read, quote, or follow
private/kite-implementation/SKILL.md or any kite-implementation skill workflow.
If a skills list is visible in the session, ignore it for this baseline run.
Use only the task prompt, the plan file, and the codebase itself.
"""

    return f"""You are a benchmark child run agent for kite-implementation.

Runtime identity:
- Model: gpt-5.5
- reasoning_effort: xhigh
- service_tier: priority
- Iteration: {iteration}
- Eval: {ev['id']} ({ev.get('name')})
- Config: {config}
- Run: 1

Hard boundaries:
- Your appsmith-v2 working codebase is this throwaway worktree: {wt}
- Never touch the main appsmith-v2 checkout at {APP_MAIN}.
- Do not push.
- Do not edit SKILL.md, evals.json, suite fixtures, catalog.yaml, or any other run's outputs.
- You may modify and commit code only inside the throwaway appsmith worktree.
- Use normal `git -C {wt} ...` commands for commits. Do not run Git commands
  against the main checkout path, and do not create alternate Git repositories.
- Write benchmark artifacts only inside this output directory: {outdir}
- The mutable plan file for this run is: {plan_copy}
- The original suite fixture is read-only context; update only the plan copy in outputs.

Before coding, verify with shell commands that `pwd` is the throwaway worktree
and `git status --short` is clean.

At the end, create or overwrite {outdir}/run_report.md with:
- scenarios attempted, in order
- scenarios skipped as blocked
- exact reused research findings
- exact new extension points changed
- tests run or explicitly skipped with reason
- architecture check result per committed scenario
- scenario check result per committed scenario
- commits created
- remaining blockers or uncertainties

Also leave the updated plan copy at {plan_copy}. After writing run_report.md,
your final response should be exactly: DONE

{skill_block}

User task prompt:
{ev['prompt']}

Expected outcome, for your orientation only:
{ev.get('expected_output', '')}
"""


def codex_args(wt: Path, outdir: Path, final_path: Path, config: str) -> list[str]:
    developer = (
        "This is a with_skill benchmark child. Use the supplied kite-implementation skill text and "
        "keep all benchmark artifacts inside the requested outputs directory."
        if config == "with_skill"
        else "This is a without_skill benchmark baseline. Do not use or consult any skill, including "
        "kite-implementation, even if a skills list is visible. Complete the task as a generic coding agent."
    )
    return [
        "codex",
        "-a",
        "never",
        "exec",
        "--json",
        "-m",
        "gpt-5.5",
        "-c",
        'model_reasoning_effort="xhigh"',
        "-c",
        'service_tier="priority"',
        "-c",
        f"developer_instructions={json.dumps(developer)}",
        "--ignore-user-config",
        "--ignore-rules",
        "-s",
        "workspace-write",
        "-C",
        str(wt),
        "--add-dir",
        str(outdir),
        "--add-dir",
        str(APP_MAIN / ".git"),
        "--skip-git-repo-check",
        "-o",
        str(final_path),
        "-",
    ]


def find_session_file(thread_id: str, started_at: float) -> Path | None:
    candidates = sorted(
        (p for p in SESSIONS_DIR.rglob("*.jsonl") if p.stat().st_mtime >= started_at - 5),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for path in candidates:
        try:
            with path.open(errors="replace") as f:
                for _ in range(8):
                    line = f.readline()
                    if not line:
                        break
                    if thread_id in line:
                        return path
        except OSError:
            continue
    return None


def extract_transcript(session_path: Path | None, stdout_path: Path, transcript_path: Path) -> int:
    lines: list[str] = []
    if session_path and session_path.exists():
        with session_path.open(errors="replace") as f:
            for raw in f:
                try:
                    item = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                typ = item.get("type")
                payload = item.get("payload", {})
                if typ == "event_msg":
                    et = payload.get("type")
                    if et == "agent_message":
                        lines.append(f"ASSISTANT: {payload.get('message', '')}")
                    elif et == "exec_command_begin":
                        cmd = payload.get("cmd") or payload.get("command") or payload
                        lines.append(f"COMMAND: {cmd}")
                    elif et == "exec_command_end":
                        lines.append(f"COMMAND_RESULT: {json.dumps(payload)[:2000]}")
                    elif et == "mcp_tool_call_begin":
                        lines.append(f"MCP_TOOL: {json.dumps(payload)[:1000]}")
                    elif et == "mcp_tool_call_end":
                        lines.append(f"MCP_RESULT: {json.dumps(payload)[:1200]}")
                elif typ == "response_item":
                    rp = payload
                    if rp.get("type") == "function_call":
                        lines.append(f"TOOL_CALL: {rp.get('name')} {str(rp.get('arguments'))[:1200]}")
                    elif rp.get("type") == "message" and rp.get("role") == "assistant":
                        for block in rp.get("content", []):
                            text = block.get("text") or block.get("output_text")
                            if text:
                                lines.append(f"ASSISTANT: {text}")
    if not lines and stdout_path.exists():
        for raw in stdout_path.read_text(errors="replace").splitlines():
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if item.get("type") == "item.completed":
                text = item.get("item", {}).get("text")
                if text:
                    lines.append(f"ASSISTANT: {text}")
    transcript_path.write_text("\n\n".join(lines) + ("\n" if lines else ""))
    return sum(len(line) for line in lines)


def parse_stdout(stdout: str) -> tuple[str | None, dict[str, Any]]:
    thread_id = None
    usage: dict[str, Any] = {}
    for raw in stdout.splitlines():
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            event = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "thread.started":
            thread_id = event.get("thread_id")
        elif event.get("type") == "turn.completed":
            usage = event.get("usage") or usage
    return thread_id, usage


def git_cmd(wt: Path, args: list[str]) -> list[str]:
    alt_git = wt.with_suffix(".git")
    if alt_git.exists():
        return ["git", f"--git-dir={alt_git}", f"--work-tree={wt}", *args]
    return ["git", "-C", str(wt), *args]


def collect_git_artifacts(wt: Path, outdir: Path) -> None:
    source = f"alternate git dir: {wt.with_suffix('.git')}" if wt.with_suffix(".git").exists() else "linked worktree git metadata"
    base = run(["git", "-C", str(APP_MAIN), "rev-parse", "HEAD"], check=False).stdout.strip()
    artifacts = {
        "git_status.txt": git_cmd(wt, ["status", "--short"]),
        "git_log.txt": git_cmd(wt, ["log", "--oneline", "--decorate", "-12"]),
        "git_branch.txt": git_cmd(wt, ["branch", "--show-current"]),
        "git_diff_HEAD.patch": git_cmd(wt, ["diff", "HEAD"]),
        "git_cumulative_diff.patch": git_cmd(wt, ["diff", f"{base}..HEAD"]) if base else git_cmd(wt, ["diff", "HEAD"]),
        "git_show_stat.txt": git_cmd(wt, ["show", "--stat", "--oneline", "--no-renames", "HEAD"]),
        "git_show_patch.diff": git_cmd(wt, ["show", "--format=fuller", "--no-renames", "--find-renames=0", "HEAD"]),
    }
    for name, cmd in artifacts.items():
        proc = run(cmd, check=False)
        (outdir / name).write_text((proc.stdout or "") + (proc.stderr or ""))
    (outdir / "worktree_path.txt").write_text(str(wt) + "\n")
    (outdir / "git_artifacts_source.txt").write_text(source + "\n")


def output_char_count(outdir: Path) -> int:
    total = 0
    for path in outdir.rglob("*"):
        if path.is_file():
            try:
                total += len(path.read_text(errors="replace"))
            except OSError:
                pass
    return total


def load_texts(outdir: Path) -> dict[str, str]:
    texts: dict[str, str] = {}
    for name in [
        "run_report.md",
        "final_response.md",
        "transcript.md",
        "git_status.txt",
        "git_log.txt",
        "git_cumulative_diff.patch",
        "git_diff_HEAD.patch",
        "git_show_patch.diff",
        "git_show_stat.txt",
        "team-invites-plan.md",
        "announcement-dismissal-plan.md",
    ]:
        path = outdir / name
        if path.exists():
            texts[name] = path.read_text(errors="replace")
    return texts


def has_all(text: str, needles: list[str]) -> bool:
    low = text.lower()
    return all(n.lower() in low for n in needles)


def has_any(text: str, needles: list[str]) -> bool:
    low = text.lower()
    return any(n.lower() in low for n in needles)


def in_order(text: str, items: list[str]) -> bool:
    low = text.lower()
    pos = -1
    for item in items:
        nxt = low.find(item.lower(), pos + 1)
        if nxt == -1:
            return False
        pos = nxt
    return True


def evidence_line(source: str, text: str, needles: list[str]) -> str:
    low_needles = [n.lower() for n in needles]
    for line in text.splitlines():
        lline = line.lower()
        if any(n in lline for n in low_needles):
            return f"{source}: {line[:500]}"
    return f"{source}: evidence not found"


def grade_expectation(ev_id: int, expectation: str, texts: dict[str, str]) -> tuple[bool, str]:
    combined = "\n".join(texts.values())
    patch = texts.get("git_show_patch.diff", "") + "\n" + texts.get("git_diff_HEAD.patch", "")
    plan = texts.get("team-invites-plan.md", "") + texts.get("announcement-dismissal-plan.md", "")
    report = texts.get("run_report.md", "") + "\n" + texts.get("transcript.md", "")
    exp = expectation.lower()

    if "live appsmith-v2" in exp or "live appsmith-v2 repository" in exp:
        passed = has_any(combined, ["worktree_path", "appsmith-v2", "backend/app/"]) and (
            bool(patch.strip()) or has_any(report, ["commit", "implemented", "blocked"])
        )
        return passed, evidence_line("combined", combined, ["appsmith-v2", "backend/app/", "worktree"])

    if "plan order" in exp or "processes the remaining scenarios in plan order" in exp:
        passed = in_order(report + "\n" + plan, ["S1", "S2", "S3"]) and not re.search(
            r"S3[\s\S]{0,200}before[\s\S]{0,200}S1", report, re.I
        )
        return passed, evidence_line("report/plan", report + "\n" + plan, ["S1", "S2", "S3"])

    if "resumable state machine" in exp:
        passed = has_any(report + plan, ["resume", "already marked committed", "first non-committed", "no scenarios were already committed"])
        return passed, evidence_line("report/plan", report + "\n" + plan, ["committed", "resume", "first non-committed"])

    if "vertical" in exp:
        if ev_id in (1, 2):
            passed = has_any(patch, ["backend/app/routes"]) and has_any(
                patch, ["backend/app/models", "backend/app/migrations"]
            ) and has_any(patch + report, ["service", "workspace_membership", "route"])
        else:
            passed = has_all(patch, ["announcement_routes.py", "announcement_db.py"]) and has_any(
                patch, ["announcement_dismissal.py", "migrations"]
            )
        return passed, evidence_line("patch/report", patch + "\n" + report, ["routes", "models", "migrations", "announcement_db"])

    if "require_workspace_admin" in exp or "workspace_membership" in exp:
        passed = has_all(combined, ["require_workspace_admin", "enqueue_email", "WorkspaceMembershipService.add_member"])
        return passed, evidence_line("combined", combined, ["require_workspace_admin", "enqueue_email", "WorkspaceMembershipService"])

    if "missing extension points" in exp and ev_id in (1, 2):
        passed = has_any(patch, ["invitation.py", "invitations"]) and has_any(
            patch, ["migrations", "create index", "unique"]
        ) and has_any(patch + report, ["accept", "invitation_routes.py", "accept-invite"])
        return passed, evidence_line("patch/report", patch + "\n" + report, ["invitation", "unique", "accept"])

    if "announcement model" in exp or "announcement data layer" in exp or "session_manager.get_current_user" in exp:
        passed = has_all(combined, ["announcement.py", "announcement_db.py", "announcement_routes.py"]) and has_any(
            combined, ["session_manager.get_current_user", "get_current_user()"]
        )
        return passed, evidence_line("combined", combined, ["announcement.py", "announcement_db.py", "get_current_user"])

    if "announcement_dismissals model" in exp or "dismiss endpoint" in exp:
        passed = has_any(patch, ["announcement_dismissal.py", "announcement_dismissals"]) and has_any(
            patch, ["unique", "user_id", "announcement_id"]
        ) and has_any(patch, ["announcement_routes.py"])
        return passed, evidence_line("patch", patch, ["announcement_dismissal", "unique", "announcement_routes"])

    if "authenticated-only" in exp or "anonymous caller" in exp:
        passed = has_any(combined, ["get_current_user", "authenticated", "anonymous", "401", "unauthorized"])
        return passed, evidence_line("combined", combined, ["get_current_user", "anonymous", "authenticated", "401"])

    if "dismissed announcement is hidden" in exp or "user-aware" in exp or "timeout" in exp:
        passed = has_any(combined, ["dismissed", "user-aware", "dismissal"]) and has_any(
            combined, ["timeout", "anonymous", "no-user", "no user"]
        )
        return passed, evidence_line("combined", combined, ["dismissed", "timeout", "anonymous"])

    if "double-dismiss" in exp or "repeat dismiss" in exp:
        passed = has_any(combined, ["double", "repeat", "idempotent", "unique"]) and has_any(
            combined, ["user_id", "announcement_id", "announcement_dismissals"]
        )
        return passed, evidence_line("combined", combined, ["idempotent", "unique", "double", "repeat"])

    if "tests selectively" in exp or "tests selective" in exp:
        if ev_id in (1, 2):
            passed = has_any(patch + report, ["test"]) and has_any(
                patch + report, ["admin", "authorization", "double", "re-invit", "reinvite", "idempotent"]
            )
        else:
            passed = has_any(patch + report, ["test"]) and has_any(
                patch + report, ["authenticated", "dismissed", "double", "idempotent"]
            )
        return passed, evidence_line("patch/report", patch + "\n" + report, ["test", "authorization", "idempotent", "double"])

    if "kite-arch-compass" in exp or "architecture check" in exp:
        passed = has_any(report, ["kite-arch-compass", "architecture check"]) and has_any(report, ["pass", "passed", "no violation"])
        return passed, evidence_line("report", report, ["kite-arch-compass", "architecture check", "pass"])

    if "kite-scenario-check" in exp or "scenario-check" in exp:
        passed = has_any(report, ["kite-scenario-check", "scenario check", "scenario-check"]) and has_any(
            report, ["pass", "passed"]
        ) and not has_any(report, ["committed despite fail", "committed on fail"])
        return passed, evidence_line("report", report, ["kite-scenario-check", "scenario check", "pass", "fail"])

    if "skips scenario s4" in exp or "blocked scenario s4" in exp:
        passed = has_any(report + plan, ["S4", "blocked"]) and has_any(report + plan, ["skip", "skipped", "not implement", "needs re-planning", "re-plan"])
        return passed, evidence_line("report/plan", report + "\n" + plan, ["S4", "blocked", "skip", "re-plan"])

    if "implementation record" in exp:
        passed = has_any(plan + report, ["Implementation record", "changed files", "architecture-check", "scenario-check", "commit"]) and has_any(
            plan + report, ["committed"]
        )
        return passed, evidence_line("plan/report", plan + "\n" + report, ["Implementation record", "commit", "committed"])

    passed = has_any(combined, expectation.split()[:5])
    return passed, evidence_line("combined", combined, expectation.split()[:3])


def grade_run(ev: dict[str, Any], outdir: Path, timing: dict[str, Any]) -> dict[str, Any]:
    texts = load_texts(outdir)
    graded = []
    for expectation in ev.get("expectations", []):
        passed, evidence = grade_expectation(ev["id"], expectation, texts)
        graded.append({"text": expectation, "passed": passed, "evidence": evidence})
    passed_count = sum(1 for g in graded if g["passed"])
    failed_count = len(graded) - passed_count
    metrics_path = outdir / "metrics.json"
    metrics = {
        "tool_calls": {},
        "total_tool_calls": 0,
        "total_steps": 0,
        "errors_encountered": 0,
        "output_chars": output_char_count(outdir),
        "transcript_chars": len(texts.get("transcript.md", "")),
    }
    metrics_path.write_text(json.dumps(metrics, indent=2) + "\n")
    return {
        "expectations": graded,
        "summary": {
            "passed": passed_count,
            "failed": failed_count,
            "total": len(graded),
            "pass_rate": round(passed_count / len(graded), 4) if graded else 0.0,
        },
        "execution_metrics": metrics,
        "timing": {
            "executor_duration_seconds": timing.get("total_duration_seconds", 0.0),
            "total_duration_seconds": timing.get("total_duration_seconds", 0.0),
        },
        "claims": [],
        "user_notes_summary": {"uncertainties": [], "needs_review": [], "workarounds": []},
        "eval_feedback": {"suggestions": [], "overall": "Inline deterministic grading; no eval-structure suggestions."},
    }


def write_eval_metadata(iteration: int, ev: dict[str, Any]) -> None:
    eval_dir = RESULTS_ROOT / f"iteration-{iteration}" / slug_eval(ev)
    eval_dir.mkdir(parents=True, exist_ok=True)
    metadata = {
        "eval_id": ev["id"],
        "eval_name": ev.get("name") or slug_eval(ev),
        "prompt": ev["prompt"],
        "expectations": ev.get("expectations", []),
    }
    (eval_dir / "eval_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


def run_child(iteration: int, ev: dict[str, Any], config: str, run_number: int) -> None:
    rdir = run_dir(iteration, ev, config, run_number)
    outdir = rdir / "outputs"
    if rdir.exists():
        shutil.rmtree(rdir)
    outdir.mkdir(parents=True, exist_ok=True)
    wt = worktree_path(iteration, ev, config, run_number)
    print(f"RUN iteration-{iteration} eval-{ev['id']} {config} run-{run_number}", flush=True)
    ensure_worktree(wt)
    plan_copy = copy_fixture(ev, outdir)
    prompt = build_prompt(ev=ev, config=config, iteration=iteration, outdir=outdir, plan_copy=plan_copy, wt=wt)
    (outdir / "prompt.md").write_text(prompt)
    final_path = outdir / "final_response.md"
    stdout_path = outdir / "codex_stdout.jsonl"
    stderr_path = outdir / "codex_stderr.txt"

    args = codex_args(wt, outdir, final_path, config)
    start = time.time()
    started_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        proc = subprocess.run(args, input=prompt, text=True, capture_output=True, timeout=5400)
        timed_out = False
    except subprocess.TimeoutExpired as exc:
        proc = subprocess.CompletedProcess(args, 124, stdout=exc.stdout or "", stderr=exc.stderr or "Timed out")
        timed_out = True
    duration = time.time() - start
    stdout = proc.stdout or ""
    stderr = proc.stderr or ""
    stdout_path.write_text(stdout)
    stderr_path.write_text(stderr)

    thread_id, usage = parse_stdout(stdout)
    session_path = find_session_file(thread_id, start) if thread_id else None
    if session_path:
        shutil.copy2(session_path, outdir / "codex_session.jsonl")
    transcript_chars = extract_transcript(session_path, stdout_path, outdir / "transcript.md")
    collect_git_artifacts(wt, outdir)

    total_tokens = int(usage.get("total_tokens") or (int(usage.get("input_tokens", 0)) + int(usage.get("output_tokens", 0))))
    timing = {
        "total_tokens": total_tokens,
        "duration_ms": int(duration * 1000),
        "total_duration_seconds": round(duration, 1),
        "started_at": started_iso,
        "thread_id": thread_id,
        "returncode": proc.returncode,
        "timed_out": timed_out,
        "transcript_chars": transcript_chars,
    }
    (rdir / "timing.json").write_text(json.dumps(timing, indent=2) + "\n")

    if proc.returncode != 0 or timed_out:
        note = outdir / "user_notes.md"
        existing = note.read_text(errors="replace") if note.exists() else ""
        note.write_text(
            existing
            + f"\nRun process returned {proc.returncode}; timed_out={timed_out}. See codex_stderr.txt and transcript.md.\n"
        )

    grading = grade_run(ev, outdir, timing)
    (rdir / "grading.json").write_text(json.dumps(grading, indent=2) + "\n")
    print(
        f"DONE iteration-{iteration} eval-{ev['id']} {config}: "
        f"pass_rate={grading['summary']['pass_rate']:.2f} rc={proc.returncode} dur={duration:.1f}s tokens={total_tokens}",
        flush=True,
    )
    remove_worktree(wt)


def regrade_existing(iteration: int, ev: dict[str, Any], config: str, run_number: int) -> None:
    rdir = run_dir(iteration, ev, config, run_number)
    outdir = rdir / "outputs"
    if not outdir.exists():
        raise RuntimeError(f"Missing output directory: {outdir}")
    wt = worktree_path(iteration, ev, config, run_number)
    if wt.exists() or wt.with_suffix(".git").exists():
        collect_git_artifacts(wt, outdir)
    timing_path = rdir / "timing.json"
    timing = json.loads(timing_path.read_text()) if timing_path.exists() else {"total_duration_seconds": 0.0}
    grading = grade_run(ev, outdir, timing)
    (rdir / "grading.json").write_text(json.dumps(grading, indent=2) + "\n")
    print(
        f"REGRADED iteration-{iteration} eval-{ev['id']} {config}: "
        f"pass_rate={grading['summary']['pass_rate']:.2f}",
        flush=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iteration", type=int, required=True)
    parser.add_argument("--configs", nargs="*", default=["with_skill", "without_skill"])
    parser.add_argument("--run-number", type=int, default=1)
    parser.add_argument("--eval-id", type=int, action="append", default=[])
    parser.add_argument("--regrade-existing", action="store_true")
    args = parser.parse_args()

    if args.iteration not in (1, 2, 3):
        raise SystemExit("--iteration must be 1, 2, or 3")
    data = json.loads(SUITE_JSON.read_text())
    for ev in data["evals"]:
        if args.eval_id and ev["id"] not in args.eval_id:
            continue
        write_eval_metadata(args.iteration, ev)
        for config in args.configs:
            if args.regrade_existing:
                regrade_existing(args.iteration, ev, config, args.run_number)
            else:
                run_child(args.iteration, ev, config, args.run_number)
    if args.regrade_existing:
        print(f"ALL EXISTING RUNS REGRADED iteration-{args.iteration}", flush=True)
    else:
        print(f"ALL CHILD RUNS COMPLETE iteration-{args.iteration}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
