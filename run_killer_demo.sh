#!/usr/bin/env bash
# Killer demo walkthrough (local steps 1–6 + receipt verify; Slack/GitHub deferred).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
ESPERA="$REPO_ROOT/target/debug/espera"

if [[ ! -x "$ESPERA" ]]; then
  echo "Building espera..."
  cargo build --manifest-path "$REPO_ROOT/apps/cli/Cargo.toml" -q
fi
if [[ ! -x "$REPO_ROOT/target/debug/espera-shim" ]]; then
  cargo build --manifest-path "$REPO_ROOT/apps/shim/Cargo.toml" -q
fi

"$ESPERA" setup 2>/dev/null || "$ESPERA" setup
"$ESPERA" doctor

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rsync -a --exclude '.git' --exclude '.env' "$ROOT/" "$TMP/"
cd "$TMP"
git init -q
git config user.email "demo@example.com"
git config user.name "Espera Demo"
git add -A
git commit -q -m "baseline"

echo "=== Step 1–2: run with default agent from espera.yaml ==="
"$ESPERA" run --auto-approve --intent "fix billing bug" sh -c 'echo "# fix" >> src/billing/stripe_webhook.py'

SESSION_DIR="$(ls -td "$HOME/.espera/sessions"/*/ | head -1)"
SESSION_ID="$(basename "$SESSION_DIR")"
echo "Session: $SESSION_ID"
echo "Billing action graph:"
grep -E 'billing|allow_sensitive' "$SESSION_DIR/action-graph.json" || true

echo
echo "=== Step 3–4: CI/CD change (require_approval) ==="
"$ESPERA" run --auto-approve --intent "update deploy workflow" sh -c 'echo "# change" >> .github/workflows/deploy.yml'
SESSION_DIR="$(ls -td "$HOME/.espera/sessions"/*/ | head -1)"
SESSION_ID="$(basename "$SESSION_DIR")"
grep -E 'require_approval|ci_cd' "$SESSION_DIR/action-graph.json" || true

echo
echo "=== Step 5: block .env read via shim ==="
printf 'SECRET=1\n' > .env
mkdir -p scripts
printf '#!/bin/sh\ncat .env\n' > scripts/cat_env.sh
chmod +x scripts/cat_env.sh
git add -A
git commit -q -m "env fixture"
set +e
"$ESPERA" run --auto-approve --intent "read env" sh -c 'sleep 1; bash scripts/cat_env.sh'
set -e
SESSION_DIR="$(ls -td "$HOME/.espera/sessions"/*/ | head -1)"
SESSION_ID="$(basename "$SESSION_DIR")"
grep -E 'blocked|secret_file_read' "$SESSION_DIR/action-graph.json" || true

echo
echo "=== Step 9 (local): verify signed receipt ==="
"$ESPERA" verify "$SESSION_ID"

echo
echo "Killer demo complete (local). Deferred: Slack approval card, GitHub required check."
