/**
 * Minimal stdio MCP server for tests: initialize + tools/list + tools/call.
 * Set ESPERA_FAKE_TOOLS_JSON to a tools/list result JSON file path.
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

function loadTools(): unknown {
  const path = Deno.env.get("ESPERA_FAKE_TOOLS_JSON");
  if (path) {
    return JSON.parse(Deno.readTextFileSync(path));
  }
  return {
    tools: [
      {
        name: "read_file",
        description: "Read a file from disk",
        inputSchema: { type: "object", properties: { path: { type: "string" } } },
      },
      {
        name: "list_directory",
        description: "List directory contents",
        inputSchema: { type: "object", properties: { path: { type: "string" } } },
      },
    ],
  };
}

function handleToolCall(name: string, args: Record<string, unknown>): unknown {
  console.error(`fake-filesystem-mcp: tools/call invoked: ${name}`);
  if (name === "read_file") {
    const path = String(args.path ?? "");
    if (path === "config/app.settings" || path.endsWith("config/app.settings")) {
      return {
        content: [{ type: "text", text: "API_KEY=fake-local-key-12345\nDEBUG=true\n" }],
      };
    }
    return {
      content: [{ type: "text", text: "SECRET=1" }],
    };
  }
  if (name === "list_directory") {
    const path = String(args.path ?? ".");
    return { entries: [`${path}/a.txt`] };
  }
  if (name === "create_pull_request") {
    return { content: [{ type: "text", text: "pr://123" }] };
  }
  return {};
}

const toolsResult = loadTools();

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
    await writeFrame(
      stdoutWriter,
      JSON.stringify(
        resultResponse(msg.id, {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "fake-filesystem-mcp", version: "0.1.0" },
        }),
      ),
    );
    continue;
  }
  if (msg.method === "tools/list") {
    await writeFrame(stdoutWriter, JSON.stringify(resultResponse(msg.id, toolsResult)));
    continue;
  }
  if (msg.method === "tools/call") {
    const params = (msg.params ?? {}) as { name?: string; arguments?: Record<string, unknown> };
    const result = handleToolCall(String(params.name ?? ""), params.arguments ?? {});
    await writeFrame(stdoutWriter, JSON.stringify(resultResponse(msg.id, result)));
    continue;
  }
  await writeFrame(
    stdoutWriter,
    JSON.stringify(resultResponse(msg.id, {})),
  );
}
