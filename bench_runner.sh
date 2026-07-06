#!/bin/bash
# Autonomous benchmark runner — runs on each Vultr instance at boot.
#
# Reads the model list from the Vultr instance metadata API (set as userdata
# by the orchestrator), runs registration and benchmarks for each model,
# and self-destructs the instance on full success.
#
# This script is invoked by bench-runner.service (systemd) on first boot.
# It should be placed at /root/run_benchmarks.sh on the snapshot image.
# Use setup_snapshot.sh to install it.

set -o pipefail

LOG="/var/log/bench-runner.log"
REMOTE_DIR="/root/skill/scripts"
METADATA="http://169.254.169.254"

# Tee all output to log file
exec > >(tee -a "$LOG") 2>&1

# ── Load environment first, before strict mode ──
# .bashrc references $PS1 which is unbound in non-interactive shells.
# Source with -u disabled to avoid a fatal error, then enable strict mode.
source /root/.profile 2>/dev/null || true
source /root/.bashrc 2>/dev/null || true
set -o allexport
source /etc/environment 2>/dev/null || true
set +o allexport

# Ensure tool paths are present regardless of how systemd invoked this script
export PATH="/root/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:$PATH"

# Ensure HOME is set — systemd may not set it, but the Vultr CLI needs it to
# locate its config directory ($XDG_CONFIG_HOME falls back to $HOME/.config).
export HOME="${HOME:-/root}"

# Now enable strict mode (unbound variables are safe after sourcing profiles)
set -uo pipefail

# ── Slack notification helper ──
# Reads SLACK_WEBHOOK_URL from /etc/environment (set during snapshot setup).
# Silently no-ops if the variable is unset so the script still works without Slack.
slack_notify() {
    local text="$1"
    if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
        return 0
    fi
    curl -sf -X POST "$SLACK_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"text\": $(echo "$text" | jq -Rs .)}" \
        >/dev/null 2>&1 || echo "WARNING: Slack notification failed"
}

echo "=== Benchmark runner started at $(date -u) ==="
echo "Hostname: $(hostname)"

# ── Verify required tools ──
for tool in curl jq uv vultr; do
    if ! command -v "$tool" &>/dev/null; then
        echo "ERROR: '$tool' not found in PATH (PATH=$PATH)"
        exit 1
    fi
done

# ── Get instance ID and IP from Vultr metadata ──
echo "Fetching instance metadata..."
INSTANCE_ID=""
INSTANCE_IP=""
for attempt in $(seq 1 12); do
    INSTANCE_ID=$(curl -sf --retry 3 --retry-delay 5 "$METADATA/v1/instance-v2-id" 2>/dev/null || true)
    INSTANCE_IP=$(curl -sf --retry 3 --retry-delay 5 "$METADATA/v1/interfaces/0/ipv4/address" 2>/dev/null || true)
    if [ -n "$INSTANCE_ID" ] && [ -n "$INSTANCE_IP" ]; then
        break
    fi
    echo "  Metadata not ready (attempt $attempt/12), retrying in 10s..."
    sleep 10
done

if [ -z "$INSTANCE_ID" ]; then
    echo "ERROR: Could not retrieve instance ID from metadata API after 2 minutes"
    exit 1
fi

echo "Instance ID: $INSTANCE_ID"
echo "Instance IP: $INSTANCE_IP"

# ── Register a safety-net self-destruct in 5 hours ──
# This fires even if the benchmarks hang or the runner crashes after registration.
# Requires 'at' to be available (installed by setup_snapshot.sh).
if command -v at &>/dev/null && [ -n "$INSTANCE_ID" ]; then
    echo "vultr instance delete $INSTANCE_ID" | at now + 24 hours 2>/dev/null && \
        echo "Safety-net self-destruct scheduled in 24 hours" || \
        echo "WARNING: Could not schedule safety-net self-destruct (at daemon not running?)"
fi

# ── Read model list from file ──
# The orchestrator creates a Vultr startup script per instance that writes
# /root/benchmark_models.txt (one model per line) at first boot.
# Startup scripts run regardless of snapshot vs OS image, unlike --userdata
# which is silently ignored on snapshot-based instances.
MODEL_FILE="/root/benchmark_models.txt"

# Wait for the startup script to run and write the file (it runs early in boot
# but may not be done by the time this service starts)
echo "Waiting for model assignment file..."
for attempt in $(seq 1 12); do
    if [ -s "$MODEL_FILE" ]; then
        break
    fi
    echo "  $MODEL_FILE not ready yet (attempt $attempt/12), waiting 10s..."
    sleep 10
done

if [ ! -s "$MODEL_FILE" ]; then
    echo "ERROR: $MODEL_FILE not found or empty after 2 minutes"
    echo "Was this instance launched by the orchestrator?"
    exit 1
fi

echo "Model assignment file:"
cat "$MODEL_FILE"

mapfile -t MODELS < "$MODEL_FILE"

if [ ${#MODELS[@]} -eq 0 ]; then
    echo "ERROR: No models found in $MODEL_FILE"
    exit 1
fi

echo "Models assigned to this instance:"
for m in "${MODELS[@]}"; do
    echo "  - $m"
done

# ── Read optional official key ──
OFFICIAL_KEY_FILE="/root/benchmark_official_key.txt"
OFFICIAL_KEY_ARG=()
OFFICIAL_KEY_SET="no"
if [ -s "$OFFICIAL_KEY_FILE" ]; then
    OFFICIAL_KEY=$(cat "$OFFICIAL_KEY_FILE")
    OFFICIAL_KEY_ARG=(--official-key "$OFFICIAL_KEY")
    OFFICIAL_KEY_SET="yes"
    echo "Official key loaded from $OFFICIAL_KEY_FILE"
elif [ -n "${PINCHBENCH_OFFICIAL_KEY:-}" ]; then
    OFFICIAL_KEY_ARG=(--official-key "$PINCHBENCH_OFFICIAL_KEY")
    OFFICIAL_KEY_SET="yes"
    echo "Official key loaded from PINCHBENCH_OFFICIAL_KEY env var"
else
    echo "No official key found — submissions will be unofficial"
fi

# ── Read optional Axiom token for observability ──
AXIOM_TOKEN_FILE="/root/benchmark_axiom_token.txt"
if [ -s "$AXIOM_TOKEN_FILE" ]; then
    export AXIOM_API_TOKEN=$(cat "$AXIOM_TOKEN_FILE")
    echo "Axiom logging enabled from $AXIOM_TOKEN_FILE"
elif [ -n "${AXIOM_API_TOKEN:-}" ]; then
    echo "Axiom logging enabled from AXIOM_API_TOKEN env var"
else
    echo "Axiom logging disabled (no token found)"
fi

# ── Read optional no-fail-fast flag ──
NO_FAIL_FAST_FILE="/root/benchmark_no_fail_fast.txt"
NO_FAIL_FAST=0
if [ -s "$NO_FAIL_FAST_FILE" ]; then
    NO_FAIL_FAST=1
    echo "Fail-fast DISABLED (will continue running all models even on sanity check failure)"
else
    echo "Fail-fast enabled (default)"
fi

# ── Read optional thinking level ──
THINKING_FILE="/root/benchmark_thinking.txt"
THINKING_ARG=()
if [ -s "$THINKING_FILE" ]; then
    THINKING_LEVEL=$(cat "$THINKING_FILE")
    THINKING_ARG=(--thinking "$THINKING_LEVEL")
    echo "Thinking level set to '$THINKING_LEVEL' from $THINKING_FILE"
else
    echo "Thinking level: default (no override)"
fi

# Export Vultr instance metadata for Axiom events
export VULTR_INSTANCE_ID="$INSTANCE_ID"
export VULTR_INSTANCE_IP="$INSTANCE_IP"

# ── Pull latest benchmark code ──
echo ""
echo "=== Updating benchmark code ==="
cd "$REMOTE_DIR"
git pull || echo "WARNING: git pull failed, continuing with existing code"
SKILL_GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# ── Registration ──
echo ""
echo "=== Running registration ==="
# Use a temp file so output is both written to the log (via the exec redirect)
# and available for URL extraction. Command substitution $(...) runs in a subshell
# that doesn't inherit the exec redirect, so tee /dev/stderr wouldn't reach the log.
REG_TMPFILE=$(mktemp)
    uv run benchmark.py --register "${OFFICIAL_KEY_ARG[@]}" 2>&1 | tee "$REG_TMPFILE"
REGISTER_EXIT=${PIPESTATUS[0]}
REGISTRATION_OUTPUT=$(cat "$REG_TMPFILE")
rm -f "$REG_TMPFILE"

if [ "$REGISTER_EXIT" -ne 0 ]; then
    echo "ERROR: Registration failed"
    slack_notify "❌ *bench-runner failed* on \`$(hostname)\` ($INSTANCE_ID)
IP: \`$INSTANCE_IP\`
Registration failed after assigning models: ${MODELS[*]}
Instance retained for debugging.
Check: \`ssh root@$INSTANCE_IP tail -f $LOG\`"
    exit 1
fi
echo "✓ Registration complete"

# Unset any pre-baked PINCHBENCH_TOKEN from the snapshot environment so that
# benchmark runs use the freshly registered token saved to the config file.
# lib_upload._resolve_token checks the env var before the config file, so
# a stale snapshot token would otherwise shadow the new one and cause 401s.
unset PINCHBENCH_TOKEN

# Extract claim URL ("Claim URL: https://...") from registration output
CLAIM_URL=$(echo "$REGISTRATION_OUTPUT" | grep -i "Claim URL" | grep -oE 'https?://[^ ]+' | head -1 || true)

MODEL_LIST=$(printf ' • %s\n' "${MODELS[@]}")
slack_notify "🚀 *bench-runner started* on \`$(hostname)\` ($INSTANCE_ID)
IP: \`$INSTANCE_IP\`
Skill git hash: \`$SKILL_GIT_HASH\`
Official key set: \`$OFFICIAL_KEY_SET\`
Models (${#MODELS[@]}):
$MODEL_LIST
${CLAIM_URL:+Claim URL: $CLAIM_URL}"

# ── Run benchmarks ──
FAILED_MODELS=()
RESULT_URLS=()
SKIPPED_MODELS=()
FAIL_FAST_TRIGGERED=0
FAIL_FAST_MODEL=""

for i in "${!MODELS[@]}"; do
    model="${MODELS[$i]}"
    echo ""
    echo "=== Benchmarking: $model ==="
    echo "Started at: $(date -u)"

    MODEL_TMPFILE=$(mktemp)
    uv run benchmark.py --model "$model" "${OFFICIAL_KEY_ARG[@]}" "${THINKING_ARG[@]}" 2>&1 | tee "$MODEL_TMPFILE"
    MODEL_EXIT=${PIPESTATUS[0]}
    MODEL_OUTPUT=$(cat "$MODEL_TMPFILE")
    rm -f "$MODEL_TMPFILE"

    # Extract score, submission ID, and leaderboard URL from model run output
    MODEL_SCORE=$(echo "$MODEL_OUTPUT" | grep -oP "Overall Score: \K[\d.]+% \([\d.]+ / [\d.]+\)" | head -1 || true)
    MODEL_SUBMISSION=$(echo "$MODEL_OUTPUT" | grep -i "Submission ID" | grep -oE '[a-f0-9-]{36}' | head -1 || true)
    MODEL_URL=$(echo "$MODEL_OUTPUT" | grep -i "View at" | grep -oE 'https?://[^ ]+' | head -1 || true)
    
    # Build result entry with score and URL
    RESULT_ENTRY="$model"
    if [ -n "$MODEL_SCORE" ]; then
        RESULT_ENTRY="$RESULT_ENTRY: $MODEL_SCORE"
    fi
    if [ -n "$MODEL_URL" ]; then
        RESULT_ENTRY="$RESULT_ENTRY — $MODEL_URL"
    fi
    if [ -n "$MODEL_SUBMISSION" ]; then
        RESULT_ENTRY="$RESULT_ENTRY (submission: $MODEL_SUBMISSION)"
    fi
    RESULT_URLS+=("$RESULT_ENTRY")

    if [ "$MODEL_EXIT" -eq 0 ]; then
        echo "✓ $model complete at $(date -u)"
    elif [ "$MODEL_EXIT" -eq 3 ]; then
        if [ "$NO_FAIL_FAST" -eq 1 ]; then
            echo "⚠️  Sanity check failed for $model (exit code 3) — continuing (fail-fast disabled)"
            FAILED_MODELS+=("$model")
        else
            echo "🚨 FAIL FAST triggered by $model (exit code 3)"
            FAILED_MODELS+=("$model")
            if [ "$i" -lt "$(( ${#MODELS[@]} - 1 ))" ]; then
                SKIPPED_MODELS=("${MODELS[@]:$((i + 1))}")
            fi
            FAIL_FAST_TRIGGERED=1
            FAIL_FAST_MODEL="$model"
            FAIL_FAST_SKIPPED_LIST=""
            if [ ${#SKIPPED_MODELS[@]} -gt 0 ]; then
                FAIL_FAST_SKIPPED_LIST=$(printf ' • %s\n' "${SKIPPED_MODELS[@]}")
            fi
            slack_notify "🚨 *bench-runner fail-fast* on \`$(hostname)\` ($INSTANCE_ID)
IP: \`$INSTANCE_IP\`
Model: \`$model\`
Reason: sanity check scored 0% (exit code 3)
Skipped (${#SKIPPED_MODELS[@]}):
$FAIL_FAST_SKIPPED_LIST"
            break
        fi
    else
        echo "✗ $model failed at $(date -u)"
        FAILED_MODELS+=("$model")
    fi
done

# ── Summary ──
echo ""
echo "=== Run complete at $(date -u) ==="
echo "Total models: ${#MODELS[@]}"
echo "Failed:       ${#FAILED_MODELS[@]}"
if [ "$FAIL_FAST_TRIGGERED" -eq 1 ]; then
    echo "Fail-fast:    yes (triggered by $FAIL_FAST_MODEL)"
    echo "Skipped:      ${#SKIPPED_MODELS[@]}"
fi
if [ ${#FAILED_MODELS[@]} -gt 0 ]; then
    echo "Failed models:"
    for m in "${FAILED_MODELS[@]}"; do
        echo "  - $m"
    done
fi
if [ ${#SKIPPED_MODELS[@]} -gt 0 ]; then
    echo "Skipped models:"
    for m in "${SKIPPED_MODELS[@]}"; do
        echo "  - $m"
    done
fi

PROCESSED=$(( ${#MODELS[@]} - ${#SKIPPED_MODELS[@]} ))
SUCCEEDED=$(( PROCESSED - ${#FAILED_MODELS[@]} ))
if [ "$FAIL_FAST_TRIGGERED" -eq 1 ]; then
    SUMMARY_EMOJI="🚨"
    SKIPPED_LIST=""
    if [ ${#SKIPPED_MODELS[@]} -gt 0 ]; then
        SKIPPED_LIST=$(printf ' • %s\n' "${SKIPPED_MODELS[@]}")
    fi
    SUMMARY_STATUS="fail-fast triggered by $FAIL_FAST_MODEL after $SUCCEEDED/${#MODELS[@]} succeeded.
Skipped (${#SKIPPED_MODELS[@]}):
$SKIPPED_LIST"
elif [ ${#FAILED_MODELS[@]} -eq 0 ]; then
    SUMMARY_EMOJI="✅"
    SUMMARY_STATUS="all ${#MODELS[@]} models completed"
else
    SUMMARY_EMOJI="⚠️"
    FAILED_LIST=$(printf ' • %s\n' "${FAILED_MODELS[@]}")
    SUMMARY_STATUS="$SUCCEEDED/${#MODELS[@]} succeeded. Failed:
$FAILED_LIST"
fi

SHOULD_DESTROY=1
if [ "$FAIL_FAST_TRIGGERED" -eq 1 ] || [ ${#FAILED_MODELS[@]} -gt 0 ]; then
    SHOULD_DESTROY=0
fi

if [ "$SHOULD_DESTROY" -eq 1 ]; then
    LIFECYCLE_NOTE="Destroying instance now."
else
    LIFECYCLE_NOTE="Instance retained for debugging (safety-net auto-delete is still scheduled)."
fi

RESULTS_SECTION=""
if [ ${#RESULT_URLS[@]} -gt 0 ]; then
    RESULTS_SECTION="
Results:
$(printf ' • %s\n' "${RESULT_URLS[@]}")"
fi

slack_notify "$SUMMARY_EMOJI *bench-runner done* on \`$(hostname)\` ($INSTANCE_ID)
IP: \`$INSTANCE_IP\`
$SUMMARY_STATUS
${CLAIM_URL:+Claim URL: $CLAIM_URL}$RESULTS_SECTION
$LIFECYCLE_NOTE"

# ── Self-destruct ──
if [ "$SHOULD_DESTROY" -eq 1 ]; then
    echo ""
    echo "=== Deleting instance $INSTANCE_ID ==="
    if vultr instance delete "$INSTANCE_ID"; then
        echo "✓ Instance deletion requested"
    else
        echo "WARNING: Self-destruct failed — instance $INSTANCE_ID may need manual cleanup"
        echo "Run: vultr instance delete $INSTANCE_ID"
    fi
else
    echo ""
    echo "=== Instance retained for debugging: $INSTANCE_ID ($INSTANCE_IP) ==="
    echo "Run when done: vultr instance delete $INSTANCE_ID"
fi
