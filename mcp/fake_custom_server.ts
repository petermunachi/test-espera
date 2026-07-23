/**
 * Minimal stdio MCP server for tests: exposes a distinct `ping` tool.
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
          serverInfo: { name: "fake-custom-mcp", version: "0.1.0" },
        }),
      ),
    );
    continue;
  }
  if (msg.method === "tools/list") {
    await writeFrame(
      stdoutWriter,
      JSON.stringify(
        resultResponse(msg.id, {
          tools: [
            {
              name: "ping",
              description: "Return a pong marker for routing tests",
              inputSchema: {
                type: "object",
                properties: { message: { type: "string" } },
              },
            },
          ],
        }),
      ),
    );
    continue;
  }
  if (msg.method === "tools/call") {
    const params = (msg.params ?? {}) as {
      name?: string;
      arguments?: Record<string, unknown>;
    };
    const name = String(params.name ?? "");
    if (name === "ping") {
      const message = String(params.arguments?.message ?? "pong");
      await writeFrame(
        stdoutWriter,
        JSON.stringify(
          resultResponse(msg.id, {
            content: [{ type: "text", text: `custom:${message}` }],
          }),
        ),
      );
      continue;
    }
    await writeFrame(stdoutWriter, JSON.stringify(resultResponse(msg.id, {})));
    continue;
  }
  await writeFrame(
    stdoutWriter,
    JSON.stringify(resultResponse(msg.id, {})),
  );
}
