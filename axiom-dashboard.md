# PinchBench Axiom Dashboard

## Setup

Dataset: `pinchbench`

## Dashboard Panels

### 1. Active Instances
**Chart type:** Table

```apl
pinchbench
| where event == "run_start" or event == "heartbeat"
| sort by _time desc
| summarize last_heartbeat = max(_time) by instance_id, model
| extend status = case(
    now() - last_heartbeat < 5m, "Running",
    now() - last_heartbeat < 15m, "Stale",
    "Dead"
  )
| sort by last_heartbeat desc
```

---

### 2. Tasks by Instance
**Chart type:** Table

Note: `minif`/`maxif` on `_time` return a float type in Axiom, so cast with `todatetime()`.

```apl
pinchbench
| where event == "task_start" or event == "task_complete"
| sort by _time asc
| summarize
    started = minif(_time, event == "task_start"),
    completed = maxif(_time, event == "task_complete"),
    score = maxif(score, event == "task_complete")
  by instance_id, model, task_id
| extend duration_min = datetime_diff("minute", todatetime(started), todatetime(completed))
| extend status = case(
    isnotnull(completed), "Complete",
    isnotnull(started), "Running",
    "Pending"
  )
| sort by started desc
```

---

### 3. Current Task Duration
**Chart type:** Table

Note: `max(_time)` in a `summarize` also needs `todatetime()` for `datetime_diff`.

```apl
pinchbench
| where event == "task_start"
| sort by _time desc
| summarize last_start = max(_time) by instance_id, model, task_id
| extend duration_min = datetime_diff("minute", todatetime(last_start), now())
| where duration_min > 0
| sort by duration_min desc
```

---

### 4. Overall Progress
**Chart type:** Table

This is a snapshot, not a timeseries. Use Table to show current % complete per model.

```apl
pinchbench
| where event == "task_complete" or event == "task_start"
| summarize
    completed = countif(event == "task_complete"),
    started = countif(event == "task_start")
  by model
| extend progress_pct = (completed / started) * 100
| sort by progress_pct asc
```

---

### 5. Tasks Completed Over Time
**Chart type:** Timeseries

Timeseries charts require `summarize ... by bin(_time, <interval>)` as the last summarize.

```apl
pinchbench
| where event == "task_complete"
| summarize count() by bin(_time, 5m), model
```

---

### 6. Error Rate
**Chart type:** Statistic

```apl
pinchbench
| where event == "task_complete" or event == "run_failed" or event == "sanity_failed"
| extend failed = case(
    event == "run_failed" or event == "sanity_failed", 1,
    score == 0, 1,
    0
  )
| summarize error_rate = avg(failed) * 100
```

---

### 7. Recent Errors
**Chart type:** Table (or Log Stream)

```apl
pinchbench
| where isnotnull(error) and error != ""
| sort by _time desc
| take 20
| project _time, instance_id, model, event, task_id, error
```

---

### 8. Score Distribution
**Chart type:** Table

```apl
pinchbench
| where event == "task_complete" and isnotnull(score_pct)
| summarize avg_score = avg(score_pct) by model
| sort by avg_score desc
```

---

### 9. Heartbeat Timeline
**Chart type:** Timeseries

```apl
pinchbench
| where event == "heartbeat"
| summarize count() by bin(_time, 1m), instance_id
```

---

## Alerts

### Instance Stalled
```apl
pinchbench
| where event == "heartbeat"
| summarize last_heartbeat = max(_time) by instance_id, model
| where now() - last_heartbeat > 5m
```

### Sanity Check Failed
```apl
pinchbench
| where event == "sanity_failed"
| sort by _time desc
| take 1
```

## Notes

- The `heartbeat` event fires every 60 seconds while a task is running
- `task_start` fires when a task begins execution
- `task_complete` fires when grading finishes
- Timeseries charts **must** have `summarize ... by bin(_time, <interval>)` as the final summarize
- `minif`/`maxif` on timestamp columns return float; wrap with `todatetime()` when using `datetime_diff`
