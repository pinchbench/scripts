# Benchmark Run Observability Plan

## Purpose

Long-running benchmark runs currently become difficult to inspect after the launcher completes its SSH handoff. This document records the current observability model, the major blind spots, and a proposed sequence of improvements for assessment before implementation.

## Current Execution Model

The primary workflow is split across two components:

1. `orchestrate_vultr.py` creates Vultr instances from a snapshot, waits for their IP addresses and SSH connectivity, writes assigned models and optional configuration files to each instance, then exits.
2. `bench_runner.sh`, launched through `bench-runner.service`, reads the model assignment on each instance, registers the benchmark run, executes models sequentially, sends selected Slack notifications, and deletes the instance after complete success.

Current operator visibility includes:

- Timestamped provisioning and handoff messages printed by `orchestrate_vultr.py`.
- Instance-local logs at `/var/log/bench-runner.log` and in systemd journal output.
- Optional Slack messages for registration failure, run start, fail-fast events, and final completion.
- An Axiom dashboard specification expecting application-level lifecycle and heartbeat events.
- Vultr instance listing to see whether instances remain alive or have deleted themselves.

## Observability Gaps

### 1. No aggregated batch view after handoff

After assignment files are delivered, `orchestrate_vultr.py` no longer monitors the benchmark lifecycle. Operators cannot easily see, in one view:

- Which model is currently running on each instance.
- How many assigned models have completed.
- Whether an instance is progressing or stalled.
- Which instances failed registration or setup.
- Whether successful cleanup completed.

The current fallback is individual SSH log inspection, Slack, or externally emitted Axiom telemetry.

### 2. Logs disappear after successful self-deletion

`bench_runner.sh` maintains detailed local logs, but successful instances delete themselves immediately after finishing. Once deleted, their local log and journal history are unavailable for investigation of slow runs, unusual warnings, or incomplete result parsing.

### 3. Early failures are poorly surfaced

Failures before registration generally produce local log output only. Examples include:

- Missing tools on the snapshot.
- Metadata API lookup timeout.
- Assignment file timeout.
- Environment or setup problems before Slack notification is initialized in a useful lifecycle state.

An instance can remain running and incur cost without an obvious operator-facing terminal signal.

### 4. Setup failures can lose instance cleanup context

If instance creation succeeds but waiting for IP, waiting for SSH, or writing configuration fails, the launcher reports an exception but does not reliably retain the already created instance ID and any known IP in the failure summary. This complicates immediate diagnosis and cleanup.

### 5. Assignment delivery races runner startup

The service starts on instance boot while the orchestrator separately waits for SSH and writes `/root/benchmark_models.txt`. The runner waits only two minutes for this file and then exits. The unit has `Restart=no`, so a delayed handoff can result in an alive instance that never begins benchmarks.

### 6. Axiom telemetry may be silently disabled

Credential naming is inconsistent:

- `bootstrap_instance.sh` stores `AXIOM_TOKEN`.
- `orchestrate_vultr.py` and `bench_runner.sh` consume `AXIOM_API_TOKEN` or the SSH-delivered token file.

A snapshot configured only through bootstrap may therefore report that Axiom logging is disabled, even though an operator expects dashboard data.

### 7. Dashboard progress semantics are incomplete

The documented Axiom progress panel calculates completed tasks divided by started tasks. Tasks not yet started are absent from the denominator, so a long-running batch may appear more complete than it is. Infrastructure-stage failures before application telemetry also may not appear in the dashboard.

### 8. Result reporting relies on human-readable output parsing

The shell runner parses score, submission ID, and leaderboard URL from `benchmark.py` stdout. Output formatting changes could cause missing Slack result details without making the run itself fail or producing a specific observability warning.

### 9. Documentation differs from current behavior

Several documented operational assumptions do not match implementation:

- Model delivery is documented as userdata or metadata based, but current orchestration writes files over SSH.
- Laptop availability is documented as needed only through instance creation, but it is required through SSH handoff.
- Cleanup timing is documented as five or six hours in places, while current code uses a 24-hour safety net.

These inconsistencies make it harder to interpret expected instance states during a long run.

## Proposed Improvements

## Priority 1: Correlate Every Batch with a Run ID and Manifest

Generate a unique `run_id` for every orchestration invocation and carry it through all observable surfaces:

- Instance labels or tags.
- Launcher output.
- Model assignment configuration.
- Slack notifications.
- Axiom events.
- Retained logs and result records.

Persist a local manifest for each invocation, for example:

```json
{
  "run_id": "20260526T194100Z-7c1a",
  "snapshot": "ce21c623-3974-450c-9d3e-43117a2fb55b",
  "created_at": "2026-05-26T19:41:00Z",
  "instances": [
    {
      "label": "bench-00-7c1a",
      "instance_id": "abc123",
      "ip": "203.0.113.10",
      "models": ["model-a", "model-b"],
      "stage": "assignment_delivered"
    }
  ]
}
```

### Benefits

- Provides a durable record after instances delete themselves.
- Correlates logs, metrics, notifications, and results across machines.
- Preserves randomized model assignment for later analysis.
- Provides the basis for a status command and safe cleanup tooling.

### Relevant Code Areas

- `orchestrate_vultr.py`: model distribution, launch scheduling, success/failure reporting.
- `bench_runner.sh`: exported metadata and notifications.

## Priority 2: Emit Runner Lifecycle Telemetry

Add shell-level telemetry independently of any telemetry emitted by `benchmark.py`. Suggested lifecycle events:

| Event | Meaning |
| --- | --- |
| `instance_boot` | Runner process began on an instance. |
| `metadata_ready` | Vultr identity and IP were discovered. |
| `assignment_waiting` | Runner is waiting for assigned models. |
| `assignment_received` | Model assignment was accepted. |
| `registration_start` | Benchmark registration began. |
| `registration_complete` | Registration succeeded. |
| `registration_failed` | Registration failed. |
| `model_start` | A model benchmark began. |
| `model_complete` | A model benchmark completed successfully. |
| `model_failed` | A model benchmark completed unsuccessfully. |
| `runner_failed` | Runner terminated unexpectedly. |
| `deletion_requested` | Successful run initiated self-deletion. |
| `deletion_failed` | Instance could not self-delete. |

Include shared fields on all events where available:

- `run_id`
- `instance_id`
- `instance_ip`
- `instance_label`
- `model`
- `snapshot_id`
- `runner_hash`
- `skill_git_hash`
- `phase`
- `error`

### Benefits

- Observes infrastructure and setup failures before Python benchmark events begin.
- Makes failed handoff, failed cleanup, and registration problems dashboard-visible.
- Establishes a complete lifecycle timeline for each instance.

## Priority 3: Fix and Validate Axiom Enablement

Standardize credential usage on `AXIOM_API_TOKEN` across:

- `bootstrap_instance.sh`
- `setup_snapshot.sh`
- `orchestrate_vultr.py`
- `bench_runner.sh`

Add explicit startup validation:

- Log whether a token was loaded and from which supported source, without printing it.
- Send an `instance_boot` or `telemetry_ready` test event.
- Surface a failed telemetry request in local logs and optionally Slack.
- Record the intended dataset and run ID in the startup output.

### Benefits

- Avoids a silent empty-dashboard failure mode.
- Makes observability configuration verifiable before a full expensive batch.

## Priority 4: Preserve Failure Context During Provisioning

Refactor the launcher so intermediate launch failures still return or record all known instance context:

- Stage at which failure occurred: `create`, `ip_wait`, `ssh_wait`, or `assignment_write`.
- Instance ID if creation succeeded.
- IP address if allocated.
- Assigned models.
- Error string.
- Whether automatic cleanup was attempted or whether manual deletion is required.

Example failure summary:

```text
bench-04 failed at assignment_write: instance=abc123 ip=203.0.113.44
models=model-a,model-b
cleanup: retained; run `vultr instance delete abc123`
error: SSH command timed out
```

### Benefits

- Reduces orphaned infrastructure and accidental spend.
- Makes partial setup failures actionable from a single launcher report.

## Priority 5: Add an Atomic Per-Instance Status File

Have `bench_runner.sh` update a machine-readable status file, for example `/root/benchmark_status.json`, each time the state changes.

Example:

```json
{
  "run_id": "20260526T194100Z-7c1a",
  "phase": "benchmarking",
  "current_model": "openai/gpt-4o",
  "completed_models": 2,
  "failed_models": 0,
  "total_models": 4,
  "updated_at": "2026-05-26T20:17:04Z",
  "last_error": null,
  "result_urls": []
}
```

Write through a temporary file and rename it so remote readers never observe partially written JSON.

### Benefits

- Enables monitoring without parsing verbose logs.
- Provides an SSH-based fallback if Axiom is unavailable.
- Makes model-level progress inexpensive to poll.

## Priority 6: Provide a Batch Status Command

Add a companion command or an `orchestrate_vultr.py status` mode that loads a saved manifest and provides an aggregated operator view.

Initial data sources can be:

- Vultr instance state.
- The per-instance status JSON retrieved over SSH.
- Local manifest metadata.

Later, this command can query Axiom for heartbeat and terminal state data.

Example output:

```text
RUN 20260526T194100Z-7c1a
INSTANCE          MODEL              PHASE          ELAPSED   UPDATED    RESULT
bench-00-7c1a     openai/gpt-4o      benchmarking   41m       38s ago    -
bench-01-7c1a     claude-opus        complete       35m       6m ago     success
bench-02-7c1a     gemini-flash       stalled        57m       14m ago    -
```

### Benefits

- Gives operators a single useful interface during long runs.
- Reduces manual SSH and dashboard dependence.
- Allows early identification of stalled or retained instances.

## Priority 7: Retain Full Logs Before Deleting Instances

Before self-deletion on success, persist the complete runner log and structured run metadata to a durable destination. Possible options include:

- Axiom log ingestion.
- Object storage.
- A result service attachment.
- A central collection host.

Persist at least:

- `run_id`, instance ID, IP, and snapshot ID.
- Runner and benchmark git revisions or hashes.
- Assigned models.
- Start/end timestamps.
- Registration output status.
- Model exit codes.
- Extracted scores, submissions, and result URLs.
- `/var/log/bench-runner.log` contents.

### Benefits

- Preserves diagnostic evidence after the desired automatic cleanup path.
- Makes successful-but-suspicious runs inspectable.

## Priority 8: Notify on Early Failure and Unexpected Exit

Install an `EXIT` trap or explicit terminal-status handling in `bench_runner.sh` so failures before registration are observable.

Notify or emit telemetry on:

- Missing required tools.
- Metadata timeout.
- Assignment timeout.
- Registration failure.
- Model failure or fail-fast.
- Unexpected script exit.
- Self-delete failure.

Slack should remain low-volume: use it for terminal conditions and meaningful lifecycle boundaries, while Axiom handles fine-grained heartbeats and dashboard status.

### Benefits

- Detects retained instances that otherwise appear only through cost or manual checking.
- Provides immediate operational signal for snapshot regressions.

## Priority 9: Remove the Assignment Startup Race

The current runner begins before its assignment is guaranteed to exist. Prefer a deterministic handoff model:

### Preferred Option

- Snapshot instances do not automatically start the benchmark service.
- Orchestrator writes all assignment/configuration files over SSH.
- Orchestrator explicitly runs `systemctl start bench-runner.service` only after handoff succeeds.

### Alternative Options

- Add a systemd path unit that starts the runner when `/root/benchmark_models.txt` appears.
- Increase the assignment wait duration and report `assignment_waiting` telemetry continuously.

### Benefits

- Eliminates a boot timing race.
- Provides a clear, observable boundary between configured and executing instances.
- Prevents inert paid instances caused by a one-time service timeout.

## Priority 10: Strengthen Dashboard Semantics and Alerts

Update the Axiom data model and dashboard after lifecycle events and `run_id` exist.

### Recommended Dashboard Dimensions

- `run_id`
- `instance_id`
- `model`
- `snapshot_id`
- `runner_hash`
- `phase`
- `terminal_state`
- `last_heartbeat`
- `expected_model_count`
- `completed_model_count`

### Recommended Panels

- Active instances grouped by run ID and lifecycle phase.
- Model completion using `completed / expected`, not `completed / started`.
- Current model and elapsed runtime per instance.
- Last heartbeat and stalled instances.
- Registration and assignment failures.
- Instances retained for debugging.
- Self-delete failures and retained instances approaching TTL.
- Success/failure by snapshot version or runner hash.
- Models with successful exit but missing result URLs.

### Recommended Alerts

- Instance created but no `assignment_received` event within a threshold.
- Assignment received but no `registration_complete` event.
- Heartbeat absent for more than five minutes during active benchmarking.
- Runner terminated in a non-success terminal state.
- Self-delete failed.
- A benchmark-labeled Vultr instance persists close to cleanup TTL.

## Priority 11: Align Documentation with Operation

Update operator documentation and inline comments to reflect:

- SSH-delivered assignment files instead of userdata or metadata delivery.
- Laptop connectivity requirements through successful SSH handoff.
- Actual safety-net and reaper TTL values.
- Axiom environment variable naming and setup validation.
- The chosen durable log retention and status inspection workflows.

### Benefits

- Reduces confusion while debugging an expensive long run.
- Makes expected runtime and cleanup behavior clear to operators.

## Proposed Implementation Sequence

### Phase 1: Make Existing Telemetry Trustworthy

- Standardize `AXIOM_API_TOKEN` handling.
- Add runner lifecycle events for boot, assignment, registration, failure, and deletion.
- Add terminal notification handling for early failures.
- Correct documentation for handoff and cleanup behavior.

Expected outcome: silent failures become visible and dashboard enablement can be verified.

### Phase 2: Establish Batch-Level Correlation

- Introduce `run_id` generation and propagation.
- Write durable orchestration manifests.
- Preserve instance IDs and stages on partial provisioning failure.
- Include run ID in Slack and event fields.

Expected outcome: each launch can be analyzed as a coherent batch and cleaned up reliably.

### Phase 3: Add Live Operator Status

- Implement `/root/benchmark_status.json` writes.
- Build a status command based on manifests, Vultr status, and SSH status-file reads.
- Include current model, progress counters, last update, failures, and cleanup state.

Expected outcome: operators can monitor a long run from one command without opening many SSH sessions.

### Phase 4: Preserve Post-Run Evidence

- Ship complete runner logs to a durable store before deleting successful instances.
- Store structured per-model outcomes and benchmark/runtime metadata.
- Warn if output parsing fails to extract expected result fields.

Expected outcome: successful runs remain auditable after infrastructure is destroyed.

### Phase 5: Refine Lifecycle and Dashboard Workflows

- Remove the service/assignment startup race.
- Update dashboard queries and alerts around `run_id`, expected counts, lifecycle phases, and retained nodes.
- Add snapshot/runner-hash comparison views for regression detection.

Expected outcome: lifecycle operation is deterministic, and long-run trends and regressions become straightforward to analyze.

## Decision Points for Assessment

Before implementation, select preferred approaches for these design decisions:

| Decision | Options | Recommended Initial Choice |
| --- | --- | --- |
| Durable logs | Axiom, object storage, central SSH collection | Axiom if already licensed and reliable; otherwise object storage. |
| Live status source | Axiom only, SSH status JSON, hybrid | Hybrid: SSH status JSON first, Axiom as durable/alerting layer. |
| Service startup | Manual start after handoff, systemd path unit, longer timeout | Explicit `systemctl start` after assignment delivery. |
| Slack volume | Lifecycle only, per-model, periodic heartbeat | Lifecycle/terminal only; keep frequent progress in Axiom/status command. |
| Manifest storage | Repository-local ignored directory, external store | Local ignored run directory initially, with optional later upload. |

## Referenced Files

- `orchestrate_vultr.py`
- `bench_runner.sh`
- `bench-runner.service`
- `bootstrap_instance.sh`
- `setup_snapshot.sh`
- `axiom-dashboard.md`
- `README.md`
- `utilities/reaper.sh`
