# Migration Plan: Git Hash → SemVer Versioning

**Issue:** [pinchbench/skill#62](https://github.com/pinchbench/skill/issues/62)

**Goal:** Replace opaque git hashes (`a1b2c3d`) with semantic versions (`1.0.0`) across all PinchBench components.

---

## Overview

PinchBench currently uses git commit hashes to identify benchmark versions. This migration switches to semantic versioning while maintaining backward compatibility with existing submissions.

**Version source of truth:** GitHub releases (git tags). The `BENCHMARK_VERSION` file is auto-updated by CI on each release.

---

## Phase 1: skill repo (version generation)

| Step | File | Change |
|------|------|--------|
| 1 | `pyproject.toml` | Add `setuptools-scm` for dynamic versioning from git tags |
| 2 | `BENCHMARK_VERSION` | New file containing `1.0.0` — auto-updated on each release |
| 3 | `.github/workflows/release.yml` | GitHub Action that updates `BENCHMARK_VERSION` when a release is published |
| 4 | `scripts/benchmark.py` | Replace `_get_git_version()` with `_get_benchmark_version()` using multi-strategy resolution |

**Version resolution order:**
1. `importlib.metadata` (for pip installs)
2. `BENCHMARK_VERSION` file (for cloned/downloaded)
3. `git describe --tags` (development fallback)
4. Git short hash (ultimate fallback)

---

## Phase 2: api repo (data layer)

| Step | File | Change |
|------|------|--------|
| 5 | `schema.sql` | Add `semver`, `label`, `release_notes`, `release_url` columns to `benchmark_versions` table |
| 6 | `migrations/` | SQL scripts to add columns and backfill existing hash versions as `1.0.0-beta.N` |
| 7 | `src/routes/benchmarkVersions.ts` | Return new fields, sort by semver |
| 8 | `src/routes/results.ts` | Accept any version format (backward compat with old clients) |
| 9 | `src/types.ts` | Update `BenchmarkVersion` type |

**Data migration:** Existing git-hash versions → `1.0.0-beta.1`, `1.0.0-beta.2`, etc.

---

## Phase 3: leaderboard repo (UI)

| Step | File | Change |
|------|------|--------|
| 10 | `lib/types.ts` | Add new fields to `BenchmarkVersion` interface |
| 11 | `components/version-selector.tsx` | Display `label` instead of `id.slice(0,8)`, use Tag icon for semver |
| 12 | `app/submission/[id]/page.tsx` | Update version display |
| 13 | `app/runs/page.tsx` | Update version display |
| 14 | `app/about/page.tsx` | Update versioning documentation |

---

## Dependency Order

```
skill (4 files)
    ↓
api schema + migrations
    ↓
api routes + types    ←→    leaderboard types
    ↓
leaderboard UI
```

---

## Database Schema Changes

### benchmark_versions table (new columns)

```sql
ALTER TABLE benchmark_versions ADD COLUMN semver TEXT;
ALTER TABLE benchmark_versions ADD COLUMN label TEXT;
ALTER TABLE benchmark_versions ADD COLUMN release_notes TEXT;
ALTER TABLE benchmark_versions ADD COLUMN release_url TEXT;
CREATE INDEX IF NOT EXISTS idx_benchmark_versions_semver ON benchmark_versions(semver);
```

### Legacy version mapping

Existing git-hash versions are migrated to:
- `1.0.0-beta.1`, `1.0.0-beta.2`, etc.
- Ordered by `created_at` ascending

---

## API Response Shape

### GET /api/benchmark_versions

**New version:**
```json
{
  "id": "1.0.0",
  "semver": "1.0.0",
  "label": "1.0.0",
  "release_notes": "## What's Changed\n- Initial stable release...",
  "release_url": "https://github.com/pinchbench/skill/releases/tag/v1.0.0",
  "created_at": "...",
  "is_current": true,
  "submission_count": 42
}
```

**Legacy version (git hash):**
```json
{
  "id": "a1b2c3d",
  "semver": "1.0.0-beta.5",
  "label": "1.0.0-beta.5",
  "release_notes": null,
  "release_url": null,
  "created_at": "...",
  "is_current": false,
  "submission_count": 15
}
```

---

## Backward Compatibility

| Scenario | Handling |
|----------|----------|
| Old skill submits git hash | API accepts, stores as before, auto-creates version with null semver |
| New skill submits semver | API stores with `id` = semver |
| Frontend receives null semver | Falls back to `id.slice(0,8)` display |
| API filters by version | Works with both hash and semver IDs |
| Existing submissions | Unchanged, still link to their git-hash version |

---

## Release Process (post-migration)

1. Maintainer creates GitHub release with tag `v1.1.0`
2. GitHub Actions automatically updates `BENCHMARK_VERSION` file to `1.1.0`
3. Users who clone get the new `BENCHMARK_VERSION` file
4. Users who pip install get version from package metadata (via setuptools-scm)
5. First submission with new version auto-creates `benchmark_versions` record
6. Admin sets `current = 1` for new version when ready to make it default
7. Admin optionally adds `release_notes` and `release_url`

---

## Files Modified

### skill repo
- `pyproject.toml`
- `BENCHMARK_VERSION` (new)
- `.github/workflows/release.yml` (new)
- `scripts/benchmark.py`

### api repo
- `schema.sql`
- `migrations/YYYYMMDD_add_semver_columns.sql` (new)
- `migrations/YYYYMMDD_backfill_legacy_versions.sql` (new)
- `src/routes/benchmarkVersions.ts`
- `src/routes/results.ts`
- `src/types.ts`

### leaderboard repo
- `lib/types.ts`
- `components/version-selector.tsx`
- `app/submission/[id]/page.tsx`
- `app/runs/page.tsx`
- `app/about/page.tsx`
