#!/bin/bash
# Reaper script to delete stale benchmark instances from Vultr
# Targets instances with labels starting with "bench-" that are older than TTL

set -euo pipefail

# Default TTL: 24 hours in seconds
DEFAULT_TTL=86400

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Delete stale benchmark instances from Vultr.

Finds all instances with labels starting with "bench-" that are older than
the specified TTL and deletes them.

Options:
  --ttl SECONDS   Time-to-live in seconds (default: $DEFAULT_TTL = 6 hours)
  --dry-run       Show what would be deleted without actually deleting
  -h, --help      Show this help message

Examples:
  $0                      # Delete instances older than 6 hours
  $0 --ttl 3600           # Delete instances older than 1 hour
  $0 --dry-run            # Preview what would be deleted
  $0 --dry-run --ttl 7200 # Preview instances older than 2 hours

Cron example (run every hour):
  0 * * * * /path/to/reaper.sh >> /var/log/reaper.log 2>&1
EOF
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ttl=$DEFAULT_TTL
dry_run=false

while (($# > 0)); do
  case "$1" in
    --ttl)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --ttl requires a value"
        exit 1
      fi
      ttl="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Validate TTL is a number
if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
  echo "Error: TTL must be a positive integer (got: $ttl)"
  exit 1
fi

log "Starting reaper (TTL: ${ttl}s, dry-run: $dry_run)"

# Find stale bench-* instances
# Note: Using dateutil parsing via strptime to handle timezone offsets
stale_instances=$(
  vultr instance list --output json \
    | jq -r --argjson ttl "$ttl" '
        .instances[]
        | select(.label | startswith("bench-"))
        | .date_created as $dc
        | ($dc | sub("\\+00:00$"; "Z") | fromdateiso8601) as $created
        | select((now - $created) > $ttl)
        | "\(.id)\t\(.label)\t\($dc)"
      '
)

if [[ -z "$stale_instances" ]]; then
  log "No stale instances found"
  exit 0
fi

# Count instances
count=$(echo "$stale_instances" | wc -l)
log "Found $count stale instance(s)"

# Process each instance
while IFS=$'\t' read -r id label date_created; do
  age_seconds=$(( $(date +%s) - $(date -d "$date_created" +%s) ))
  age_hours=$(( age_seconds / 3600 ))
  age_minutes=$(( (age_seconds % 3600) / 60 ))

  if [[ "$dry_run" == "true" ]]; then
    log "[DRY-RUN] Would delete: $id ($label) - age: ${age_hours}h ${age_minutes}m"
  else
    log "Deleting: $id ($label) - age: ${age_hours}h ${age_minutes}m"
    if vultr instance delete "$id"; then
      log "Deleted: $id"
    else
      log "ERROR: Failed to delete $id"
    fi
  fi
done <<< "$stale_instances"

log "Reaper finished"
