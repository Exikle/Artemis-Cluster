#!/usr/bin/env node
// Pod stand-in for the workstation headersHelper that .mcp.json names. Claude Code runs helpers
// without the pod env, so the tier key is read from the mounted secret file instead.
import { readFileSync } from "node:fs";

const tier = (process.argv[2] || "").trim().toUpperCase();
let token = "";
try {
  token = readFileSync(`/var/run/secrets/agentgateway/KEY_${tier}`, "utf8").trim();
} catch {}
process.stdout.write(JSON.stringify(token ? { "x-api-key": token } : {}));
