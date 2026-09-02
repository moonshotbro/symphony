# Durable coordination action ledger

The optional action ledger is Symphony's fail-closed boundary for mutating coordination. It extends
the existing orchestrator; it does not poll trackers, schedule work, own claims, or replace the
retry queue. It is disabled by default.

## Configuration

```yaml
action_ledger:
  enabled: true
  path: /var/lib/symphony/action-ledger.jsonl
```

An enabled ledger requires an explicit durable path. A relative path resolves from the directory
containing `WORKFLOW.md`. Startup fails when the file is unreadable, malformed, truncated, or
cannot be recovered. With the feature disabled, the runtime and dispatch path remain unchanged.

## Action envelope

Each persisted JSON line is a complete `symphony.action-ledger.v1` action snapshot:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | `act_` plus the first 32 hex characters of the idempotency key |
| `idempotency_key` | 64-character hex | Hash of the complete normalized intent |
| `lineage_key` | 64-character hex | Hash of action kind and bounded source identity |
| `kind` | enum | `task_creation`, `task_messaging`, `automation`, `fork`, `handoff`, or `merge` |
| `source` | bounded object | Goal/task/issue/repository/revision/session and privacy-bounded review correlation |
| `target` | bounded object | Type, ID, host, project, or worker host only |
| `purpose_hash` | 64-character hex | Hash of the purpose; the purpose body is never stored |
| `checkpoint` | string | Exact source revision or workflow checkpoint |
| `expected_postcondition` | token | Named effect that proves success |
| `policy_fingerprint` | 64-character hex | Exact policy version governing dispatch |
| `blocker_classification` | token or null | `goal.stalled` when a durable decision condition blocks one goal |
| `resume_condition` | token or null | Exact named condition allowed to resume that stalled goal |
| `valid_until` | RFC 3339 or null | Expiry checked before an approval-like effect is presented or run |
| `state` | enum | Current state from the transition table below |
| `supersedes` | action ID or null | Previous action in the same source lineage |
| `observed_effect` | bounded object | Resulting task/session/worktree/revision identifiers and disposition |
| `inserted_at`, `updated_at` | RFC 3339 | Snapshot timestamps |

Canonical encoding uses deterministic Erlang terms and SHA-256. Replaying the same normalized
intent returns the existing action. Changing the checkpoint, target, purpose, policy, expiry, or
resume condition creates a new linked action. Stored identity is recomputed during replay, so an
altered envelope fails startup closed.

## Transition table

| From | Allowed next states |
| --- | --- |
| `planned` | `preflight_rejected`, `dispatched`, `quarantined`, `needs_input`, `terminal_failure` |
| `dispatched` | `succeeded`, `already_satisfied`, `uncertain`, `retryable_failure`, `compensated`, `quarantined`, `needs_input`, `terminal_failure` |
| `uncertain` | `succeeded`, `already_satisfied`, `retryable_failure`, `compensated`, `quarantined`, `needs_input`, `terminal_failure` |
| `retryable_failure` | `planned`, `quarantined`, `needs_input`, `terminal_failure` |
| `quarantined` | `planned`, `needs_input`, `terminal_failure` |
| `needs_input` | `planned`, `already_satisfied`, `quarantined`, `terminal_failure` |

`preflight_rejected`, `succeeded`, `already_satisfied`, `compensated`, and `terminal_failure` are
immutable. Corrections are new actions linked through `supersedes`.

On startup, every persisted `dispatched` action becomes `uncertain` before the orchestrator starts.
Its issue remains claimed, so the ordinary scheduler cannot blindly dispatch a duplicate. The
reconciler returns ordered `pending`, `retryable`, `quarantined`, and `needs_input` lists for the
existing orchestrator to inspect.

An uncertain action is not retryable by implication. The caller must first call
`ActionLedger.inspect_recovered/3` with an authoritative provider result. For a
`codex.session_observed` postcondition, the result must confirm provider authority, existence,
session identity, and workspace identity. Confirmed effects become `already_satisfied`; an
authoritative absence becomes `retryable_failure`; incomplete or non-authoritative evidence becomes
`quarantined`. The adapter accepts an `inspect_recovered` callback and performs this inspection
before it can move an uncertain action back to `planned`.

## Obsolete approvals and stalled goals

The coordination adapter checks `valid_until` and an optional live precondition immediately before
it records `dispatched`. A failed check transitions the action to `preflight_rejected` with
`approval_obsolete`; the effect callback is not invoked. This cancels stale approval work before
presentation or execution.

A durable decision request uses `blocker_classification: goal.stalled` and a precise
`resume_condition`. Identical requests deduplicate. When the supplied condition matches exactly,
`resume_goal/3` moves that durable decision request from `needs_input` to terminal
`already_satisfied`; it does not turn the decision request itself into another dispatch. The native
orchestrator separately releases the matching issue claim and schedules its existing poll loop, so
the underlying issue can continue through the ordinary scheduler. Other action lanes remain
schedulable. The orchestrator can resolve the persisted stalled-goal action directly after restart,
using the issue revision as the checkpoint and a deterministic named resume condition. If the
initial ledger write fails, the issue remains blocked and no retry is scheduled.

## Native integration map

- `AgentRuntimeSupervisor` starts the ledger before the existing orchestrator when enabled.
- `Orchestrator.refresh_issue_for_dispatch/1` remains the source-state freshness guard.
- `Orchestrator.spawn_issue_on_worker_host/5` persists `planned` and `dispatched` before spawning a
  worker through `CoordinationAdapter`; the existing task supervisor still owns the process.
- `AgentRunner` runtime updates provide the existing workspace and worker-host correlation.
- `Codex.AppServer` updates provide the session identity that satisfies `codex.session_observed`.
- `Orchestrator` worker-exit handling records retry/input dispositions but continues to use the
  existing retry queue and claim state.
- `Workspace.workspace_key/1` supplies bounded workspace identity; hooks are evidence, never the
  transaction boundary.
- every transition emits `[:symphony, :action_ledger, :transition]` with action, state, issue/task/
  session correlation, checkpoint hash, policy fingerprint, and blocker tokens only.

`Codex.CoordinationEffects` is the typed native boundary for these operations. It records the
fence, attempt, and correlation identifiers as bounded identity facts before calling a provider.
Only stored-thread fork is currently admitted; its provider must return the exact source and child
thread IDs, and a lost response remains `uncertain` until a read-only child inspection reconciles
it. Task messaging, automation, and handoff are persisted as typed preflight rejections because
the installed desktop-host capability has not been identity-bound to Symphony. No request body,
prompt, tool arguments, host pipe metadata, or provider payload is admitted to the ledger.

The GitHub adapter provides
the first live mutation boundary as `github_merge`; its review source, reviewer, exact check list,
and derived fingerprint are persisted as bounded source metadata without prompts, credentials, or
review body content.

For `task_creation` actions whose postcondition is `codex.session_observed`, the native
`Codex.RecoveryInspector` opens a fresh read-only App Server connection on the recorded worker
host and uses metadata-only `thread/read` followed by paginated `thread/turns/list`. It accepts an
effect only when the provider returns the exact recorded thread ID, deterministic workspace path,
turn ID, and typed dispatch-host assertion. Codex does not expose a provider-issued session ID;
the stored `session_correlation_id` is explicitly the local `<thread_id>-<turn_id>` correlation,
not provider authority. Remote workspace paths are absolute, traversal-free, and contained below
the configured remote root before Symphony opens SSH. Only Codex's exact `-32600` `thread not
loaded: <recorded thread id>` response is authoritative absence and makes the action retryable; a timeout, malformed
response, missing correlation, host mismatch, cached ID, or telemetry never does. Those cases
remain held/quarantined rather than being blindly redispatched.

## Recovery runbook

1. Stop mutation dispatch if the ledger cannot start or append. Read-only inspection of an already
   loaded in-memory ledger remains available.
2. Inspect `reconcile/1`. Never retry an `uncertain` action solely because the process restarted.
3. Verify the expected postcondition against the authoritative provider using the recorded bounded
   identifiers.
4. Record `succeeded` or `already_satisfied` when the effect exists; otherwise move to
   `retryable_failure`, `quarantined`, `needs_input`, or `terminal_failure` with evidence.
5. Resume `goal.stalled` only through its exact named condition. Create a superseding intent when
   checkpoint, target, purpose, or policy changes.
6. Repair corrupt storage from a known-good backup or operator-audited prefix; do not truncate and
   continue silently.

For a stopped or unavailable process, `ActionLedger.inspect_storage(path)` is a read-only recovery
API. It reports parsed actions and reconciliation state, or returns the corruption/read failure
without modifying the file. It must be used before any operator repair; no recovery command may
silently truncate or continue from a partial ledger.

## Privacy boundary

The ledger rejects unknown fields, non-string values, oversized values, and keys containing prompt,
secret, token, password, body, content, or credential. Issue identifiers, repositories, and
dispositions also pass strict payload-safe allowlists; invalid values are rejected before append
and are never redacted into an apparently valid identity. It stores hashes instead of purpose text
and never stores issue descriptions, prompts, document content, customer payloads, or credentials.
