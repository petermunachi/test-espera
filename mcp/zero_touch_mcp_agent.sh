#!/usr/bin/env bash
# Zero-touch MCP test agent (Phase 2.8): reads overlaid ~/.cursor/mcp.json like Cursor would.
set -euo pipefail

CONFIG="${HOME}/.cursor/mcp.json"
if [[ ! -f "$CONFIG" ]]; then
  echo "expected overlaid MCP config at $CONFIG" >&2
  exit 1
fi

ESPERA="${ESPERA_BIN:-espera}"
ACTION="${TEST_MCP_ACTION:-allow_list}"

UPSTREAM=$(python3 -c "
import json, os, sys
with open(os.path.expanduser('$CONFIG')) as f:
    j = json.load(f)
args = j['mcpServers']['espera']['args']
i = args.index('--config')
print(args[i + 1])
")

mcp_write() {
  printf '%s\n' "$1"
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"zero-touch-mcp-agent","version":"0.1.0"},"_meta":{"server":"filesystem"}}}'

case "$ACTION" in
  block_env)
    CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_file","arguments":{"path":".env"},"_meta":{"server":"filesystem"}}}'
    ;;
  allow_list)
    CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_directory","arguments":{"path":"src"},"_meta":{"server":"filesystem"}}}'
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
