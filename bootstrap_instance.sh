#!/bin/bash
# Bootstrap a fresh Vultr instance into a snapshot-ready benchmark runner.
#
# Run this on a FRESH Vultr instance (Ubuntu 22.04 or Debian Bookworm, root).
# It installs all dependencies, clones the benchmark repo, installs the runner
# service, writes credentials to /etc/environment, resets cloud-init, and shuts
# down so you can immediately take a snapshot.
#
# Usage (from your laptop):
#   scp scripts/bootstrap_instance.sh root@<ip>:/tmp/
#   ssh root@<ip> 'bash /tmp/bootstrap_instance.sh'
#
# You will be prompted interactively for:
#   - GitHub repo URL (or leave blank to use the default)
#   - OPENROUTER_API_KEY
#   - PINCHBENCH_TOKEN
#   - VULTR_API_KEY
#   - PINCHBENCH_OFFICIAL_KEY (optional)
#   - SLACK_WEBHOOK_URL (optional)
#
# After the script exits the instance will be shut down. Take a snapshot from
# the Vultr portal or with:
#   vultr snapshot create -i <id> -d "bench-runner $(date +%Y-%m-%d)"
# Then update the snapshot ID in orchestrate_vultr.py and create_instance.sh.

set -euo pipefail

SKILL_DIR="/root/skill"
REPO_URL="https://github.com/pinchbench/skill.git"
LOG="/var/log/bootstrap.log"
BOOTSTRAP_SRC="$(readlink -f "${BASH_SOURCE[0]}")"
RUNNER_BUNDLE_HASH=""
RUNNER_HASH_RECORD="/root/bootstrap-runner-hashes.txt"

exec > >(tee -a "$LOG") 2>&1

echo "=== PinchBench bootstrap started at $(date -u) ==="

# ── Prompt for credentials upfront ──
echo ""
echo "Enter credentials (all required unless noted):"
echo ""

read -r -p "Skill repo URL [$REPO_URL]: " INPUT_REPO
REPO_URL="${INPUT_REPO:-$REPO_URL}"

read -r -p "OPENROUTER_API_KEY: " OPENROUTER_API_KEY
if [ -z "$OPENROUTER_API_KEY" ]; then
    echo "ERROR: OPENROUTER_API_KEY is required"
    exit 1
fi

read -r -p "PINCHBENCH_TOKEN: " PINCHBENCH_TOKEN
if [ -z "$PINCHBENCH_TOKEN" ]; then
    echo "ERROR: PINCHBENCH_TOKEN is required"
    exit 1
fi

read -r -p "VULTR_API_KEY: " VULTR_API_KEY
if [ -z "$VULTR_API_KEY" ]; then
    echo "ERROR: VULTR_API_KEY is required (needed for instance self-destruct)"
    exit 1
fi

read -r -p "PINCHBENCH_OFFICIAL_KEY (optional, press Enter to skip): " PINCHBENCH_OFFICIAL_KEY

read -r -p "SLACK_WEBHOOK_URL (optional, press Enter to skip): " SLACK_WEBHOOK_URL

echo ""
echo "=== Starting installation ==="

# ── System packages ──
echo ""
echo "--- Installing system packages ---"
apt-get update -qq
apt-get install -y -qq \
    curl \
    git \
    jq \
    at \
    python3 \
    python3-pip \
    python3-venv \
    python3-yaml \
    python-is-python3 \
    ca-certificates \
    gnupg

systemctl enable atd
systemctl start atd
echo "✓ System packages installed"

# ── Node.js 22 ──
echo ""
echo "--- Installing Node.js 22 ---"
if command -v node &>/dev/null; then
    echo "✓ Node.js already installed: $(node --version)"
else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
    echo "✓ Node.js $(node --version) installed"
fi

# ── uv ──
echo ""
echo "--- Installing uv ---"
if command -v uv &>/dev/null; then
    echo "✓ uv already installed: $(uv --version)"
else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    ln -sf /root/.local/bin/uv /usr/local/bin/uv
    echo "✓ uv $(uv --version) installed"
fi

# ── Vultr CLI ──
echo ""
echo "--- Installing Vultr CLI ---"
if command -v vultr-cli &>/dev/null || command -v vultr &>/dev/null; then
    # Ensure both names exist regardless of which was found
    if command -v vultr-cli &>/dev/null && ! command -v vultr &>/dev/null; then
        ln -sf "$(command -v vultr-cli)" /usr/local/bin/vultr
    elif command -v vultr &>/dev/null && ! command -v vultr-cli &>/dev/null; then
        ln -sf "$(command -v vultr)" /usr/local/bin/vultr-cli
    fi
    echo "✓ vultr-cli already installed: $(vultr-cli version 2>/dev/null || vultr version)"
else
    # Tag format is "v3.8.0"; asset filename includes the full tag: vultr-cli_v3.8.0_linux_amd64.tar.gz
    # Binary inside the archive is named "vultr-cli"
    VULTR_CLI_VERSION=$(curl -sf "https://api.github.com/repos/vultr/vultr-cli/releases/latest" | jq -r '.tag_name')
    VULTR_CLI_URL="https://github.com/vultr/vultr-cli/releases/download/${VULTR_CLI_VERSION}/vultr-cli_${VULTR_CLI_VERSION}_linux_amd64.tar.gz"
    echo "  Downloading vultr-cli $VULTR_CLI_VERSION..."
    curl -sL "$VULTR_CLI_URL" | tar -xz -C /usr/local/bin vultr-cli
    chmod +x /usr/local/bin/vultr-cli
    ln -sf /usr/local/bin/vultr-cli /usr/local/bin/vultr
    echo "✓ vultr-cli $(vultr-cli version) installed"
fi

# ── OpenClaw ──
echo ""
echo "--- Installing OpenClaw ---"
if command -v openclaw &>/dev/null; then
    echo "✓ OpenClaw already installed: $(openclaw --version 2>/dev/null || echo unknown version)"
else
    npm install -g openclaw
    echo "✓ OpenClaw $(openclaw --version 2>/dev/null || echo installed)"
fi

# ── OpenClaw optional peer dependencies ──
# These are optional deps that OpenClaw may need at runtime but doesn't
# auto-install. Missing them causes "Cannot find module" errors.
echo ""
echo "--- Installing OpenClaw peer dependencies ---"
npm install -g @slack/web-api
echo "✓ OpenClaw peer dependencies installed"

# ── Clone benchmark repo ──
echo ""
echo "--- Cloning benchmark repo ---"
if [ -d "$SKILL_DIR" ]; then
    echo "  $SKILL_DIR already exists, pulling latest..."
    git -C "$SKILL_DIR" pull
else
    git clone "$REPO_URL" "$SKILL_DIR"
fi
echo "✓ Repo at $SKILL_DIR"

# ── Pre-install Python dependencies ──
echo ""
echo "--- Pre-installing Python dependencies ---"
cd "$SKILL_DIR"
uv sync
echo "✓ Python dependencies installed"

# ── Write credentials to /etc/environment ──
echo ""
echo "--- Writing credentials to /etc/environment ---"

# Remove any existing entries for these keys
sed -i '/^OPENROUTER_API_KEY=/d' /etc/environment
sed -i '/^PINCHBENCH_TOKEN=/d' /etc/environment
sed -i '/^VULTR_API_KEY=/d' /etc/environment
sed -i '/^PINCHBENCH_OFFICIAL_KEY=/d' /etc/environment
sed -i '/^SLACK_WEBHOOK_URL=/d' /etc/environment

cat >> /etc/environment <<EOF
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
PINCHBENCH_TOKEN=$PINCHBENCH_TOKEN
VULTR_API_KEY=$VULTR_API_KEY
EOF

if [ -n "$PINCHBENCH_OFFICIAL_KEY" ]; then
    echo "PINCHBENCH_OFFICIAL_KEY=$PINCHBENCH_OFFICIAL_KEY" >> /etc/environment
fi

if [ -n "$SLACK_WEBHOOK_URL" ]; then
    echo "SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL" >> /etc/environment
fi

# Also make available to login shells
cat > /etc/profile.d/pinchbench.sh <<EOF
export OPENROUTER_API_KEY=$OPENROUTER_API_KEY
export PINCHBENCH_TOKEN=$PINCHBENCH_TOKEN
export VULTR_API_KEY=$VULTR_API_KEY
EOF
if [ -n "$PINCHBENCH_OFFICIAL_KEY" ]; then
    echo "export PINCHBENCH_OFFICIAL_KEY=$PINCHBENCH_OFFICIAL_KEY" >> /etc/profile.d/pinchbench.sh
fi
if [ -n "$SLACK_WEBHOOK_URL" ]; then
    echo "export SLACK_WEBHOOK_URL=$SLACK_WEBHOOK_URL" >> /etc/profile.d/pinchbench.sh
fi

echo "✓ Credentials written"

# ── Install bench_runner.sh ──
echo ""
echo "--- Installing bench_runner.sh ---"
RUNNER_SRC=""
# Look relative to this script, then /tmp
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for candidate in "$SCRIPT_DIR/bench_runner.sh" "/tmp/bench_runner.sh"; do
    if [ -f "$candidate" ]; then
        RUNNER_SRC="$candidate"
        break
    fi
done

if [ -z "$RUNNER_SRC" ]; then
    echo "  bench_runner.sh not found locally — copying from repo..."
    # It lives in the pinchbench/scripts dir of the repo; if the skill repo
    # doesn't contain it, we embed a download path. For now, require it to
    # be scp'd alongside this script.
    echo "ERROR: bench_runner.sh not found in $SCRIPT_DIR or /tmp"
    echo "  scp scripts/bench_runner.sh root@<ip>:/tmp/ and rerun"
    exit 1
fi

cp "$RUNNER_SRC" /root/run_benchmarks.sh
chmod 700 /root/run_benchmarks.sh
echo "✓ Runner installed at /root/run_benchmarks.sh"

# ── Install bench-runner.service ──
echo ""
echo "--- Installing bench-runner.service ---"
SERVICE_SRC=""
for candidate in "$SCRIPT_DIR/bench-runner.service" "/tmp/bench-runner.service"; do
    if [ -f "$candidate" ]; then
        SERVICE_SRC="$candidate"
        break
    fi
done

if [ -z "$SERVICE_SRC" ]; then
    echo "ERROR: bench-runner.service not found in $SCRIPT_DIR or /tmp"
    echo "  scp scripts/bench-runner.service root@<ip>:/tmp/ and rerun"
    exit 1
fi

cp "$SERVICE_SRC" /etc/systemd/system/bench-runner.service
systemctl daemon-reload
systemctl enable bench-runner.service
echo "✓ Service installed and enabled ($(systemctl is-enabled bench-runner.service))"

# ── Hash snapshot bootstrap artifacts ──
echo ""
echo "--- Hashing snapshot bootstrap artifacts ---"
BOOTSTRAP_SHA256=$(sha256sum "$BOOTSTRAP_SRC" | awk '{print $1}')
RUNNER_SHA256=$(sha256sum "$RUNNER_SRC" | awk '{print $1}')
SERVICE_SHA256=$(sha256sum "$SERVICE_SRC" | awk '{print $1}')
RUNNER_BUNDLE_HASH=$(printf '%s\n' \
    "bootstrap_instance.sh:$BOOTSTRAP_SHA256" \
    "bench_runner.sh:$RUNNER_SHA256" \
    "bench-runner.service:$SERVICE_SHA256" \
    | sha256sum | awk '{print $1}')

cat > "$RUNNER_HASH_RECORD" <<EOF
generated_at_utc: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
bootstrap_instance.sh: $BOOTSTRAP_SHA256
bench_runner.sh: $RUNNER_SHA256
bench-runner.service: $SERVICE_SHA256
runner_hash: $RUNNER_BUNDLE_HASH
EOF

echo "✓ runner hash: $RUNNER_BUNDLE_HASH"
echo "  hash record: $RUNNER_HASH_RECORD"

# ── Reset cloud-init ──
echo ""
echo "--- Resetting cloud-init ---"
cloud-init clean
echo "✓ cloud-init reset"

# ── Verification ──
echo ""
echo "=== Verification ==="
echo -n "  uv:               "; uv --version
echo -n "  node:             "; node --version
echo -n "  vultr:            "; vultr-cli version
echo -n "  jq:               "; jq --version
echo -n "  at:               "; at -V 2>&1 || true
echo -n "  openclaw:         "; openclaw --version 2>/dev/null || echo "(check manually)"
echo -n "  runner script:    "; ls -la /root/run_benchmarks.sh
echo -n "  service enabled:  "; systemctl is-enabled bench-runner.service
echo -n "  runner hash:      "; echo "$RUNNER_BUNDLE_HASH"
echo -n "  repo:             "; git -C "$SKILL_DIR" log -1 --oneline
echo ""
echo "Credentials set:"
grep -E "OPENROUTER_API_KEY|PINCHBENCH_TOKEN|VULTR_API_KEY|PINCHBENCH_OFFICIAL_KEY|SLACK_WEBHOOK_URL" /etc/environment \
    | sed 's/=.*/=<set>/'

echo ""
echo "=== Bootstrap complete at $(date -u) ==="
echo ""
echo "Next steps:"
echo "  1. Instance is shutting down now"
echo "  2. Take snapshot:"
echo "       vultr snapshot create -i <id> -d \"bench-runner $(date +%Y-%m-%d)\""
echo "  3. Record this runner hash in docs/snapshot-versions.md:"
echo "       $RUNNER_BUNDLE_HASH"
echo "     (full per-file hashes are in $RUNNER_HASH_RECORD)"
echo "  4. Note the new snapshot ID and update in:"
echo "       orchestrate_vultr.py  (VultrConfig.snapshot default)"
echo "       create_instance.sh    (--snapshot flag)"
echo ""

# ── Done ──
echo ""
echo "Bootstrap complete. Do NOT shut down the instance before snapshotting."
echo "Take the snapshot from a RUNNING instance so it boots correctly:"
echo ""
echo "  vultr snapshot create -i <id> -d \"bench-runner $(date +%Y-%m-%d)\""
echo ""
echo "Then delete this instance:"
echo "  vultr instance delete <id>"
