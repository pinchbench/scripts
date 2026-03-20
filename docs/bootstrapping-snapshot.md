## Boostrapping a new Vultr Snapshot

Do this whenever the snapshot is lost or needs to be rebuilt from scratch.
The snapshot is what all benchmark instances boot from — it contains the repo,
all dependencies, API keys, and the runner service.

### 1. Create a fresh base instance

Use a plain Ubuntu 22.04 image (not the old snapshot):

```bash
vultr instance create \
  --region atl \
  --plan vc2-1c-2gb \
  --os 1743 \
  --label bench-bootstrap \
  --ssh-keys a4b8f6d9-fa2e-48a4-b12d-b6162d065e52 \
  --output json
```

Note: `4d587b8f-0641-4007-8b47-76272dd2b53d` = popos / `a4b8f6d9-fa2e-48a4-b12d-b6162d065e52` = mbp

Wait for it to become active and get its IP:

```bash
vultr instance list
```

### 2. Copy the setup files to the instance

```bash
scp bootstrap_instance.sh \
    bench_runner.sh \
    bench-runner.service \
    root@<ip>:/tmp/
```

### 3. SSH into the instance and run the bootstrap script

```bash
ssh root@<ip>
```

```bash
'bash /tmp/bootstrap_instance.sh'
```

The script will prompt for:

| Credential                | Where to find it                                             |
| ------------------------- | ------------------------------------------------------------ |
| `OPENROUTER_API_KEY`      | `skill/.env`                                                 |
| `PINCHBENCH_TOKEN`        | `skill/.env`                                                 |
| `VULTR_API_KEY`           | Vultr portal → Account → API                                 |
| `PINCHBENCH_OFFICIAL_KEY` | `skill/.env` (optional — skip for unofficial submissions)    |
| `SLACK_WEBHOOK_URL`       | Slack app webhook (optional — skip to disable notifications) |

It installs Node 22, uv, vultr-cli, OpenClaw, clones the skill repo, pre-installs
Python deps, writes credentials to `/etc/environment`, installs and enables
`bench-runner.service`, computes a runner bundle hash for the three bootstrapped
files (`bootstrap_instance.sh`, `bench_runner.sh`, `bench-runner.service`), and
resets cloud-init.

The bootstrap script is idempotent — if it fails partway through, fix the issue
and re-run it. Already-installed tools will be skipped.

### 4. Take the snapshot

Take the snapshot while the instance is **still running**. Snapshots taken from
stopped instances boot into a stopped state, which breaks the orchestrator.

```bash
vultr snapshot create \
  -i <id> \
  -d "bench-runner $(date +%Y-%m-%d)"
```

Wait for the snapshot status to become `complete`:

```bash
watch vultr snapshot list
```

### 5. Update snapshot metadata

Update `docs/snapshot-versions.md` with a new table row that includes:

- Date
- Snapshot name
- Snapshot ID
- `Runner Hash` (printed by `bootstrap_instance.sh` and saved to `/root/bootstrap-runner-hashes.txt`)
- Notes

Then update the snapshot ID in two places:

**`scripts/orchestrate_vultr.py`** — `VultrConfig.snapshot` default:

```python
snapshot: str = "<new-snapshot-id>"
```

**`scripts/create_instance.sh`** — the `--snapshot` comment at the top.

### 6. Delete the bootstrap instance

It's stopped but still billing:

```bash
vultr instance delete <id>
```
