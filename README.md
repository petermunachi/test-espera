# test-espera

Adversarial fixture repository for dogfooding Espera (Phase 4+).

Remote: https://github.com/petermunachi/test-espera

## Fixtures

| Path | Purpose |
|------|---------|
| `espera.yaml` | Killer-demo policy config (`agent: echo`, `sensitive_paths`, `billing_path` → allow_sensitive, etc.) |
| `policy/base/rules.rego` | Config-driven OPA rules (reads `input.config`) |
| `.github/workflows/deploy.yml` | CI/CD path → `critical` / `ci_cd_path` |
| `src/billing/stripe_webhook.py` | Billing path → `high` / `billing_path` → `allow_sensitive` |
| `.env.example` | Secret-file pattern |
| `src/auth/login.rs` | Auth path classification |
| `terraform/main.tf` | IaC / trivy misconfig |
| `Cargo.lock` | Dependency scanner targets |
| `config.yml` | Gitleaks secret detection (created during tests) |
| `migrations/001_bad_delete.sql` | SQL migration → `sql_change:sqlparser:delete_without_where` |
| `src/db.py` | Embedded SQL in Python → AST extract + sqlparser |

**Note:** `block_db_writes` defaults to **off** in `espera.yaml` so dogfood SQL tests remain observe-only. Enable explicitly to block migration/shell DB writes (see `apps/cli/TESTING.md` Phase 11.2).

**Note:** `require_package_check` defaults to **off** so `dependency_change` dogfood assertions remain observe-only. When enabled, sessions notify on dependency file changes; optional `package_check_require_approval_on_vuln` pauses on CVE findings (see `apps/cli/TESTING.md` Phase 11.3).

## Dogfood from this directory

**Automated suite** (recommended — uses clean temp repos so git delta is reliable):

```bash
./run_dogfood_tests.sh
```

**Killer demo** (billing → CI/CD approval → shim block → receipt verify):

```bash
./run_killer_demo.sh
```

**Cargo integration test** (from repo root):

```bash
cargo test -p espera --test dogfood_e2e
```

### Manual steps (standalone clone)

```bash
espera setup
espera doctor

# Default agent from espera.yaml (agent: echo)
espera run --intent "dogfood"

# Working-tree dry-run (no agent)
espera scan --json

# Full-repo posture (no dirty files required)
espera scan --full

# CI/CD change (file must be committed before session, or created fresh)
espera run --intent "dogfood" \
  sh -- -c 'echo "# change" >> .github/workflows/deploy.yml'

# Billing edit (allow_sensitive in decisions[])
espera run --intent "billing" \
  sh -- -c 'echo "# fix" >> src/billing/stripe_webhook.py'

# Verify signed receipt
espera verify <session-id>
```

When developing inside the Espera monorepo (`examples/test-espera/`), use `./run_killer_demo.sh` or `./run_dogfood_tests.sh` — those copy the fixture into an isolated temp git repo because the monorepo root would otherwise be discovered as the policy root.

## Git delta note

Espera compares git status at **session start** vs **session end**. Only paths whose git status is **new or changed during the session** appear in the action graph. Files already modified or untracked at session start may not be reported even if the agent edits them again. Commit or clean the baseline before dogfood runs, or create files fresh inside the supervised command.

`espera scan` uses **working tree vs HEAD** semantics (all dirty paths), which differs from supervised session delta.

Check `report.json` for scanner `warnings` (e.g. OSV `parse_error` when a lockfile cannot be scanned).

## PR receipt conventions (Phase 1)

After a supervised session, prove the PR to the merge gate:

```bash
espera pr export --session-id <uuid>
git add .espera/pr && git commit -m "Add Espera receipt"
```

Add to the PR body:

```html
<!-- espera-session: <uuid> -->
```

Optional CI workflow artifact marker (see `.github/workflows/espera-receipt.yml`):

```html
<!-- espera-ci-run: owner/repo/<run_id> -->
```

Verify locally before opening a PR:

```bash
espera verify-artifacts --session-dir ~/.espera/sessions/<uuid> --commit-sha "$(git rev-parse HEAD)"
```
