#!/usr/bin/env bash
# Comprehensive Espera dogfood tests against test-espera fixtures.
# Each scenario uses a fresh temp git repo (clean baseline) so session delta is reliable.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
ESPERA="$REPO_ROOT/target/debug/espera"
FIXTURE_SRC="$ROOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass=0
fail=0
skip=0

log_pass() { echo -e "${GREEN}PASS${NC} $1"; pass=$((pass + 1)); }
log_fail() { echo -e "${RED}FAIL${NC} $1"; echo "       $2"; fail=$((fail + 1)); }
log_skip() { echo -e "${YELLOW}SKIP${NC} $1"; skip=$((skip + 1)); }

require_bin() {
  if [[ ! -x "$ESPERA" ]]; then
    echo "Building espera..."
    cargo build --manifest-path "$REPO_ROOT/apps/cli/Cargo.toml" -q
  fi
  if [[ ! -x "$REPO_ROOT/target/debug/espera-shim" ]]; then
    echo "Building espera-shim..."
    cargo build --manifest-path "$REPO_ROOT/apps/shim/Cargo.toml" -q
  fi
  if [[ ! -x "$REPO_ROOT/target/debug/espera-mcp-proxy" ]]; then
    if command -v deno >/dev/null 2>&1; then
      echo "Building espera-mcp-proxy..."
      "$REPO_ROOT/integrations/mcp-proxy/scripts/build.sh" >/dev/null
    else
      echo "WARN: deno not found; doctor may fail until espera-mcp-proxy is built" >&2
    fi
  fi
  "$ESPERA" setup --force -q 2>/dev/null || "$ESPERA" setup --force 2>/dev/null || true
  # Refresh shim if workspace build is newer than installed copy
  if [[ -x "$REPO_ROOT/target/debug/espera-shim" ]]; then
    mkdir -p "${ESPERA_HOME:-$HOME}/.espera/shim/bin"
    cp -f "$REPO_ROOT/target/debug/espera-shim" "${ESPERA_HOME:-$HOME}/.espera/shim/bin/espera-shim"
    chmod +x "${ESPERA_HOME:-$HOME}/.espera/shim/bin/espera-shim"
    "$ESPERA" setup --force -q 2>/dev/null || "$ESPERA" setup --force 2>/dev/null || true
  fi
}

init_fixture_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  # Copy fixture files (not .git)
  rsync -a --exclude '.git' --exclude '.env' "$FIXTURE_SRC/" "$dir/"
  cd "$dir"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Espera Test"
  git add -A
  git commit -q -m "baseline fixtures"
}

latest_session_dir() {
  local home="${ESPERA_HOME:-$HOME}"
  set +o pipefail
  ls -td "$home/.espera/sessions"/*/ 2>/dev/null | head -1
  set -o pipefail
}

run_session() {
  local intent="$1"
  shift
  set +e
  "$ESPERA" run --auto-approve --intent "$intent" "$@"
  set -e
}

run_session_expect_fail() {
  local intent="$1"
  shift
  set +e
  if "$ESPERA" run --auto-approve --intent "$intent" "$@"; then
    set -e
    log_fail "$intent" "expected non-zero exit"
    return 1
  fi
  set -e
  log_pass "$intent session blocked (non-zero exit)"
}

assert_graph_contains() {
  local label="$1"
  local pattern="$2"
  local graph_path
  graph_path="$(latest_session_dir)/action-graph.json"
  if [[ ! -f "$graph_path" ]]; then
    log_fail "$label" "no action-graph.json at $graph_path"
    return 1
  fi
  local graph
  graph="$(cat "$graph_path")"
  if echo "$graph" | grep -Fq "$pattern"; then
    log_pass "$label (matched: $pattern)"
    return 0
  fi
  log_fail "$label" "pattern '$pattern' not in graph:\n$(echo "$graph" | head -40)"
  return 1
}

assert_graph_contains_any() {
  local label="$1"
  shift
  local graph_path
  graph_path="$(latest_session_dir)/action-graph.json"
  if [[ ! -f "$graph_path" ]]; then
    log_fail "$label" "no action-graph.json at $graph_path"
    return 1
  fi
  local graph
  graph="$(cat "$graph_path")"
  local pattern
  for pattern in "$@"; do
    if echo "$graph" | grep -Fq "$pattern"; then
      log_pass "$label (matched: $pattern)"
      return 0
    fi
  done
  log_fail "$label" "none of ($*) in graph:\n$(echo "$graph" | head -40)"
  return 1
}

assert_report_ok() {
  local label="$1"
  local report_path
  report_path="$(latest_session_dir)/report.json"
  if [[ ! -f "$report_path" ]]; then
    log_fail "$label report" "missing report.json"
    return 1
  fi
  local exit_code
  exit_code="$(python3 -c "import json; print(json.load(open('$report_path'))['exit_code'])" 2>/dev/null || echo "missing")"
  if [[ "$exit_code" == "0" ]]; then
    log_pass "$label session exit 0"
  else
    log_fail "$label report" "exit_code=$exit_code"
  fi
}

latest_session_id() {
  local dir
  dir="$(latest_session_dir)"
  basename "$dir"
}

assert_receipt_verified() {
  local label="$1"
  local session_id
  session_id="$(latest_session_id)"
  if [[ -z "$session_id" || "$session_id" == "." ]]; then
    log_fail "$label receipt" "no session id"
    return 1
  fi
  if "$ESPERA" verify "$session_id" >/tmp/espera_verify.out 2>&1; then
    log_pass "$label receipt verified ($session_id)"
    return 0
  fi
  log_fail "$label receipt" "$(cat /tmp/espera_verify.out)"
  return 1
}

echo "=== Espera test-espera dogfood suite ==="
echo "Fixture repo: $FIXTURE_SRC"
echo

require_bin

echo "--- doctor ---"
if "$ESPERA" doctor 2>&1 | tee /tmp/espera_doctor.out; then
  if grep -q "In-process analyzers" /tmp/espera_doctor.out \
    && grep -q "ast-rust" /tmp/espera_doctor.out \
    && grep -q "sqlparser" /tmp/espera_doctor.out \
    && grep -q "shellcheck" /tmp/espera_doctor.out \
    && grep -q "All in-process analyzers are ready" /tmp/espera_doctor.out \
    && grep -q "MCP proxy (Phase 2.1)" /tmp/espera_doctor.out \
    && grep -q "MCP proxy is ready" /tmp/espera_doctor.out \
    && grep -q "Posture scan (read-only smoke)" /tmp/espera_doctor.out \
    && grep -q "sweep cache dir: ok" /tmp/espera_doctor.out; then
    log_pass "doctor (bundled + in-process)"
  else
    log_fail "doctor" "missing in-process section or not all ok"
  fi
else
  log_fail "doctor" "doctor exited non-zero"
fi
echo

# --- Scenario tests (each in fresh repo) ---
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

test_ci_cd() {
  local dir="$TMPBASE/ci-cd"
  init_fixture_repo "$dir"
  run_session "dogfood-ci-cd" sh -c 'echo "# session change" >> .github/workflows/deploy.yml'
  assert_report_ok "ci-cd"
  assert_graph_contains "ci-cd critical risk" '"risk": "critical"'
  assert_graph_contains "ci-cd path reason" "ci_cd_path"
  assert_graph_contains "ci-cd deploy.yml" "deploy.yml"
  assert_graph_contains "ci-cd policy approval" '"action": "require_approval"'
}

test_billing_sensitive() {
  local dir="$TMPBASE/billing"
  init_fixture_repo "$dir"
  run_session "dogfood-billing" sh -c 'echo "# fix" >> src/billing/stripe_webhook.py'
  assert_report_ok "billing"
  assert_graph_contains "billing path reason" "billing_path"
  assert_graph_contains "billing stripe_webhook" "stripe_webhook.py"
  assert_graph_contains "billing allow_sensitive" '"action": "allow_sensitive"'
}

test_sql_migration() {
  local dir="$TMPBASE/sql-migration"
  init_fixture_repo "$dir"
  run_session "dogfood-sql" sh -c 'mkdir -p migrations && echo "DELETE FROM users;" > migrations/002_session.sql'
  assert_report_ok "sql-migration"
  assert_graph_contains "sql migration path" "002_session.sql"
  assert_graph_contains "sql delete_without_where" "delete_without_where"
  assert_graph_contains "sql critical" '"risk": "critical"'
}

test_python_embedded_sql() {
  local dir="$TMPBASE/python-sql"
  init_fixture_repo "$dir"
  run_session "dogfood-python-sql" sh -c 'mkdir -p src && printf "def f(c):\n    c.execute(\"DELETE FROM accounts\")\n" > src/session_db.py'
  assert_report_ok "python-sql"
  assert_graph_contains "python sql path" "session_db.py"
  assert_graph_contains "python sqlparser finding" "sqlparser:delete:delete_without_where"
}

test_gitleaks_secret() {
  local dir="$TMPBASE/gitleaks"
  init_fixture_repo "$dir"
  run_session "dogfood-secret" sh -c 'printf "api_key=sk-live-test1234567890\n" > leaked.yml'
  assert_report_ok "gitleaks"
  assert_graph_contains "gitleaks path" "leaked.yml"
  # gitleaks enrichment or at least secret_file classification
  if assert_graph_contains_any "gitleaks or secret" gitleaks secret_file; then
    :
  fi
}

test_auth_path() {
  local dir="$TMPBASE/auth"
  init_fixture_repo "$dir"
  run_session "dogfood-auth" sh -c 'mkdir -p src/auth && echo "// change" >> src/auth/login.rs'
  assert_report_ok "auth"
  assert_graph_contains "auth path" "src/auth/login.rs"
  assert_graph_contains "auth reason" "auth_path"
  assert_graph_contains "auth codeowner" '"action": "require_codeowner"'
}

test_shim_redact() {
  local dir="$TMPBASE/shim-redact"
  init_fixture_repo "$dir"
  run_session "dogfood-redact" sh -c 'sleep 1; cat config/app.settings'
  assert_report_ok "shim-redact"
  assert_graph_contains "redact decision" '"action": "redact"'
  assert_receipt_verified "shim-redact"
}

test_mint_credential() {
  local dir="$TMPBASE/mint"
  init_fixture_repo "$dir"
  cd "$dir"
  sed -i.bak 's/block_package_publish: true/block_package_publish: false/' espera.yaml
  rm -f espera.yaml.bak
  git add espera.yaml
  git commit -q -m "allow publish mint" || true
  run_session "dogfood-mint" sh -c 'npm publish --dry-run 2>/dev/null || npm publish 2>/dev/null || true'
  assert_graph_contains "mint decision" "mint_scoped_credential"
  assert_graph_contains "mint metadata" "minted_credentials"
  assert_receipt_verified "mint"
}

test_iac_terraform() {
  local dir="$TMPBASE/iac"
  init_fixture_repo "$dir"
  run_session "dogfood-iac" sh -c 'echo "# change" >> terraform/main.tf'
  assert_report_ok "iac"
  assert_graph_contains "iac path" "terraform/main.tf"
  assert_graph_contains "iac reason" "iac_change"
}

test_cargo_lock() {
  local dir="$TMPBASE/deps"
  init_fixture_repo "$dir"
  run_session "dogfood-deps" sh -c 'echo "# touch" >> Cargo.lock'
  assert_report_ok "cargo-lock"
  assert_graph_contains "cargo.lock path" "Cargo.lock"
  assert_graph_contains "dependency reason" "dependency_change"
}

test_env_touch() {
  local dir="$TMPBASE/env-touch"
  init_fixture_repo "$dir"
  run_session "dogfood-env" sh -c 'printf "API_KEY=session-%s\n" "$$" > .env'
  assert_report_ok "env-touch"
  assert_graph_contains "env path" ".env"
  assert_graph_contains "env secret_file" "secret_file"
  if assert_graph_contains_any "env file_write or file_read" file_write file_read; then
    :
  fi
}

test_shell_guard() {
  local dir="$TMPBASE/shell-guard"
  init_fixture_repo "$dir"
  run_session_expect_fail "dogfood-shell" sh -c 'printf "" > .env && cat .env'
  assert_graph_contains "shell secret_file_read" "secret_file_read"
  assert_graph_contains "shell command type" "shell_command"
  assert_graph_contains "shell block decision" '"action": "block"'
}

test_shim_nested_cat_env() {
  local dir="$TMPBASE/shim-nested"
  init_fixture_repo "$dir"
  printf 'SECRET=1\n' > "$dir/.env"
  mkdir -p "$dir/scripts"
  printf '#!/bin/sh\ncat .env\n' > "$dir/scripts/cat_env.sh"
  chmod +x "$dir/scripts/cat_env.sh"
  cd "$dir"
  git add -A
  git commit -q -m "env and script"
  run_session_expect_fail "dogfood-shim-nested" sh -c 'sleep 1; bash scripts/cat_env.sh'
  assert_graph_contains "shim secret_file_read" "secret_file_read"
  assert_graph_contains "shim blocked status" '"status": "blocked"'
}

test_shellcheck_script() {
  local dir="$TMPBASE/shellcheck"
  init_fixture_repo "$dir"
  run_session "dogfood-shellcheck" sh -c 'printf "#!/bin/bash\necho \$UNQUOTED\n# session-%s\n" "$$" > scripts/risky.sh'
  assert_report_ok "shellcheck"
  assert_graph_contains "shellcheck path" "scripts/risky.sh"
  assert_graph_contains "shellcheck finding" "shellcheck:SC"
  assert_receipt_verified "shellcheck"
}

test_espera_scan() {
  local dir="$TMPBASE/scan"
  init_fixture_repo "$dir"
  cd "$dir"
  echo "# scan change" >> src/billing/stripe_webhook.py
  local out
  out="$("$ESPERA" scan --json 2>&1)" || true
  if echo "$out" | grep -Fq "billing_path"; then
    log_pass "espera scan billing_path"
  else
    log_fail "espera scan" "billing_path not in output:\n$(echo "$out" | head -20)"
  fi
}

test_espera_scan_posture() {
  local dir="$TMPBASE/scan-posture"
  init_fixture_repo "$dir"
  cd "$dir"
  local out
  out="$("$ESPERA" scan --json 2>&1)" || true
  if ! command -v jq >/dev/null 2>&1; then
    log_skip "espera scan posture shape (jq not installed)"
    return 0
  fi
  local json
  json="$(echo "$out" | jq -c . 2>/dev/null)" || {
    log_fail "espera scan posture" "invalid JSON:\n$(echo "$out" | head -20)"
    return 0
  }
  local version wt_paths
  version="$(echo "$json" | jq -r '.scan_version // empty')"
  wt_paths="$(echo "$json" | jq '.repo.working_tree.paths | length')"
  if [[ "$version" != "1" ]]; then
    log_fail "espera scan posture" "scan_version=$version (expected 1)"
    return 0
  fi
  if ! echo "$json" | jq -e '.machine.agents | type == "array"' >/dev/null; then
    log_fail "espera scan posture" "machine.agents missing or not array"
    return 0
  fi
  if ! echo "$json" | jq -e '.machine.mcp_servers | type == "array"' >/dev/null; then
    log_fail "espera scan posture" "machine.mcp_servers missing or not array"
    return 0
  fi
  if [[ "$wt_paths" != "0" ]]; then
    log_fail "espera scan posture" "working_tree.paths length=$wt_paths (expected 0 on clean repo)"
    return 0
  fi
  if ! echo "$json" | jq -e '.recommendations | length > 0' >/dev/null; then
    log_fail "espera scan posture" "recommendations array empty"
    return 0
  fi
  if ! echo "$json" | jq -e '.repo.posture.policy_gaps | length > 0' >/dev/null; then
    log_fail "espera scan posture" "policy_gaps missing or empty"
    return 0
  fi
  log_pass "espera scan posture JSON shape"
}

test_espera_scan_full() {
  local dir="$TMPBASE/scan-full"
  init_fixture_repo "$dir"
  cd "$dir"
  printf 'SECRET=1\n' > .env
  local out
  out="$("$ESPERA" scan --repo-only --full --json 2>/dev/null)" || true
  if ! command -v jq >/dev/null 2>&1; then
    log_skip "espera scan full (jq not installed)"
    return 0
  fi
  local json
  json="$(echo "$out" | jq -c . 2>/dev/null)" || {
    log_fail "espera scan full" "invalid JSON:\n$(echo "$out" | head -20)"
    return 0
  }
  if ! echo "$json" | jq -e '.repo.sweep.mode == "full"' >/dev/null; then
    log_fail "espera scan full" "repo.sweep.mode missing or not full"
    return 0
  fi
  if ! echo "$json" | jq -e '.repo.posture.secret_files | index(".env")' >/dev/null 2>&1; then
    if ! echo "$json" | jq -e '[.repo.posture.secret_files[] | select(test("\\.env$"))] | length > 0' >/dev/null; then
      log_fail "espera scan full" "expected .env in posture.secret_files"
      return 0
    fi
  fi
  if ! echo "$json" | jq -e '[.repo.posture.cicd_files[] | select(test("deploy.yml"))] | length > 0' >/dev/null; then
    log_fail "espera scan full" "expected deploy.yml in posture.cicd_files"
    return 0
  fi
  if ! echo "$json" | jq -e '.recommendations | length > 0' >/dev/null; then
    log_fail "espera scan full" "recommendations empty"
    return 0
  fi
  log_pass "espera scan full-repo posture"
}

test_espera_scan_machine() {
  if ! command -v jq >/dev/null 2>&1; then
    log_skip "espera scan machine-only (jq not installed)"
    return 0
  fi
  local home="$TMPBASE/machine-home"
  rm -rf "$home"
  mkdir -p "$home"
  cp -R "$FIXTURE_SRC/posture/machine/home/." "$home/"
  local out
  out="$(HOME="$home" "$ESPERA" scan --machine-only --json 2>&1)" || true
  local json
  json="$(echo "$out" | jq -c . 2>/dev/null)" || {
    log_fail "espera scan machine" "invalid JSON:\n$(echo "$out" | head -20)"
    return 0
  }
  local mcp_len
  mcp_len="$(echo "$json" | jq '.machine.mcp_servers | length')"
  if [[ "$mcp_len" -lt 1 ]]; then
    log_fail "espera scan machine" "expected MCP servers in machine-only scan"
    return 0
  fi
  if echo "$json" | jq -e '.repo != null' >/dev/null 2>&1; then
    log_fail "espera scan machine" "repo should be omitted in machine-only mode"
    return 0
  fi
  log_pass "espera scan machine-only JSON"
}

test_espera_scan_markdown() {
  local dir="$TMPBASE/scan-markdown"
  init_fixture_repo "$dir"
  cd "$dir"
  local report="$dir/posture.md"
  local out
  out="$("$ESPERA" scan --format markdown -o "$report" 2>&1)" || true
  if [[ ! -f "$report" ]]; then
    log_fail "espera scan markdown" "report not written:\n$out"
    return 0
  fi
  if ! grep -Fq '# espera scan' "$report"; then
    log_fail "espera scan markdown" "missing markdown title in $report"
    return 0
  fi
  if ! grep -Fq '## Detected' "$report"; then
    log_fail "espera scan markdown" "missing ## Detected section"
    return 0
  fi
  if ! grep -Fq '## Recommended' "$report"; then
    log_fail "espera scan markdown" "missing ## Recommended section"
    return 0
  fi
  log_pass "espera scan markdown report"
}

test_espera_scan_multi_repo() {
  if ! command -v jq >/dev/null 2>&1; then
    log_skip "espera scan multi-repo (jq not installed)"
    return 0
  fi
  local codebase="$TMPBASE/code-portfolio"
  rm -rf "$codebase"
  mkdir -p "$codebase/risky/.github/workflows" "$codebase/risky/policy/base" "$codebase/clean/policy/base"
  cp "$FIXTURE_SRC/espera.yaml" "$codebase/risky/"
  cp "$FIXTURE_SRC/espera.yaml" "$codebase/clean/"
  cp -R "$FIXTURE_SRC/policy/base/." "$codebase/risky/policy/base/"
  cp -R "$FIXTURE_SRC/policy/base/." "$codebase/clean/policy/base/"
  printf '# risky\nRun with espera run echo\n' > "$codebase/risky/README.md"
  printf '# clean\nRun with espera run echo\n' > "$codebase/clean/README.md"
  cat > "$codebase/risky/.github/workflows/ai-agent.yml" <<'EOF'
name: ai
on: push
jobs:
  fix:
    runs-on: ubuntu-latest
    steps:
      - run: claude -p "fix the bug"
EOF
  for repo in risky clean; do
    cd "$codebase/$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git add .
    git commit -q -m "baseline"
  done
  local out
  out="$("$ESPERA" scan --repos "$codebase" --format json 2>/dev/null)" || true
  local json
  json="$(echo "$out" | jq -c . 2>/dev/null)" || {
    log_fail "espera scan multi-repo" "invalid JSON:\n$(echo "$out" | head -20)"
    return 0
  }
  local scanned unwrapped
  scanned="$(echo "$json" | jq '.summary.repos_scanned')"
  unwrapped="$(echo "$json" | jq '.summary.repos_with_ci_agent_unwrapped')"
  if [[ "$scanned" != "2" ]]; then
    log_fail "espera scan multi-repo" "repos_scanned=$scanned (expected 2)"
    return 0
  fi
  if [[ "$unwrapped" != "1" ]]; then
    log_fail "espera scan multi-repo" "repos_with_ci_agent_unwrapped=$unwrapped (expected 1)"
    return 0
  fi
  log_pass "espera scan multi-repo portfolio"
}

test_espera_scan_agent_protection() {
  local dir="$TMPBASE/scan-agent-protection"
  rm -rf "$dir"
  mkdir -p "$dir/policy/base" "$dir/.github/workflows"
  cp "$FIXTURE_SRC/espera.yaml" "$dir/"
  cp -R "$FIXTURE_SRC/policy/base/." "$dir/policy/base/"
  printf '# test\nRun with espera run echo\n' > "$dir/README.md"
  cat > "$dir/.github/workflows/ai-agent.yml" <<'EOF'
name: ai
on: push
jobs:
  fix:
    runs-on: ubuntu-latest
    steps:
      - run: claude -p "fix the bug"
EOF
  cd "$dir"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  git add .
  git commit -q -m "baseline"
  local out
  out="$("$ESPERA" scan --json 2>/dev/null)" || true
  if ! command -v jq >/dev/null 2>&1; then
    log_skip "espera scan agent protection (jq not installed)"
    return 0
  fi
  local json
  json="$(echo "$out" | jq -c . 2>/dev/null)" || {
    log_fail "espera scan agent protection" "invalid JSON:\n$(echo "$out" | head -20)"
    return 0
  }
  if ! echo "$json" | jq -e '.repo.posture.policy_gaps | index("ci_agent_unwrapped")' >/dev/null; then
    log_fail "espera scan agent protection" "expected ci_agent_unwrapped in policy_gaps"
    return 0
  fi
  if ! echo "$json" | jq -e '.recommendations[] | select(.id == "wrap_ci_agents")' >/dev/null; then
    log_fail "espera scan agent protection" "expected wrap_ci_agents recommendation"
    return 0
  fi
  log_pass "espera scan agent protection (ci_agent_unwrapped)"
}

test_espera_scan_sarif() {
  if ! command -v jq >/dev/null 2>&1; then
    log_skip "espera scan sarif (jq not installed)"
    return 0
  fi
  local codebase="$TMPBASE/code-sarif"
  rm -rf "$codebase"
  mkdir -p "$codebase/a/policy/base" "$codebase/b/policy/base"
  cp "$FIXTURE_SRC/espera.yaml" "$codebase/a/"
  cp "$FIXTURE_SRC/espera.yaml" "$codebase/b/"
  cp -R "$FIXTURE_SRC/policy/base/." "$codebase/a/policy/base/"
  cp -R "$FIXTURE_SRC/policy/base/." "$codebase/b/policy/base/"
  printf '# a\nRun with espera run echo\n' > "$codebase/a/README.md"
  printf '# b\nRun with espera run echo\n' > "$codebase/b/README.md"
  for repo in a b; do
    cd "$codebase/$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    git add .
    git commit -q -m "baseline"
  done
  local sarif="$TMPBASE/portfolio.sarif"
  if ! "$ESPERA" scan --repos "$codebase" --sarif -o "$sarif" >/dev/null 2>&1; then
    log_fail "espera scan sarif" "scan command failed"
    return 0
  fi
  local runs
  runs="$(jq '.runs | length' "$sarif" 2>/dev/null)" || {
    log_fail "espera scan sarif" "invalid SARIF JSON"
    return 0
  }
  if [[ "$runs" != "2" ]]; then
    log_fail "espera scan sarif" "runs=$runs (expected 2)"
    return 0
  fi
  log_pass "espera scan portfolio SARIF"
}

test_espera_scan_launch_timing() {
  local dir="$TMPBASE/scan-launch-timing"
  init_fixture_repo "$dir"
  cd "$dir"
  local start end elapsed
  start=$(date +%s)
  if ! "$ESPERA" scan --repo-only --full --json >/dev/null 2>&1; then
    log_fail "espera scan launch timing" "scan command failed"
    return 0
  fi
  end=$(date +%s)
  elapsed=$((end - start))
  if [[ "$elapsed" -gt 30 ]]; then
    log_fail "espera scan launch timing" "took ${elapsed}s (expected <=30s)"
    return 0
  fi
  log_pass "espera scan launch timing (${elapsed}s)"
}

test_killer_demo_chain() {
  local dir="$TMPBASE/killer-demo"
  init_fixture_repo "$dir"
  cd "$dir"
  run_session "killer-billing" sh -c 'echo "# fix" >> src/billing/stripe_webhook.py'
  assert_graph_contains "killer billing allow_sensitive" '"action": "allow_sensitive"'
  assert_receipt_verified "killer-billing"
  run_session "killer-cicd" sh -c 'echo "# deploy" >> .github/workflows/deploy.yml'
  assert_graph_contains "killer cicd approval" '"action": "require_approval"'
  assert_receipt_verified "killer-cicd"
  printf 'SECRET=1\n' > .env
  mkdir -p scripts
  printf '#!/bin/sh\ncat .env\n' > scripts/cat_env.sh
  chmod +x scripts/cat_env.sh
  git add -A
  git commit -q -m "env and script"
  run_session_expect_fail "killer-shim-block" sh -c 'sleep 1; bash scripts/cat_env.sh'
  assert_graph_contains "killer shim block" '"status": "blocked"'
  assert_receipt_verified "killer-shim-block"
}

test_default_agent_from_yaml() {
  local dir="$TMPBASE/default-agent"
  init_fixture_repo "$dir"
  cd "$dir"
  set +e
  "$ESPERA" run --auto-approve --intent "default agent yaml"
  set -e
  assert_report_ok "default-agent"
  assert_graph_contains "default agent echo" '"agent": "echo"'
}

test_shell_guard_e2e() {
  echo "--- shell_guard_e2e (cargo test) ---"
  if (cd "$REPO_ROOT" && cargo test -p espera-analyzers --test shell_guard_e2e -q) 2>&1; then
    log_pass "shell_guard_e2e tests"
  else
    log_fail "shell_guard_e2e" "cargo test failed"
  fi
}

test_fs_watcher_e2e() {
  echo "--- fs_watcher_e2e (cargo test) ---"
  if (cd "$REPO_ROOT" && cargo test -p espera-analyzers --test fs_watcher_e2e -q) 2>&1; then
    log_pass "fs_watcher_e2e tests"
  else
    log_fail "fs_watcher_e2e" "cargo test failed"
  fi
}

test_in_process_e2e() {
  echo "--- in_process_e2e (cargo test) ---"
  if (cd "$REPO_ROOT" && cargo test -p espera-analyzers --test in_process_e2e -q) 2>&1; then
    log_pass "in_process_e2e unit tests"
  else
    log_fail "in_process_e2e" "cargo test failed"
  fi
}

test_scanner_e2e() {
  echo "--- scanner_e2e (cargo test) ---"
  if (cd "$REPO_ROOT" && cargo test -p espera-analyzers --test scanner_e2e -q) 2>&1; then
    log_pass "scanner_e2e tests"
  else
    log_fail "scanner_e2e" "cargo test failed (run espera setup?)"
  fi
}

test_mcp_proxy_tools_list() {
  echo "--- mcp_proxy_tools_list_e2e (cargo test) ---"
  if ! command -v deno >/dev/null 2>&1; then
    log_skip "mcp_proxy_tools_list_e2e (deno not installed)"
    return 0
  fi
  if [[ ! -x "$REPO_ROOT/target/debug/espera-mcp-proxy" ]]; then
    "$REPO_ROOT/integrations/mcp-proxy/scripts/build.sh" >/dev/null
  fi
  if (cd "$REPO_ROOT" && cargo test -p espera --test mcp_proxy_tools_list_e2e -q) 2>&1; then
    log_pass "mcp_proxy_tools_list_e2e"
  else
    log_fail "mcp_proxy_tools_list_e2e" "cargo test failed"
  fi
}

test_mcp_proxy_block_env() {
  echo "--- mcp_proxy_tools_call_e2e (cargo test) ---"
  if ! command -v deno >/dev/null 2>&1; then
    log_skip "mcp_proxy_tools_call_e2e (deno not installed)"
    return 0
  fi
  if [[ ! -x "$REPO_ROOT/target/debug/espera-mcp-proxy" ]]; then
    "$REPO_ROOT/integrations/mcp-proxy/scripts/build.sh" >/dev/null
  fi
  if (cd "$REPO_ROOT" && cargo test -p espera --test mcp_proxy_tools_call_e2e -q) 2>&1; then
    log_pass "mcp_proxy_tools_call_e2e"
  else
    log_fail "mcp_proxy_tools_call_e2e" "cargo test failed"
  fi
}

test_mcp_proxy_session() {
  echo "--- mcp_proxy_session_e2e (cargo test) ---"
  if ! command -v deno >/dev/null 2>&1; then
    log_skip "mcp_proxy_session_e2e (deno not installed)"
    return 0
  fi
  if [[ ! -x "$REPO_ROOT/target/debug/espera-mcp-proxy" ]]; then
    "$REPO_ROOT/integrations/mcp-proxy/scripts/build.sh" >/dev/null
  fi
  if [[ ! -x "$REPO_ROOT/target/debug/espera-shim" ]]; then
    (cd "$REPO_ROOT" && cargo build -p espera-shim -q)
  fi
  if (cd "$REPO_ROOT" && cargo test -p espera --test mcp_proxy_session_e2e -q) 2>&1; then
    log_pass "mcp_proxy_session_e2e"
  else
    log_fail "mcp_proxy_session_e2e" "cargo test failed"
  fi
}

test_ci_cd
test_billing_sensitive
test_env_touch
test_shell_guard
test_shim_nested_cat_env
test_shellcheck_script
test_sql_migration
test_python_embedded_sql
test_gitleaks_secret
test_auth_path
test_shim_redact
test_mint_credential
test_iac_terraform
test_cargo_lock
test_espera_scan
test_espera_scan_posture
test_espera_scan_full
test_espera_scan_machine
test_espera_scan_markdown
test_espera_scan_multi_repo
test_espera_scan_agent_protection
test_espera_scan_sarif
test_espera_scan_launch_timing
test_killer_demo_chain
test_default_agent_from_yaml
test_shell_guard_e2e
test_fs_watcher_e2e
test_in_process_e2e
test_scanner_e2e
test_mcp_proxy_tools_list
test_mcp_proxy_block_env
test_mcp_proxy_session

echo
echo "=== Summary: $pass passed, $fail failed, $skip skipped ==="
if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
