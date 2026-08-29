#!/usr/bin/env node
// Patched HTTP entrypoint for @ric_/forgejo-mcp.
//
// Upstream dist/http.js (every published version through 0.1.7) builds ONE
// process-global StreamableHTTPServerTransport in stateful mode at startup and
// routes every /mcp request into it. There is no per-session transport map, so:
//   * a second `initialize` gets 400 -32600 "Server already initialized"
//   * a client's DELETE /mcp latches _closed on that shared transport, after
//     which every request returns 404 -32001 "Session not found", forever
// LiteLLM opens a fresh MCP session per call and sends DELETE on teardown, so it
// bricks the server on its first successful tool listing. /health is answered
// before the transport, so the pod stays Running and nothing restarts it.
//
// This entrypoint keeps a transport per session and evicts on close.

import { createServer as createHttpServer } from "node:http";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { parseCliArgs, resolveConfig } from "@ric_/forgejo-mcp/dist/config.js";
import { createServer } from "@ric_/forgejo-mcp/dist/server.js";

const require = createRequire(import.meta.url);
const version = require("@ric_/forgejo-mcp/package.json").version;

const cliArgs = parseCliArgs(process.argv.slice(2));
const config = resolveConfig(cliArgs);
const port = cliArgs.port || parseInt(process.env.PORT || "8080", 10);
const apiKey = process.env.FORGEJO_MCP_API_KEY;

const transports = new Map();

const json = (res, status, body) => {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
};

const httpServer = createHttpServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://localhost:${port}`);

  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("X-Frame-Options", "DENY");

  if (url.pathname === "/health") {
    return json(res, 200, { status: "ok", version });
  }

  if (url.pathname !== "/mcp") {
    return json(res, 404, { error: "Not found" });
  }

  if (apiKey && req.headers.authorization !== `Bearer ${apiKey}`) {
    return json(res, 401, {
      error: "Unauthorized. Provide Bearer token via Authorization header.",
    });
  }

  const sessionId = req.headers["mcp-session-id"];
  let transport = sessionId ? transports.get(sessionId) : undefined;

  if (!transport) {
    if (sessionId) {
      return json(res, 404, {
        jsonrpc: "2.0",
        error: { code: -32001, message: "Session not found" },
        id: null,
      });
    }
    transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (id) => {
        transports.set(id, transport);
      },
      onsessionclosed: (id) => {
        transports.delete(id);
      },
    });
    transport.onclose = () => {
      if (transport.sessionId) {
        transports.delete(transport.sessionId);
      }
    };
    await createServer(config).connect(transport);
  }

  await transport.handleRequest(req, res);
});

httpServer.listen(port, () => {
  console.error(`Forgejo MCP server (HTTP, per-session patch) listening on port ${port}`);
  console.error(`  MCP endpoint: http://localhost:${port}/mcp`);
  console.error(`  Health check: http://localhost:${port}/health`);
  console.error(`  Package: @ric_/forgejo-mcp@${version}`);
  console.error(`  Connected to: ${config.baseUrl}`);
  console.error(`  Authentication: ${apiKey ? "enabled (Bearer token)" : "DISABLED"}`);
});
