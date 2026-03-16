#!/usr/bin/env python3
"""
Fire-and-forget Vultr benchmark launcher.

Creates instances from a snapshot, waits for SSH, writes the model assignment
to /root/benchmark_models.txt, then disconnects. The bench-runner.service picks
up the file and runs benchmarks autonomously until done, then self-destructs.

Your laptop needs to stay online for ~5-10m per batch while instances boot and
SSH becomes available. After the model file is written you can close your laptop.

Vultr blocks both --userdata and --script-id for custom snapshot instances, so
SSH is the only reliable way to pass per-instance configuration.

Usage:
  uv run scripts/orchestrate_vultr.py --models anthropic/claude-opus-4.5 --count 1
  uv run scripts/orchestrate_vultr.py --models model1 model2 model3 --count 3

Options:
  --models:  Space-separated list of models to benchmark
  --models-file: YAML file with default models (e.g. default-models.yml)
  --count:   Number of instances to create (default: 1)
             Models are distributed round-robin across instances.
             e.g. 9 models across 3 instances = 3 models per instance.
  --workers: Parallel SSH workers for writing model files (default: 10)
  --key:     Path to SSH private key (default: ~/.ssh/id_ed25519)
"""

from __future__ import annotations

import argparse
import json
import os
import random
import socket
import subprocess
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

import yaml

try:
    import paramiko
except ImportError:
    print("ERROR: paramiko is required. Install with: uv pip install paramiko", file=sys.stderr)
    sys.exit(1)

# See docs/snapshot-versions.md

DEFAULT_SNAPSHOT = "0b4273c2-ddee-4bd8-b56b-596111207145" # Last known good: "541697a1-c04c-4f54-bfc7-8ee90ae93aed"


@dataclass(frozen=True)
class VultrConfig:
    """Configuration for Vultr instance creation."""

    region: str = "atl"
    plan: str = "vc2-1c-2gb"
    snapshot: str = DEFAULT_SNAPSHOT
    ssh_keys: str = "4d587b8f-0641-4007-8b47-76272dd2b53d"


def timestamp() -> str:
    """Return local timestamp for log lines."""
    return time.strftime("%Y-%m-%d %H:%M:%S")


def log(message: str, *, error: bool = False) -> None:
    """Print a timestamped log line."""
    stream = sys.stderr if error else sys.stdout
    print(f"{timestamp()} {message}", file=stream, flush=True)


def create_instance(label: str, config: VultrConfig) -> str:
    """Create a Vultr instance and return its ID."""
    result = subprocess.run(
        [
            "vultr",
            "instance",
            "create",
            "--region",
            config.region,
            "--plan",
            config.plan,
            "--snapshot",
            config.snapshot,
            "--ssh-keys",
            config.ssh_keys,
            "--label",
            label,
            "--output",
            "json",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    data = json.loads(result.stdout)
    instance_data = data.get("instance", data)
    return instance_data["id"]


def wait_for_ip(instance_id: str, timeout: int = 900, poll: int = 10) -> str:
    """
    Poll until the instance has an IP address and is running.

    If the instance boots into a stopped state (which happens when the snapshot
    was taken from a stopped instance), issue a start command automatically.
    """
    start = time.time()
    started = False
    while time.time() - start < timeout:
        result = subprocess.run(
            ["vultr", "instance", "get", instance_id, "--output", "json"],
            capture_output=True,
            text=True,
            check=True,
        )
        data = json.loads(result.stdout)
        instance_data = data.get("instance", data)
        status = instance_data.get("status")
        power = instance_data.get("power_status", "running")
        server = instance_data.get("server_status", "")
        ip = instance_data.get("main_ip", "0.0.0.0")

        if status == "active" and ip != "0.0.0.0":
            # If the instance is stopped (snapshot taken while shut down), start it
            if power == "stopped" and server != "locked" and not started:
                log(f"    Instance {instance_id} is stopped — starting it...")
                subprocess.run(
                    ["vultr", "instance", "start", instance_id],
                    capture_output=True,
                    check=False,
                )
                started = True
            elif power == "running":
                return ip

        time.sleep(poll)
    raise TimeoutError(f"Instance {instance_id} did not become active within {timeout}s")


def wait_for_ssh(ip: str, timeout: int = 600) -> None:
    """Wait until port 22 accepts connections."""
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection((ip, 22), timeout=5):
                return
        except (socket.timeout, ConnectionRefusedError, OSError):
            time.sleep(5)
    raise TimeoutError(f"SSH not available on {ip} after {timeout}s")


def write_model_file(
    ip: str, models: list[str], key_path: str, official_key: str | None = None
) -> None:
    """
    SSH into the instance and write /root/benchmark_models.txt.

    Optionally also writes /root/benchmark_official_key.txt when official_key is provided.
    This is a brief connection — we write one file and disconnect.
    The bench-runner.service is already running and waiting for this file.
    """
    key_path = os.path.expanduser(key_path)
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        client.connect(ip, username="root", key_filename=key_path, timeout=30)
        model_content = "\n".join(models) + "\n"
        # Write atomically via temp file to avoid a race with the runner's polling
        escaped = model_content.replace("'", "'\\''")
        cmd = (
            f"printf '%s' '{escaped}' > /root/benchmark_models.txt.tmp && "
            f"mv /root/benchmark_models.txt.tmp /root/benchmark_models.txt"
        )
        _, stdout, stderr = client.exec_command(cmd)
        exit_status = stdout.channel.recv_exit_status()
        if exit_status != 0:
            err = stderr.read().decode().strip()
            raise RuntimeError(f"Failed to write model file on {ip}: {err}")

        if official_key:
            escaped_key = official_key.replace("'", "'\\''")
            key_cmd = (
                f"printf '%s' '{escaped_key}' > /root/benchmark_official_key.txt.tmp && "
                f"mv /root/benchmark_official_key.txt.tmp /root/benchmark_official_key.txt"
            )
            _, stdout2, stderr2 = client.exec_command(key_cmd)
            exit_status2 = stdout2.channel.recv_exit_status()
            if exit_status2 != 0:
                err2 = stderr2.read().decode().strip()
                raise RuntimeError(f"Failed to write official key file on {ip}: {err2}")
    finally:
        client.close()


def launch_instance(
    label: str,
    models: list[str],
    key_path: str,
    config: VultrConfig,
    ip_timeout: int,
    ssh_timeout: int,
    official_key: str | None = None,
) -> tuple[str, str, str]:
    """
    Full lifecycle for one instance: create → wait for IP → wait for SSH → write model file.

    Returns (label, instance_id, ip).
    """
    log(f"  [{label}] Creating instance for: {', '.join(models)}")
    instance_id = create_instance(label, config)
    log(f"  [{label}] Created: {instance_id} — waiting for IP...")

    ip = wait_for_ip(instance_id, timeout=ip_timeout)
    log(f"  [{label}] Active at {ip} — waiting for SSH...")

    wait_for_ssh(ip, timeout=ssh_timeout)
    log(f"  [{label}] SSH ready — writing model assignment...")

    write_model_file(ip, models, key_path, official_key=official_key)
    log(f"  [{label}] ✓ Models written. Instance is running headlessly.")

    return label, instance_id, ip


def distribute_models(models: list[str], count: int, *, shuffle: bool = True) -> list[list[str]]:
    """
    Distribute models across N instances using round-robin assignment.

    When shuffle=True (default), the model order is randomized before distribution.
    This prevents the same models from always landing on the same instance positions,
    which helps avoid systematic biases in benchmarking (e.g., first instances getting
    all the "A" models alphabetically).

    Examples:
      9 models, 3 instances → [[m0,m3,m6], [m1,m4,m7], [m2,m5,m8]]
      3 models, 5 instances → [[m0], [m1], [m2], [], []]
    """
    working_models = list(models)
    if shuffle:
        random.shuffle(working_models)
    buckets: list[list[str]] = [[] for _ in range(count)]
    for i, model in enumerate(working_models):
        buckets[i % count].append(model)
    return buckets


def load_models_from_yaml(path: str) -> list[str]:
    """Load models from a YAML file."""
    with open(path, encoding="utf-8") as f:
        data = yaml.safe_load(f)

    if isinstance(data, dict):
        data = data.get("models")

    if not isinstance(data, list):
        raise ValueError(f"{path} must contain a YAML list or a 'models' list")

    models = [str(m).strip() for m in data if str(m).strip()]
    if not models:
        raise ValueError(f"No models found in {path}")
    return models


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Launch self-orchestrating Vultr benchmark instances",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Run a model on a single instance
  uv run scripts/orchestrate_vultr.py --models anthropic/claude-opus-4.5

  # Distribute 30 models across 10 instances (3 models each)
  uv run scripts/orchestrate_vultr.py --count 10 --models model1 model2 ... model30
        """,
    )
    parser.add_argument("--models", nargs="+", help="Model IDs to benchmark")
    parser.add_argument(
        "--models-file",
        default="default-models.yml",
        help="YAML file with default models (default: default-models.yml)",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=1,
        help="Number of instances; models distributed round-robin (default: 1)",
    )
    parser.add_argument(
        "--workers", type=int, default=10, help="Parallel workers for instance setup (default: 10)"
    )
    parser.add_argument(
        "--key",
        default="~/.ssh/id_ed25519",
        help="Path to SSH private key (default: ~/.ssh/id_ed25519)",
    )
    parser.add_argument("--region", default="atl")
    parser.add_argument("--plan", default="vc2-1c-2gb")
    parser.add_argument("--snapshot", default=DEFAULT_SNAPSHOT)
    parser.add_argument("--ssh-keys", default="4d587b8f-0641-4007-8b47-76272dd2b53d")
    parser.add_argument(
        "--ip-timeout",
        type=int,
        default=900,
        help="Seconds to wait for instance active state and IP (default: 900)",
    )
    parser.add_argument(
        "--ssh-timeout",
        type=int,
        default=600,
        help="Seconds to wait for SSH port 22 (default: 600)",
    )
    parser.add_argument(
        "--official-key",
        type=str,
        default=os.environ.get("PINCHBENCH_OFFICIAL_KEY"),
        metavar="KEY",
        help="Official key to mark submissions as official (can also use PINCHBENCH_OFFICIAL_KEY env var)",
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="Enable verbose debug logging for scheduling/executor flow",
    )
    parser.add_argument(
        "--no-shuffle",
        action="store_true",
        help="Disable randomization of model order (default: models are shuffled before distribution)",
    )

    args = parser.parse_args()

    models = args.models
    if not models:
        if os.path.exists(args.models_file):
            models = load_models_from_yaml(args.models_file)
            log(f"Loaded {len(models)} models from {args.models_file}")
        else:
            parser.error(
                "either --models must be provided or the default models file must exist "
                f"({args.models_file})"
            )

    config = VultrConfig(
        region=args.region,
        plan=args.plan,
        snapshot=args.snapshot,
        ssh_keys=args.ssh_keys,
    )

    buckets = distribute_models(models, args.count, shuffle=not args.no_shuffle)
    non_empty = [(i, b) for i, b in enumerate(buckets) if b]

    if args.debug:
        bucket_sizes = [len(b) for b in buckets]
        non_empty_indexes = [i for i, _ in non_empty]
        log(f"DEBUG bucket sizes: {bucket_sizes}")
        log(f"DEBUG non-empty bucket indexes ({len(non_empty_indexes)}): {non_empty_indexes}")
        log(f"DEBUG workers: {args.workers}")

    log(f"\n{'=' * 60}")
    log("Vultr Benchmark Launcher")
    log(f"{'=' * 60}")
    log(f"Models:    {len(models)}")
    log(f"Instances: {args.count} ({len(non_empty)} with models assigned)")
    log(f"Official:  {'yes' if args.official_key else 'no'}")
    log("Note: laptop must stay online ~5m while instances boot")
    log(f"{'=' * 60}\n")

    created: list[tuple[str, str, str, list[str]]] = []
    failed: list[tuple[str, str]] = []

    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(
                launch_instance,
                f"bench-{i:02d}",
                bucket,
                args.key,
                config,
                args.ip_timeout,
                args.ssh_timeout,
                args.official_key,
            ): (
                i,
                bucket,
            )
            for i, bucket in non_empty
        }

        if args.debug:
            submitted_indexes = sorted(i for i, _ in futures.values())
            log(f"DEBUG submitted futures: {len(futures)}")
            log(f"DEBUG submitted indexes: {submitted_indexes}")

        completed_count = 0
        for future in as_completed(futures):
            i, bucket = futures[future]
            label = f"bench-{i:02d}"
            try:
                lbl, instance_id, ip = future.result()
                created.append((lbl, instance_id, ip, bucket))
                completed_count += 1
                if args.debug:
                    log(f"DEBUG future complete ({completed_count}/{len(futures)}): {label}")
            except Exception as e:
                log(f"  ✗ {label} failed: {e}", error=True)
                if args.debug:
                    log(traceback.format_exc().rstrip(), error=True)
                failed.append((label, str(e)))

    log(f"\n{'=' * 60}")
    log("Summary")
    log(f"{'=' * 60}")
    log(f"Launched: {len(created)}/{len(non_empty)}")

    for label, iid, ip, models in sorted(created):
        log(f"  {label} ({iid}) @ {ip}")
        for m in models:
            log(f"    - {m}")

    if failed:
        log(f"\nFailed ({len(failed)}):")
        for label, err in failed:
            log(f"  {label}: {err}")

    log("\nInstances are running headlessly and will self-destruct when done.")
    log("Monitor: vultr instance list")
    log("Logs:    ssh root@<ip> tail -f /var/log/bench-runner.log")
    log(f"{'=' * 60}\n")

    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
