# LLM Orchestrator Architecture Research

_Last researched: 2026-05-23. Scope: `backend/app/llm` LLM, orchestrator, agent generation, skill/tool, sandbox, QA/SEO/image, and regression surfaces._

## 1. Executive summary

Kite's LLM system is a hub-and-spoke architecture. The **Orchestrator Agent** owns the user conversation and delegates side effects through tools; specialized agents/routines/services own implementation details such as website creation, editing, QA, SEO, image generation, and channel routing. The most important maintainability pattern is **context diet by progressive disclosure**: the always-loaded system prompt has global flow rules and a dynamic skill catalog, while detailed capability instructions live in `backend/app/llm/skills/*/SKILL.md` and are loaded with `invoke_skill` only when needed.

High-value source anchors:

- Taxonomy is explicit in `backend/docs/rules/module-taxonomy.md`: markdown bundles are **Skills**; deterministic/non-LLM code is **Services**; single bounded model calls are **LLM Routines**; iterative tool loops or delegated OpenCode runs are **Agents**; callable adapters exposed to an agent are **Tools** (`module-taxonomy.md:6-21`, `:34-40`, `:49-63`).
- The Orchestrator entrypoint is `process_chat_message()` and the tool loop is `run_orchestrator_agentic_loop()` in `backend/app/llm/orchestrator_agent/__init__.py:683` and `:1294`.
- LLM calls centralize in `backend/app/llm/infra/llm_service.py`, which states that all chat/completion calls route through OpenRouter for tracking/billing (`llm_service.py:6`, `:567`, `:1056`, `:1607`).
- Sandbox code/editing flows centralize in `backend/app/llm/infra/opencode_cli.py`; its module doc calls it the only OpenCode CLI runner and describes the metadata proxy boundary (`opencode_cli.py:1-15`).
- Tool results use the typed `ToolResult` / `ToolError` contract in `backend/app/llm/infra/types.py:6-15`.

## 2. Taxonomy and ownership rules

The repo has a clear module taxonomy and naming convention:

| Category | Definition / ownership | Examples in `backend/app/llm` |
| --- | --- | --- |
| Skill | Reusable markdown instruction bundle in agentskills.io layout. Prefer extending a skill before adding new code when the need is instruction/routing guidance. | `skills/website-create/SKILL.md`, `skills/images/SKILL.md`, `skills/qa-review/SKILL.md` |
| Service | Deterministic, non-LLM business logic. | `app/services/prompt_service.py`, `workpad_service`, `checkpointing_service` |
| LLM Routine | Bounded single model call without a tool loop. | Content/name/memory routines; QA video evaluator is LLM-routine-like once sandbox data is collected. |
| Agent | LLM/tool loop or delegated iterative tool use, including OpenCode sandbox runs. | `orchestrator_agent`, `platform_router_agent`, `coding/website_change_agent`, `product/discoverability_analysis_agent`, `coding/discoverability_improvement_agent` |
| Tool | Thin callable adapter exposed to an agent. It validates input, delegates to one primary callee, and translates result. | `orchestrator_agent/tools/*`, `skills/*/tools/*` |

Important rule docs:

- `backend/docs/rules/orchestrator-tools.md:11-14` says tools should validate, delegate to one primary callee, and avoid accumulating business logic.
- Tool guidance has one authoritative layer: docstring for argument/return contract, `SKILL.md` body for workflow use, skill frontmatter `description` for routing triggers, and system prompt for cross-cutting flow (`orchestrator-tools.md:18-29`, `:37-51`).
- New skill/tool code belongs under `app/llm/skills/<skill-name>/tools/`, while baseline always-available infrastructure remains in `app/llm/orchestrator_agent/tools/` (`orchestrator-tools.md:3-7`, `:64-84`).
- `backend/docs/rules/skills-authoring.md:61-69` reinforces: start with a skill, one concern per skill, move deterministic logic to services/tools, and split branching/recovery-heavy markdown into service/agent code.

## 3. Orchestrator core loop and model flow

### Entrypoint and model config

`process_chat_message()` (`orchestrator_agent/__init__.py:1294`) handles DB/thread concerns, attachment validation, `workflow_context` construction, history loading, memory preload, cancellation watch, final SSE publication, checkpointing, and UI block publication. It calls `_run_orchestrator_with_cancel_watch()` then `run_orchestrator_agentic_loop(..., max_iterations=15)` (`orchestrator_agent/__init__.py:1410-1421`).

`get_orchestrator_model()` (`orchestrator_agent/__init__.py:312-340`) configures:

- primary `LLMModel.GPT_5_4`, `max_tokens=50000`, `reasoning_effort="low"`, `temperature=0.5`, `use_responses_api=False`;
- fallbacks `LLMModel.GPT_5` then `LLMModel.CLAUDE_SONNET_4_6` with tools bound to each fallback.

`llm_service.generate_response()` and `stream_response()` build a primary-plus-fallback chain and log `fallback_chain` metadata (`llm_service.py:1056-1186`, `:1607-1819`). Streaming has an explicit TODO that circuit-breaker filtering is not yet applied to streaming (`llm_service.py:1686-1687`), unlike non-streaming (`llm_service.py:1152-1153`).

### Loop shape

`run_orchestrator_agentic_loop()` (`orchestrator_agent/__init__.py:683`) does this each iteration:

1. Fetch/normalize website state into `workflow_context` so tool filtering has phase information (`:718-743`).
2. Load static orchestrator prompt via `load_orchestrator_system_prompt()` (`:383-394`). The prompt injects a dynamic skill catalog built from SKILL.md frontmatter (`:342-381`).
3. Rehydrate skill state from prior successful `invoke_skill` calls: `_rehydrate_unlocked_tools()` (`:197-225`) and `_rehydrate_active_skill()` (`:227-256`).
4. Filter visible tools via `get_filtered_tools()` (`context.py:158-232`).
5. Invoke the LLM with streaming in `invoke_orchestrator()` (`__init__.py:396-585`).
6. If there are no tool calls, publish `Done` and return (`:767-774`).
7. If there are tool calls, strip illegal UI blocks from intermediate turns (`:784-799`), publish in-progress notifications (`:809-815`), persist the `tool_request`, commit, execute all tools in parallel with `asyncio.gather()` (`:973-980`), persist `tool_response` rows, and append the AI/tool messages to in-memory history (`:1036-1052`).

The loop also guards provider history issues: `invoke_orchestrator()` catches OpenAI `BadRequestError` for missing tool outputs, injects synthetic `ToolMessage` rows for missing call IDs, and retries (`__init__.py:489-527`). If it cannot recover, it publishes the exact fallback user message `We ran into a temporary issue while generating your response. This should resolve shortly — please try again in a few seconds.` (`__init__.py:76`, `:528-537`).

## 4. State, context, memory, UI blocks

### Hidden workflow state

Tools receive request-scoped state through a `ContextVar`, not through LLM-visible tool arguments:

- `current_workflow_context` is declared in `tools/_base.py:28`.
- `get_workflow_context()` returns it and raises if no context is set (`tools/_base.py:31-44`).
- `process_chat_message()` populates `workflow_context` with `application_id`, `website_id`, `thread_id`, `creator_id`, `creator_email`, `message_id`, `working_directory`, `source_channel`, and `task_started_at` (`orchestrator_agent/__init__.py:1373-1397`).

This is a strong boundary: the LLM supplies business arguments; tools pull platform identifiers and filesystem locations from hidden context.

### Context trimming and memory

Current source code constants in `context.py` are:

- `MEMORY_QUERY_MAX_MESSAGES = 5`, `MEMORY_QUERY_MAX_CHARS = 5000`, `MEMORY_TOP_K = 10` (`context.py:28-37`).
- `CONTEXT_RESET_TOKEN_THRESHOLD = 40_000`, `CONTEXT_RESET_USER_MESSAGE_COUNT = 10` (`context.py:43-46`).
- `OBSERVER_CONTENT_TOKEN_THRESHOLD = 5_000` (`context.py:50`).

`trim_messages_if_needed()` trims only after response usage exceeds the threshold, persists `thread.context_window_start_id`, and drops leading orphan `ToolMessage`s (`context.py:53-128`). `preload_memory_context()` retrieves Mem0 memories only after the website is generated, formats them as a `SystemMessage`, and injects just before the latest user message to preserve prompt caching (`context.py:348-468`). `trigger_observer_if_needed()` dispatches an observer after 5k content tokens and dedupes with `workflow_context["observer_dispatched"]` (`context.py:260-334`).

Note: `agent-context/context-maps/*` contains some stale values (for example older 60k threshold/model descriptions). For current behavior, prefer the source code above.

### UI blocks

Render-only UI belongs in text tags, not tools, per `agent-prompt-guide.md:120-134`. The Orchestrator supports:

- `<kite-options>`
- `<kite-suggestions>`
- `<kite-tiles>`
- `<kite-checkpoint-list />`

`ui_blocks.py` owns tag constants, regex extraction, validation, and streaming-strip helpers (`ui_blocks.py:1-16`, `:27-66`, `:83-191`). Raw UI JSON is stripped from streamed display via `StreamTextState.display_text` (`schemas.py:15-40`) and `strip_ui_blocks_for_display()` (`ui_blocks.py:193-236`). Intermediate tool-calling turns are not allowed to carry UI blocks; if the model emits one, the loop strips it before DB persistence and history append (`orchestrator_agent/__init__.py:784-799`).

The final user-visible refinement delimiter is `---eor---`; streaming hides it, while final post-processing splits it so confirmation can publish before a follow-up (`streaming.py:86-155`, `utils.py` via `split_response_at_delimiter`, tests at `backend/tests/test_services/test_orchestrator.py:1678-1812`).

## 5. Skill-gated tool system

### Catalog and activation

The skill catalog lives in `tools/_base.py:65-123`:

- `external-extraction`: unlocks logo extraction/application, brand/assets extraction, URL fetch, web search, and clear operations.
- `logo-management`: unlocks logo upload/apply/delete.
- `qa-review`: unlocks `trigger_qa_agent`.
- `linkedin-import`: unlocks profile/posts fetch and `generate_designs`.
- `website-create`: unlocks `generate_designs`.
- `images`: intentionally unlocks no tools because `bash` is baseline; `invoke_skill` loads recipes/policy only.
- `scrape`: unlocks `scrape_website` and `remove_section_from_spec`.
- `website-analytics`: unlocks analytics read.

`invoke_skill()` validates all requested skill names, batches multiple names, dedupes skill files, loads skill bodies through `prompt_service.load_skills(..., agent="orchestrator")`, and returns the combined instructions plus unlocked tool names (`invoke_skill.py:26-112`). Prior successful invokes are rehydrated across turns (`orchestrator_agent/__init__.py:197-256`) and unit-tested in `backend/tests/test_llm/test_invoke_skill.py:261-424`.

`get_filtered_tools()` hides all skill-gated tools until unlocked, auto-includes `generate_designs` in design phase, and hides `trigger_coding_agent` before design selection unless the website is already generated (`context.py:158-232`).

### Dynamic imports and progressive disclosure

Skill-backed Python tools are loaded dynamically because skill directory names contain hyphens (`tools/__init__.py:28-53`). Baseline tools are imported directly and are always available (`tools/__init__.py:55-79`); skill-backed tools are then loaded from `llm/skills/<skill>/tools/*` (`tools/__init__.py:85-101`).

`read_skill_file()` exists because skill bodies can link deeper reference files; it restricts reads to a skill directory, rejects traversal/absolute path escapes, caps output at 50KB, and returns typed errors (`read_skill_file.py:1-15`, `:22-123`). This supports the external-system grammar rule: grammar such as curl recipes, URL parameters, and provider constraints should live in skills, not duplicated in the global prompt (`agent-prompt-guide.md:136-138`).

## 6. Tool contracts, notifications, and error handling

All orchestrator tools must return `ToolResult` (`orchestrator-tools.md:144-147`; `infra/types.py:6-15`). Recovery ownership is documented in `backend/docs/rules/error-handling.md:68-80`: services handle validation/transport retries, routines handle output validation/fallback, agents handle sub-step retries/partial completion, tools convert outcomes to `ToolResult`, and the Orchestrator handles user escalation.

`TOOL_NOTIFICATION_ACTIONS` is mandatory registry state (`tools/_base.py:128-166`). `register_tool()` fails fast if a tool has no notification entry (`tools/_base.py:250-292`). Notifications are centralized: tools do not publish UI notifications directly. This is documented (`orchestrator-tools.md:136-140`) and enforced by `test_tools_do_not_publish_notifications_directly()` (`backend/tests/test_services/test_orchestrator.py:2826-2852`).

The loop publishes `in_progress` before execution and a final `completed` or `failed` status after execution (`orchestrator_agent/__init__.py:809-815`, `:850-957`). A `ToolResult(status="error")` maps to final notification status `failed`, guarded by `backend/tests/test_services/test_orchestrator.py:2352-2439`.

`_sanitize_tool_result()` strips internal metadata keys such as `used_fallback`, `model`, `provider_path`, `complexity`, `rawRequest`, `provider`, and `fallback_model` before tool outputs re-enter the LLM context; it also redacts host/path/env-var details (`orchestrator_agent/__init__.py:79-134`).

## 7. Website creation and editing pipeline

### Design generation

`website-create` skill unlocks `generate_designs`. The tool requires a list of exactly three slots, each `DesignSpec` or `null` (`skills/website-create/tools/generate_designs.py:20-67`). It delegates to `website_create_opencode.run()` and translates service status into `ToolResult`: `design_generation_failed` on error, `partial` with warnings when some slots fail, and success otherwise (`generate_designs.py:108-146`).

`website_create_opencode/service.py` orchestrates generation/remix. It initializes the website directory, workpad requirements, Neon DB in background, name generation, state transitions, per-iteration brand strictness, sandbox initialization, and then starts each non-null design in parallel (`service.py:164-354`). It returns exact status messages for no attempts, all failed, partial, and success (`service.py:610-635`).

`website_create_opencode/generation.py` writes large inputs to sandbox files instead of command args to avoid E2B argv/env limits (`generation.py:1-8`). It runs the unified coding agent with `CodingAgentConfig` (`generation.py:304-333`) and raises important loud errors:

- `opencode failed while updating docs/{iter_name}/prototype/index.html (...)` when OpenCode itself fails (`generation.py:334-338`).
- `opencode did not produce docs/{iter_name}/prototype/index.html (...)` when HTML readback is empty/missing (`generation.py:379-385`).

### Design selection and refinement

`select_design()` validates the design number, disallows draft worktrees, checks prototype existence for HTML apps, sets website state to edit, stores `selected_iteration`, runs design-selection side effects, updates `workflow_context`, and returns `Design {n} selected. Website is now in edit state.` (`select_design.py:27-145`, `:185-189`).

After selection, edits route through `trigger_coding_agent()` (`tools/trigger_coding_agent.py:50-222`). It blocks dangerous proxy/credential/server requests with `_is_dangerous_request()` (`:18-36`, `:107-124`), blocks pre-selection edits with `design_not_selected` (`:38-46`, `:126-143`), builds `RunWorkflowParams`, then delegates to `coding/website_change_agent.run()` (`:176-183`).

`coding/website_change_agent.run()` provisions/syncs the app directory, resolves the design spec, checks cancellation before provisioning, and delegates to the unified coding agent (`website_change_agent/__init__.py:416-552`). The underlying `_run_cli_edit()` handles sandbox lifecycle, working dir selection, vision model upgrade for image reference tasks, model fallback chain, sync back, last-edited timestamp, screenshot capture, and result shaping (`website_change_agent/__init__.py:197-399`). Successful results distinguish `edit_outcome="no_changes_needed"` from `"applied"` based on actual modified-file counts (`:349-376`).

`coding/agent.py` is the shared coding-agent runner. It loads/saves OpenCode sessions, writes `.opencode/agents/coding.md` as the system prompt, renders user prompt separately, retries stale sessions/transient errors, can restart sandbox processes, and walks model fallback chains on `model-unavailable` only (`coding/agent.py:1-6`, `:83-158`, `:311-536`).

## 8. Sandbox-agent boundary and security

`opencode_cli.py` is the key boundary. It:

- routes OpenCode provider calls through a sandbox metadata proxy to OpenRouter/Langfuse/Metronome (`opencode_cli.py:1-15`, `:322-324`, `:1042-1067`);
- enforces protected file globs for edit/write, including `api/**`, `.opencode/**`, `.claude/**`, `.cursor/**`, `workpad.json`, server/proxy/relay files, package/lock files, Caddy/Procfile, etc. (`opencode_cli.py:354-392`);
- writes runtime `.opencode/opencode.json` per invocation with model, permissions, compaction, provider config, and optional MCP servers (`opencode_cli.py:397-430`, tests at `test_opencode_cli.py:112-134`);
- pushes sandbox-mode skills into `.opencode/skills` before each run and removes excluded stale skill dirs (`opencode_cli.py:1185-1219`);
- tees OpenCode NDJSON to an EFS log and tails it in near-real-time, parsing assistant messages, sessions, tool file modifications, protected-file refusals, terminal errors, and output-token counts (`opencode_cli.py:1279-1340`, `:1760-1938`);
- kills remote OpenCode if cancellation interrupts the run (`opencode_cli.py:935-950`, `:1302-1322`).

The security doc backs this with shared policy: agents build marketing websites in `frontend/`, must reject proxy/relay/credential/server infrastructure, must not reveal env var names/ports/sandbox paths/internal tool names, and implementation points include `_is_dangerous_request()`, `_redact_sensitive_content()`, and `_PROTECTED_FILE_GLOBS` (`backend/docs/rules/agent-security.md:9-24`, `:34-42`, `:58-61`).

## 9. Agentic skills, images, shared HTTP tools

There are two sandbox-capability paths:

1. **Curl-shaped skill through baseline `bash`**. `bash` runs a command inside the website's E2B sandbox with `BACKEND_API_URL`, `INTERNAL_API_TOKEN`, and `APPLICATION_ID` injected; output is capped at 10,000 chars (`tools/bash.py:1-16`, `:38-157`). The `images` skill uses this path.
2. **Agentic skill through OpenCode subagent**. `run_skill_in_opencode_subagent()` provisions the per-website sandbox, dispatches `skill_subagent.run_skill()`, and returns only a typed digest to the Orchestrator (`run_skill_in_opencode_subagent.py:1-19`, `:34-149`). The subagent reads `.opencode/skills/<skill>/SKILL.md`, executes the skill, and parses the final assistant message as JSON (`infra/skill_subagent.py:1-20`, `:90-238`).

`skills/images/SKILL.md` is `mode: sandbox`, has `notification_title: "Working on images"`, and adds an orchestrator policy (`SKILL.md:1-8`). Its recipes call `/api/v1/internal/shared-tools/images/generate`, `/edit`, `/remove-background`, and `/design-spec` (`SKILL.md:10-140`). `orchestrator-policy.md` owns phase gating, the 3-variation rule, design-spec coherence, image editing vs CSS/crop decisions, and the render-and-confirm handoff (`orchestrator-policy.md:1-46`).

Shared routes live under `/internal/shared-tools` in `backend/app/routes/shared_tool_routes.py:44-151`. They authenticate with `INTERNAL_API_TOKEN` and delegate to deterministic services, especially `design/image_generator.py` (`shared_tool_routes.py:1-16`, `:47-151`). `image_generator.generate_images_from_request()` maps requests to image generation inputs, calls `generate_multiple_images_and_save`, applies logo URL trimming, and returns per-request successes/errors (`image_generator.py:547-611`).

## 10. QA and SEO capabilities

### QA

`qa-review` skill tells the Orchestrator to call `trigger_qa_agent`, then present `issues` verbatim and ask `Would you like me to fix these issues?` (`skills/qa-review/SKILL.md:1-24`). `trigger_qa_agent()` returns cached reports, marks in-progress background QA as requested, or runs a fresh evaluation (`trigger_qa_agent.py:31-132`, `:136-255`). It returns `partial` when still running, `success` with `issues` and `issue_count`, and typed `qa_error` on evaluator failure.

`coding/qa/evaluator.py` collects browser data via Playwright in the sandbox, runs deterministic link checks, runs Gemini video evaluation, and persists `qa_snapshot.json`, `video.mp4`, and `video_mobile.mp4` under `docs/{iteration}/qa/` (`evaluator.py:1-14`, `:330-357`, `:430-448`, `:720-754`). It can replay LLM evaluators from snapshots (`evaluator.py:179-210`).

### SEO / discoverability

`analyze_seo_agent()` calls `product/discoverability_analysis_agent.run()` and sets `workflow_context["suppress_final_response"]` because the rich score card is published via SSE (`analyze_seo_agent.py:1-37`). The analysis agent runs OpenCode on the sandbox, parses the final assistant JSON, validates `DiscoverabilityAnalysisLLMResponse`, persists the result, and publishes `ChatStreamDiscoverabilityReport` (`product/discoverability_analysis_agent/__init__.py:1-12`, `:217-319`, `:371-447`).

`improve_seo_agent()` calls `coding/discoverability_improvement_agent.run()` and also suppresses final Orchestrator text (`improve_seo_agent.py:1-47`). Improvement gathers AI/PageSpeed issues, runs analysis first if needed, skips with `No discoverability issues found. Your website is already optimized.` when no issues exist, applies fixes through OpenCode, syncs files back, captures a screenshot, and re-analyzes (`discoverability_improvement_agent/__init__.py:1-8`, `:330-454`, `:482-604`). The prompt hard-limits edits to `frontend/src/index.html`, `frontend/public/robots.txt`, and `frontend/public/sitemap.xml`, with no visual/runtime changes (`coding/discoverability_improvement_agent/user-prompt.md:1-23`).

## 11. Platform Router boundary

Inbound channel messages can hit the **Platform Router Agent** before the Orchestrator. `run_router()` is pure decision-making with no DB writes except reads (`platform_router_agent/__init__.py:1-12`, `:101-164`). It renders stable system prompt plus dynamic context, builds router tools, and calls `run_loop()`.

`platform_router_agent/loop.py` uses GPT-5 Mini, `tool_choice="required"`, `max_tokens=1024`, and max 3 iterations by default (`loop.py:33-43`, `:45-153`). The only internal loop tool is `search_websites`; terminal tools become typed `RouterOutcome`s (`tools.py:1-14`, `:42-67`, `:203-253`). If the LLM fails, emits no tool call, returns bad args, or exhausts max iterations, the safe fallback is `ForwardToOrchestrator()` (`loop.py:88-103`, `:130-153`).

## 12. Cancellation, Stop, checkpointing, drafts

There are two cancellation paths:

- Cooperative checkpoints via `_raise_if_cancelled()` between loop phases (`orchestrator_agent/__init__.py:588-616`).
- Immediate cancel-watch via `_run_orchestrator_with_cancel_watch()`, which races the loop against Redis cancel flag polling and cancels the coroutine mid-tool (`:630-681`). OpenCode kills the remote process on `CancelledError` (`opencode_cli.py:1302-1322`).

The terminate endpoint finalizer is `finalize_terminated_run()` in `termination.py:190-264`. It is intentionally idempotent: writes synthetic `tool_response` rows for orphaned in-flight tool calls, writes a short stopped assistant message, optionally publishes a checkpoint revert offer when a checkpoint-backed tool ran, and publishes a `cancelled` notification. The synthetic tool response content says the user pressed Stop and the tool should not be retried or assumed completed (`termination.py:48-58`). Only `trigger_coding_agent` declares `on_terminate="checkpoint"`, guarded by `backend/tests/test_llm/test_orchestrator_termination.py:261-264`.

Draft threads use `working_directory` in `workflow_context`; main threads set it to `None`. Draft threads skip normal checkpointing and commit coding edits to the worktree branch instead (`orchestrator_agent/__init__.py:1250-1288`, `:1530-1539`; tests in `test_orchestrator_working_directory.py:1-193`).

## 13. Regression and evaluation strategy

There are three layers:

1. **Unit/integration tests** for loop mechanics, skill gating, streaming, context trimming, termination, working directories, OpenCode config/NDJSON parsing, and handover rules. Key tests include:
   - orchestrator model fallbacks and streaming: `backend/tests/test_services/test_orchestrator.py:65-116`, `:118-202`;
   - context trimming and delimiter hiding: `test_orchestrator.py:1593-1812`;
   - notification status on `ToolResult(status="error")`: `test_orchestrator.py:2352-2439`;
   - no single-use tools and no direct notification publishing from tools: `test_orchestrator.py:2821-2852`;
   - skill rehydration and gated tool filtering: `backend/tests/test_llm/test_invoke_skill.py:183-424`;
   - OpenCode protected-file/config/NDJSON boundary: `backend/tests/test_llm/test_opencode_cli.py:112-170`, `:1093-1168`.
2. **Orchestrator eval harness** in `backend/app/llm/orchestrator_agent/evals/`. It drives persona-based or scripted multi-turn cases, captures tool calls/UI blocks, runs deterministic checks, and optional judges (`evals/README.md:1-44`, `:76-137`, `:139-181`).
3. **LLM judge layers**: transcript judge for tone/persona/goal/drift (`judge.py:1-22`, `:74-122`) and optional handover-fidelity judge. Deterministic handover rules check verbatim preservation, reference resolution, adjective injection, JSON-path shapes, logo ordering, and upload phase (`deterministic.py:1-9`, `:250-355`, `:356-610`).

Important eval case coverage includes QA/SEO journey, recovery skill discipline, runtime error recovery, reference asset grounding, template fallback rejection, and ambiguous logo-update scope (`evals/cases/case_05_*` through `case_12_*`).

## 14. Maintainability and scalability patterns

Strong patterns:

- **Progressive disclosure / context diet**: global prompt contains flow and skill catalog; `invoke_skill` loads bodies only on demand. This lowers prompt bloat and lets capabilities evolve independently.
- **Single-source contracts**: skill frontmatter feeds the system prompt catalog; `TOOL_NOTIFICATION_ACTIONS` gates tool registration; `ToolResult` provides one error envelope; OpenCode config is generated in one Python module.
- **Thin adapter tools**: most tools validate, build context/params, delegate to a service/agent, and translate status into `ToolResult`.
- **Typed UI blocks instead of UI tools**: final assistant text carries render-only UI in tagged JSON validated by Pydantic.
- **Parallelism where safe**: tool calls execute with `asyncio.gather`; design generation runs non-null slots in parallel; batch image generation runs multiple images; background tasks handle website name, Neon init, screenshots, telemetry, and QA report requests.
- **Sandbox firewall**: Orchestrator sees typed results and summaries, not raw OpenCode/curl logs; OpenCode owns protected-file permissions and telemetry.
- **Regression codification**: deterministic eval assertions localize tool/skill/argument failures; unit tests guard prior incidents such as missing tool outputs, notification status, and protected file access.

## 15. Risks and watch points

- **Prompt/tool drift**: tool docstrings, SKILL.md bodies, and global prompt must not duplicate contracts. Use `orchestrator-tools.md:37-51` as the conflict-resolution rule.
- **Stale documentation**: some `agent-context/context-maps` entries lag the code (for example context threshold/model details). Treat source files and rule docs as stronger evidence.
- **Skill lifecycle complexity**: unlocked tools persist by scanning prior AI/tool messages. If history reconstruction drops or alters `invoke_skill` calls, gated tools can disappear. Tests cover this, but any message-history change should rerun `test_invoke_skill.py`.
- **Parallel tool races**: requirements-phase tools can run in parallel; stale workpad/subagent reads are a known fragility. Commit-before-tool-execution helps DB visibility, but tool ordering remains a design concern when one tool depends on another's side effects.
- **Sandbox security**: protected globs and dangerous-request regexes are critical. New file types/server/proxy surfaces must be added in both prompt/security policy and `_PROTECTED_FILE_GLOBS` or the Code tab/service layer may diverge.
- **Large-context pressure**: system prompt remains large despite skills. Memory preload, UI block history, and tool results can still grow; trimming depends on model usage metadata and only persists after turns complete.
- **OpenCode event shape instability**: NDJSON parsing is defensive because event shapes are not a stable public contract. New OpenCode versions may require parser/test updates.
- **Eval coverage dependence**: LLM judge failures can be flaky; deterministic assertions are more actionable. Add scripted regression cases for exact bug states whenever possible.

## 16. Suggested validation commands for future changes

Targeted checks before broad `task test`:

```bash
cd backend && uv run pytest \
  tests/test_llm/test_invoke_skill.py \
  tests/test_llm/test_run_skill_in_opencode_subagent.py \
  tests/test_llm/test_opencode_cli.py \
  tests/test_llm/test_orchestrator_termination.py \
  tests/test_services/test_orchestrator.py \
  tests/test_services/test_orchestrator_memory_preload.py \
  tests/test_services/test_orchestrator_working_directory.py
```

For prompt/tool behavior regressions:

```bash
task eval-orchestrator no_judge=1
task eval-orchestrator id=<case_id> handover_fidelity=1
```

Then run repo-required formatting/tests (`task fmt`, `task test`) before commit.
