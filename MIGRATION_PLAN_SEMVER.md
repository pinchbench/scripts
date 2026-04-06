# Production Migration: Git Hash → SemVer Versioning

**Issue:** [pinchbench/skill#62](https://github.com/pinchbench/skill/issues/62)
**Date:** 2026-04-06
**Risk:** Medium — Schema changes + data migration. Backward compatible.

---

## Overview

This migration replaces opaque git hashes (`a1b2c3d`) with semantic versions (`1.0.0`) across all PinchBench components. The API accepts any version format for backward compatibility with old skill clients.

**Version source of truth:** GitHub releases (git tags). The `BENCHMARK_VERSION` file is auto-updated by CI on each release.

---

## Phase 1: skill repo

### What to verify before merging

| PR | Title | What to check |
|----|-------|---------------|
| [#109](https://github.com/pinchbench/skill/pull/109) | Add GitHub Actions release workflow | `.github/workflows/release.yml` exists, triggers on `release.published`, strips `v` prefix, commits as github-actions[bot] |
| [#110](https://github.com/pinchbench/skill/pull/110) | Fix BENCHMARK_VERSION and add setuptools-scm | `pyproject.toml` has `dynamic = ["version"]`, `build-system` includes `setuptools-scm>=8`, `[tool.setuptools_scm]` section exists, `BENCHMARK_VERSION` file contains `0.1.0` |
| [#111](https://github.com/pinchbench/skill/pull/111) | Replace _get_git_version with _get_benchmark_version | `_get_benchmark_version()` function exists with 4-level fallback (importlib.metadata → BENCHMARK_VERSION file → git describe --tags → git short hash), call site updated |

### Merge order for skill
1. **#109** — Release workflow (needed first so future releases auto-update the version file)
2. **#110** — setuptools-scm + BENCHMARK_VERSION (foundational infrastructure)
3. **#111** — Replace versioning function (uses the new infrastructure)

### What to look for
- `pyproject.toml` should have `dynamic = ["version"]` NOT a static `version = "x.x.x"`
- `BENCHMARK_VERSION` file should be plain text (no quotes, no trailing newline recommended)
- Release workflow should only push to `main`, not to the release tag ref
- `_get_benchmark_version()` should NOT call `_get_git_version()` — it should be a standalone implementation

---

## Phase 2: api repo (requires D1 access)

### PR merge order

```
#33 semver columns + migration script (foundational)
     ↓
#32 backfill legacy versions (depends on #33)
     ↓
#35 benchmarkVersions routes + sorting (depends on #32)
     ↓
#34 semver fields in routes (depends on #33, can run parallel with #32/#35)
```

### What to verify before merging each PR

**[#33](https://github.com/pinchbench/api/pull/33) — semver columns + migration**

Files changed: `schema.sql`, `migrations/YYYYMMDD_add_semver_columns.sql`

Check `schema.sql` adds these columns to `benchmark_versions`:
```sql
semver TEXT,
label TEXT,
release_notes TEXT,
release_url TEXT
```

Check migration script `YYYYMMDD_add_semver_columns.sql`:
```sql
ALTER TABLE benchmark_versions ADD COLUMN semver TEXT;
ALTER TABLE benchmark_versions ADD COLUMN label TEXT;
ALTER TABLE benchmark_versions ADD COLUMN release_notes TEXT;
ALTER TABLE benchmark_versions ADD COLUMN release_url TEXT;
CREATE INDEX IF NOT EXISTS idx_benchmark_versions_semver ON benchmark_versions(semver);
```

**[#32](https://github.com/pinchbench/api/pull/32) — backfill legacy versions**

Files changed: `migrations/YYYYMMDD_backfill_legacy_versions.sql`

This script should:
1. Query all existing `benchmark_versions` ordered by `created_at ASC`
2. Generate `UPDATE` statements assigning `1.0.0-beta.1`, `1.0.0-beta.2`, etc.
3. Both `semver` and `label` should be set to the same value (e.g., `1.0.0-beta.1`)
4. `release_notes` and `release_url` should remain NULL for legacy versions

**[#35](https://github.com/pinchbench/api/pull/35) — benchmarkVersions routes + sorting**

Files changed: `src/routes/benchmarkVersions.ts`

Check that:
- Response includes all new fields: `semver`, `label`, `release_notes`, `release_url`
- Sorting is semver-aware: stable semver versions first (sorted by semver rules), then legacy versions by `created_at DESC`
- The route still works with existing frontend (backward compatible response shape)

**[#34](https://github.com/pinchbench/api/pull/34) — semver fields in routes**

Files changed: `src/routes/results.ts`, `src/routes/submissions.ts`, `src/types.ts`

Check that:
- `BenchmarkVersion` type includes `semver`, `label`, `release_notes`, `release_url`
- `results.ts` — when inserting new versions, `semver`/`label` default to the `id` value if not provided
- Other routes that return `BenchmarkVersion` include the new fields

### How to run the D1 migrations manually

The API uses Cloudflare D1. You need to run these manually against production.

**Prerequisites:**
```bash
# Install Wrangler if you don't have it
npm install -g wrangler

# Login to Cloudflare
wrangler auth login

# Get the D1 database ID from your dashboard or wrangler.toml
wrangler d1 list
```

**Step 1: Add the new columns**

```bash
# Get the database ID
wrangler d1 list
# Look for "pinchbench-api" or your production D1

# Run the column migration
wrangler d1 execute pinchbench-api \
  --file=migrations/YYYYMMDD_add_semver_columns.sql \
  --region=unknown  # or your region
```

Or paste directly:
```sql
ALTER TABLE benchmark_versions ADD COLUMN semver TEXT;
ALTER TABLE benchmark_versions ADD COLUMN label TEXT;
ALTER TABLE benchmark_versions ADD COLUMN release_notes TEXT;
ALTER TABLE benchmark_versions ADD COLUMN release_url TEXT;
CREATE INDEX IF NOT EXISTS idx_benchmark_versions_semver ON benchmark_versions(semver);
```

**Step 2: Backfill existing versions**

First, check what you have:
```sql
SELECT id, created_at FROM benchmark_versions ORDER BY created_at ASC;
```

Then run the backfill script:
```bash
wrangler d1 execute pinchbench-api \
  --file=migrations/YYYYMMDD_backfill_legacy_versions.sql
```

Or paste the generated UPDATE statements directly.

**Verify the migration:**
```sql
SELECT id, semver, label, created_at FROM benchmark_versions ORDER BY created_at ASC LIMIT 20;
```

You should see:
| id | semver | label |
|----|--------|-------|
| ad1c230 | 1.0.0-beta.1 | 1.0.0-beta.1 |
| 7df28f6 | 1.0.0-beta.2 | 1.0.0-beta.2 |
| ... | ... | ... |

**Step 3: Verify the API still works**

```bash
curl https://your-api.workers.dev/api/benchmark_versions | jq .
```

The response should include the new fields. Old versions will have `semver` like `1.0.0-beta.N` and null `release_notes`/`release_url`.

**Rollback (if needed):**

D1 doesn't support `ALTER TABLE DROP COLUMN`. If you need to roll back:
1. Restore from the D1 backup you took before the migration
2. Or manually `UPDATE` to copy data back before dropping (not supported — this is why you take a backup)

---

## Phase 3: leaderboard repo

### PR merge order

```
#70 BenchmarkVersion type in types.ts
     ↓
#73 version-selector.tsx display + #74 about page docs + other pages
```

(Note: #71, #72 are duplicates from earlier attempts — verify the latest ones are the ones merged)

### What to verify before merging each PR

**[#70](https://github.com/pinchbench/leaderboard/pull/70) — BenchmarkVersion type**

Check `lib/types.ts`:
```typescript
export interface BenchmarkVersion {
  id: string;
  semver: string | null;        // null only if migration hasn't run yet
  label: string;                // display string
  release_notes: string | null;
  release_url: string | null;   // link to GitHub release
  created_at: string;
  is_current: boolean;
  submission_count: number;
}
```

**Other PRs (verify they use new fields)**

Check these files use the new fields correctly:
- `components/version-selector.tsx` — displays `label` or falls back to `id.slice(0,8)` if `semver` is null
- `app/submission/[id]/page.tsx` — shows version info
- `app/runs/page.tsx` — shows version in runs table
- `app/about/page.tsx` — updated documentation explaining the versioning scheme

---

## Pre-flight Checklist

Before starting, verify:

- [ ] D1 backup taken (Cloudflare dashboard → D1 → your database → Backups)
- [ ] Staging environment available to test the full flow
- [ ] You have `wrangler` CLI installed and authenticated
- [ ] You know the production D1 database ID
- [ ] Monitor dashboards ready for submission volume and error rate

---

## Monitoring After Migration

### What to watch
- `GET /api/benchmark_versions` response time
- Submission success rate (errors in results submission)
- Version selector UI in leaderboard
- Any JavaScript errors in the browser console on leaderboard pages

### Common issues

**Leaderboard shows "undefined" for version**
→ The API isn't returning the new fields yet. Check that all api PRs are merged and deployed.

**Submissions failing with version errors**
→ Old skill clients may be sending malformed versions. The API accepts any string, but verify the frontend validation isn't blocking hashes.

**Legacy versions still showing as git hashes**
→ The backfill script didn't run, or ran on the wrong database. Check D1 directly:
```sql
SELECT id, semver, label FROM benchmark_versions LIMIT 10;
```

---

## PR Summary

| Repo | PR | Title | Merge Order |
|------|-----|-------|-------------|
| skill | [#109](https://github.com/pinchbench/skill/pull/109) | Add GitHub Actions release workflow | 1 |
| skill | [#110](https://github.com/pinchbench/skill/pull/110) | Fix BENCHMARK_VERSION and add setuptools-scm | 2 |
| skill | [#111](https://github.com/pinchbench/skill/pull/111) | Replace _get_git_version with _get_benchmark_version | 3 |
| api | [#33](https://github.com/pinchbench/api/pull/33) | Add semver columns and migration to benchmark_versions | 4 |
| api | [#32](https://github.com/pinchbench/api/pull/32) | Backfill legacy versions with semver labels | 5 (run D1 migration first) |
| api | [#35](https://github.com/pinchbench/api/pull/35) | Add semver fields and sorting to benchmarkVersions routes | 6 |
| api | [#34](https://github.com/pinchbench/api/pull/34) | Add semver fields to benchmark versions API routes | 6 (parallel with #35) |
| leaderboard | [#70](https://github.com/pinchbench/leaderboard/pull/70) | Add semver fields to BenchmarkVersion type | 7 |
| leaderboard | [#73](https://github.com/pinchbench/leaderboard/pull/73) | Update version-selector.tsx to display label instead of hash | 8 |
| leaderboard | [#74](https://github.com/pinchbench/leaderboard/pull/74) | Update about page with semver versioning documentation | 8 |

---

## Contact

If something goes wrong during deployment, check the Cloudflare Workers logs:
```bash
wrangler tail pinchbench-api
```
