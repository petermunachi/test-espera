/**
 * Minimal stdio MCP github server for credential mint e2e (Phase 2.19).
 * Tool get_me returns whether GITHUB_TOKEN is present (not the secret value).
 */

import { readFrame, writeFrame } from "../../../integrations/mcp-proxy/lib/transport.ts";
import {
  isRequest,
  parseMessage,
  resultResponse,
} from "../../../integrations/mcp-proxy/lib/jsonrpc.ts";

const stdinReader = {
  read(buf: Uint8Array) {
    return Deno.stdin.read(buf);
  },
};
const stdoutWriter = {
  write(data: Uint8Array) {
    return Deno.stdout.write(data);
  },
};

const toolsResult = {
  tools: [
    {
      name: "get_me",
      description: "Return authenticated user (requires GITHUB_TOKEN)",
      inputSchema: { type: "object", properties: {} },
    },
  ],
};

function handleToolCall(name: string): unknown {
  if (name === "get_me") {
    const token = Deno.env.get("GITHUB_TOKEN");
    if (!token) {
      return {
        isError: true,
        content: [{ type: "text", text: "GITHUB_TOKEN missing" }],
      };
    }
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ ok: true, token_present: true, login: "espera-test" }),
      }],
    };
  }
  return { content: [{ type: "text", text: "unknown tool" }] };
}

while (true) {
  let raw: string;
  try {
    raw = await readFrame(stdinReader);
  } catch {
    break;
  }
  const msg = parseMessage(raw);
  if (!isRequest(msg)) {
    continue;
  }
  if (msg.method === "initialize") {
    await writeFrame(stdoutWriter, JSON.stringify(resultResponse(msg.id!, {
      protocolVersion: "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "fake-github-mcp", version: "0.1.0" },
    })));
    continue;
  }
  if (msg.method === "tools/list") {
    await writeFrame(stdoutWriter, JSON.stringify(resultResponse(msg.id!, toolsResult)));
    continue;
  }
  if (msg.method === "tools/call") {
    const params = (msg.params ?? {}) as Record<string, unknown>;
    const name = String(params.name ?? "");
    const result = handleToolCall(name);
    await writeFrame(stdoutWriter, JSON.stringify(resultResponse(msg.id!, result)));
    continue;
  }
}
