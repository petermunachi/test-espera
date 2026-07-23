#!/usr/bin/env bash
# Harness agent for supervised MCP session e2e (Phase 2.4+).
# Uses ESPERA_MCP_UPSTREAM from espera run (Phase 2.8 zero-touch overlay).
set -euo pipefail

UPSTREAM="${ESPERA_MCP_UPSTREAM:?ESPERA_MCP_UPSTREAM required}"
ESPERA="${ESPERA_BIN:-espera}"
ACTION="${TEST_MCP_ACTION:-block_env}"

mcp_write() {
  local body="$1"
  printf '%s\n' "$body"
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"session-mcp-harness","version":"0.1.0"},"_meta":{"server":"filesystem"}}}'

case "$ACTION" in
  block_env)
    CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":".env"},"_meta":{"server":"filesystem"}}}'
    ;;
  allow_list)
    CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_directory","arguments":{"path":"src"},"_meta":{"server":"filesystem"}}}'
    ;;
  redact_config)
    CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"config/app.settings"},"_meta":{"server":"filesystem"}}}'
    ;;
  github_write)
    INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"session-mcp-harness","version":"0.1.0"},"_meta":{"server":"github"}}}'
    CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_pull_request","arguments":{"title":"test"},"_meta":{"server":"github"}}}'
    ;;
  mint_github_get_me)
    INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"session-mcp-harness","version":"0.1.0"},"_meta":{"server":"github"}}}'
    CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_me","arguments":{},"_meta":{"server":"github"}}}'
    ;;
  *)
    echo "unknown TEST_MCP_ACTION: $ACTION" >&2
    exit 1
    ;;
esac

{
  mcp_write "$INIT"
  mcp_write "$CALL"
} | "$ESPERA" mcp-proxy --config "$UPSTREAM" --listen stdio

exit 0
