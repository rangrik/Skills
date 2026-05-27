# Orchestration protocol

The contracts between the orchestrator and its workers. The orchestrator is the
only agent that talks to the user and the only agent that spawns agents; workers
do their job and **yield** a packet back up. This file defines those packets, the
yield/resume mechanism, the spawn prompts, and the progress file.

## 1. Yield / resume

A worker "yields" by ending its turn with a structured packet (see §2) instead of
acting on the user/code/ledger itself. The orchestrator fulfils the packet and
resumes the **same** worker so its context — the slice it has absorbed, the
decisions forming — survives the round-trip:

- **Preferred:** resume the same worker via the harness's agent-continuation
  (e.g. `SendMessage` to the worker by id/name). The worker keeps its context; you
  send only the answer/result.
- **Fallback (no continuation):** the worker writes its forming state to a scratch
  sibling `slice-N-<short>-system-design.WORKING.md` before yielding; you re-spawn
  a fresh worker pointed at that scratch file plus the answer. Heavier, but the
  scratch file makes it resumable and auditable. Delete the scratch file once the
  real spec is written.

Either way the worker never blocks waiting on the user; it yields and is resumed.

## 2. Packet types

Every packet names its **type** so the orchestrator knows how to fulfil it.

### `FORK` — a question only the user can answer
Emitted by the design worker (P1b reconcile, P3 grill, P4a contradiction
resolution, P4b last-call) and by the conformance critic ("ask the user").
```
type: FORK
question: <the decision to make, tied to this slice>
recommendation: <the worker's recommended option — relay FIRST>
principle: <governing kite-design-system-standards P-number, or named generic principle>
pushback: <if the likely intent bends a principle: name it + the failure it invites; else "none">
options: [<recommendation>, <alternative>, ...]
```
Orchestrator → `AskUserQuestion`, recommendation first, `principle`+`pushback` in
the description. Send the chosen option (and any "bend it anyway" note) back to the
worker. **Never answer it yourself.**

### `REALITY_CHECK_REQUEST` — code must be read
Emitted by the design worker at P4a.
```
type: REALITY_CHECK_REQUEST
slice_path: <abs path to slice-N-*.md>
forming_design: <decisions + §3 New/Modified/Reused subsystem map>
builds_on: <ancestor capability names only>
```
Orchestrator spawns the reality-check worker (§3), then returns its firewalled
findings to the design worker.

### `LEDGER_OP` — read or write `BLAST-IMPACT.md`
Emitted by the design worker (FILTER at reconcile, APPEND for out-of-scope
effects, FILTER for closeout) and by the conformance critic (APPEND below-bar
collateral).
```
type: LEDGER_OP
mode: FILTER | APPEND
payload: <slice scope + §3 map for FILTER; new entries / status updates for APPEND>
```
Orchestrator spawns the ledger-steward worker (§3) and returns its result.

### `RETURN_TO_DESIGNER` — a reality contradiction for re-entry
Emitted by the conformance critic for Family-C survivors.
```
type: RETURN_TO_DESIGNER
slice: <which slice's design>
subsystem: <SYSTEM_TAXONOMY title>
design_element: <Decision Dn / Assumption An / §3 row / §10 Qn>
nature: <collision at design altitude + recommended reconciliation>
```
Orchestrator routes these into a focused design-worker re-entry (SKILL.md step 8).

### `SPEC_WRITTEN` / `DONE` — the worker finished its unit
```
type: SPEC_WRITTEN          # design worker: slice-N-<short>-system-design.md is written
type: DONE                  # critic/verify/steward/backstop: job complete, + its result
```

## 3. Spawn prompts

### Design worker (`kite-system-design-blueprint-slices`)
```
Run the kite-system-design-blueprint-slices skill as a DESIGN WORKER under the
kite-solution-design orchestrator. You are code-blind and you do NOT spawn
sub-agents. Design exactly ONE slice, then yield.

- Slice to design: <abs path to slice-N-<short>.md>
- Builds-on capabilities (names only, assume available): <names>
- System taxonomy: <repo>/SYSTEM_TAXONOMY.md
- Pulled-in ledger entries now in scope for this slice: <BI-ids + effect, or "none">

Follow the skill's P1–P5. Wherever the skill says to ask the user, spawn a
sub-agent, or read/write the ledger, DO NOT do it — instead YIELD a packet
(FORK / REALITY_CHECK_REQUEST / LEDGER_OP) per the orchestration protocol and wait
to be resumed with the result. Emit SPEC_WRITTEN when the spec file is written. Do
not continue to any other slice.
```

### Design worker — re-entry mode
```
Run kite-system-design-blueprint-slices in RE-ENTRY mode for ONE slice. The
conformance critic returned these reality contradictions to resolve with the user.
Run the skill's "Re-entry" grill loop over JUST these, yielding a FORK per
contradiction, and fold each resolution into the existing spec. Same packet rules
as a normal design worker; emit SPEC_WRITTEN when re-finalized.

- Slice + spec: <paths>
- Returned contradictions: <list of {subsystem, design element, nature + recommendation}>
```

### Reality-check worker (code-aware, per slice)
Use the prompt in `kite-system-design-blueprint-slices/SKILL.md` P4a verbatim
(it is fully specified there, including the firewall rule). Pass the
`forming_design` and `builds_on` from the `REALITY_CHECK_REQUEST` packet.

### Whole-set backstop worker (code-aware, once)
Use the Stage-0 prompt in `kite-system-design-conformance-review/SKILL.md`
verbatim. It takes the whole slices directory at once.

### Ledger-steward worker
Use the steward prompt in
`kite-system-design-blueprint-slices/references/blast-impact-ledger.md` §5. Set
FILTER or APPEND from the `LEDGER_OP` packet.

### Conformance critic worker (`kite-system-design-conformance-review`)
```
Run kite-system-design-conformance-review as the CONFORMANCE CRITIC WORKER under
the kite-solution-design orchestrator. You are code-blind and you do NOT spawn
sub-agents. The orchestrator has ALREADY run the whole-set code-aware backstop;
its firewalled findings are below — treat them as your Stage-0 input, do not read
code.

- Slices directory: <abs path>
- Firewalled backstop findings (Stage-0 input): <pasted, or "none">

Run Stages 1–3. Apply the FIX-disposition edits to the specs yourself. For every
ASK, yield a FORK. For every RETURN-TO-DESIGNER (Family C), yield a
RETURN_TO_DESIGNER packet. For below-bar collateral, yield a LEDGER_OP/APPEND.
Write the review report. Do NOT run Stage 4 verification yourself — yield the list
of applied changes as part of DONE so the orchestrator can spawn a fresh verifier.
```

### Verify worker
Use the Stage-4 prompt in `kite-system-design-conformance-review/SKILL.md`. Spawn
fresh — never the worker that applied the changes.

## 4. `SOLUTION-DESIGN-PROGRESS.md` skeleton

The orchestrator's thin, resumable state. Lives at
`<feature>-slices/SOLUTION-DESIGN-PROGRESS.md`.

```markdown
# Solution-Design Progress — <Feature Name>

**Phase:** designing | conformance | readout | done
**Slices dir:** <path>

| Slice | Spec written? | Status | Notes |
|-------|---------------|--------|-------|
| slice-1-<short> | yes | conformance-checked | |
| slice-2-<short> | yes | designed | re-entry pending: BI/contradiction X |
| slice-3-<short> | no | pending | |

## Open returns / re-entries
<contradictions returned by the critic, by slice, until resolved>
```

Per-slice `Status`: `pending` → `designed` (spec exists) → `conformance-checked`
(survived the critic + verify). Resume = first slice that isn't `designed`, then
whatever `Phase` says.
