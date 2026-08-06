#!/usr/bin/env bash
# Run a release-pinned official PinchBench benchmark from a manually managed VM.
#
# Prerequisites on PATH: git, jq, python3, uv, openclaw, fws, and gws.
# Required environment: OPENROUTER_API_KEY and, for an official run,
# PINCHBENCH_OFFICIAL_KEY.
#
# Usage:
#   export OPENROUTER_API_KEY='...'
#   export PINCHBENCH_OFFICIAL_KEY='...'
#   export PINCHBENCH_SKILL_DIR="$HOME/pinchbench-skill" # optional
#   ./run-gcp-official-benchmark.sh deepseek/deepseek-v4-flash-0731
#   ./run-gcp-official-benchmark.sh --dry-run deepseek/deepseek-v4-flash-0731

set -euo pipefail

readonly BENCHMARK_VERSION="${PINCHBENCH_VERSION:-v2.0.0}"
readonly SKILL_DIR="${PINCHBENCH_SKILL_DIR:-$HOME/pinchbench-skill}"
readonly SKILL_REPOSITORY="${PINCHBENCH_SKILL_REPOSITORY:-https://github.com/pinchbench/skill.git}"

usage() {
  cat <<'EOF'
Usage: run-gcp-official-benchmark.sh [--dry-run] <provider/model>

Runs the complete official PinchBench suite using OpenRouter. The model argument
may be vendor/model or openrouter/vendor/model. For example:

  run-gcp-official-benchmark.sh deepseek/deepseek-v4-flash-0731
  run-gcp-official-benchmark.sh --dry-run deepseek/deepseek-v4-flash-0731

Required environment variables:
  OPENROUTER_API_KEY        Routes the benchmark model and default Haiku judge.
  PINCHBENCH_OFFICIAL_KEY   Marks the uploaded submission as official; not
                            required with --dry-run.

Options:
  --dry-run                 Run the representative core suite without uploading.
                            Skips token registration and requires no official key.

Optional environment variables:
  PINCHBENCH_SKILL_DIR      Checkout location; cloned when absent (default: ~/pinchbench-skill).
  PINCHBENCH_SKILL_REPOSITORY
                            Skill repository URL (default: pinchbench/skill).
  PINCHBENCH_VERSION        Required release tag (default: v2.0.0).
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_env() {
  [[ -n "${!1:-}" ]] || fail "Required environment variable is not set: $1"
}

has_openrouter_configuration() {
  local legacy_models="$HOME/.openclaw/agents/main/agent/models.json"
  local global_config="$HOME/.openclaw/openclaw.json"

  if [[ -f "$legacy_models" ]] && jq -e '
    .models.providers.openrouter? != null or .providers.openrouter? != null
  ' "$legacy_models" >/dev/null 2>&1; then
    return 0
  fi

  [[ -f "$global_config" ]] || return 1
  jq -e '
    .plugins.entries.openrouter.enabled == true or
    any((.agents.defaults.models // {}) | keys[]?; startswith("openrouter/")) or
    (.agents.defaults.model.primary? // "" | startswith("openrouter/")) or
    ([.auth.profiles // {} | .[]? | select(.provider == "openrouter")] | length > 0)
  ' "$global_config" >/dev/null 2>&1
}

prepare_skill_checkout() {
  if [[ ! -e "$SKILL_DIR" ]]; then
    printf 'Cloning PinchBench skill %s into %s...\n' "$BENCHMARK_VERSION" "$SKILL_DIR"
    mkdir -p "$(dirname "$SKILL_DIR")" || fail "Unable to create checkout parent directory."
    git clone --branch "$BENCHMARK_VERSION" --depth 1 "$SKILL_REPOSITORY" "$SKILL_DIR" \
      || fail "Unable to clone PinchBench skill release $BENCHMARK_VERSION."
  elif [[ ! -d "$SKILL_DIR/.git" ]]; then
    fail "PINCHBENCH_SKILL_DIR exists but is not a Git checkout: $SKILL_DIR"
  else
    printf 'Updating existing PinchBench skill checkout to %s...\n' "$BENCHMARK_VERSION"
    git -C "$SKILL_DIR" fetch --depth 1 origin "refs/tags/$BENCHMARK_VERSION:refs/tags/$BENCHMARK_VERSION" \
      || fail "Unable to fetch PinchBench skill release $BENCHMARK_VERSION."
    git -C "$SKILL_DIR" checkout --detach "$BENCHMARK_VERSION" \
      || fail "Unable to check out $BENCHMARK_VERSION. Resolve local checkout changes first."
  fi

  checked_out_version="$(git -C "$SKILL_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
  [[ "$checked_out_version" == "$BENCHMARK_VERSION" ]] \
    || fail "Expected $SKILL_DIR at $BENCHMARK_VERSION, found ${checked_out_version:-an untagged commit}."
}

DRY_RUN=0
MODEL_ARGUMENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown option: $1"
      ;;
    *)
      [[ -z "$MODEL_ARGUMENT" ]] || fail "Only one model argument is allowed."
      MODEL_ARGUMENT="$1"
      ;;
  esac
  shift
done

[[ -n "$MODEL_ARGUMENT" ]] || {
  usage >&2
  exit 2
}

case "$MODEL_ARGUMENT" in
  openrouter/*/*)
    MODEL="$MODEL_ARGUMENT"
    ;;
  */*)
    MODEL="openrouter/$MODEL_ARGUMENT"
    ;;
  *)
    fail "Model must be provider/model or openrouter/provider/model."
    ;;
esac

require_env "OPENROUTER_API_KEY"
if [[ "$DRY_RUN" -eq 0 ]]; then
  require_env "PINCHBENCH_OFFICIAL_KEY"
fi

for command_name in git jq python3 uv openclaw fws gws; do
  require_command "$command_name"
done

prepare_skill_checkout

[[ -f "$SKILL_DIR/scripts/run.sh" ]] || fail "Missing benchmark runner: $SKILL_DIR/scripts/run.sh"

if ! openclaw --version >/dev/null 2>&1; then
  fail "OpenClaw is installed but not runnable. Fix its installation before benchmarking."
fi

if ! has_openrouter_configuration; then
  fail "OpenClaw has no OpenRouter provider configuration. Run 'openclaw configure' or configure the OpenRouter plugin/auth profile."
fi

printf 'Synchronizing benchmark dependencies...\n'
(cd "$SKILL_DIR" && uv sync --frozen)

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Starting local core-suite dry run for %s...\n' "$MODEL"
  printf '%s\n' 'This skips token registration and does not upload a result.'
  cd "$SKILL_DIR"
  exec ./scripts/run.sh \
    --model "$MODEL" \
    --core \
    --no-upload
fi

if [[ -n "${PINCHBENCH_TOKEN:-}" ]]; then
  printf '%s\n' 'Ignoring existing PINCHBENCH_TOKEN and registering a fresh submission token.' >&2
  unset PINCHBENCH_TOKEN
fi

register_log="$(mktemp)"
trap 'rm -f "$register_log"' EXIT

printf 'Registering a fresh PinchBench submission token...\n'
if ! (cd "$SKILL_DIR" && ./scripts/run.sh --register) | tee "$register_log"; then
  fail "PinchBench token registration failed."
fi

claim_url="$(grep -i 'Claim URL' "$register_log" | grep -oE 'https?://[^[:space:]]+' | head -n 1 || true)"
if [[ -n "$claim_url" ]]; then
  printf 'Optional GitHub token claim URL: %s\n' "$claim_url"
fi

printf 'Starting official %s benchmark for %s...\n' "$BENCHMARK_VERSION" "$MODEL"
printf '%s\n' 'This runs the full suite and uploads the official result when it completes.'

cd "$SKILL_DIR"
exec ./scripts/run.sh \
  --model "$MODEL"
