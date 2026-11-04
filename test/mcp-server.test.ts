import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { z } from "zod";
import { COMPUTER_USE_METHODS, TOOL_INPUT_SCHEMAS, TOOL_METADATA } from "../src/tools.ts";
import packageMetadata from "../package.json" with { type: "json" };

const packageVersion = packageMetadata.version;

function stringEnvironment(): Record<string, string> {
	return Object.fromEntries(
		Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined),
	);
}

test("stdio MCP exposes the Computer Use tools and status", async () => {
	const stateRoot = await mkdtemp(path.join(os.tmpdir(), "direct-computer-use-mcp-test."));
	const client = new Client({ name: "test-client", version: "1.0.0" }, { capabilities: {} });
	const transport = new StdioClientTransport({
		command: process.execPath,
		args: [path.resolve("src/mcp-server.ts")],
		cwd: process.cwd(),
		env: { ...stringEnvironment(), CODEX_COMPUTER_USE_HOME: stateRoot },
		stderr: "pipe",
	});
	try {
		await client.connect(transport);
		assert.deepEqual(client.getServerVersion(), { name: "codex-computer-use-mcp", version: packageVersion });
		const listed = await client.listTools();
		assert.deepEqual(listed.tools.map((tool) => tool.name).sort(), [...COMPUTER_USE_METHODS, "computer_use_status"].sort());
		for (const method of COMPUTER_USE_METHODS) {
			const tool = listed.tools.find((item) => item.name === method);
			assert.deepEqual(tool, {
				name: method,
				description: TOOL_METADATA[method].description,
				inputSchema: TOOL_INPUT_SCHEMAS[method],
				annotations: TOOL_METADATA[method].annotations,
			});
		}

		const statusResult = await client.callTool({ name: "computer_use_status", arguments: {} });
		assert.equal(statusResult.isError, undefined);
		const status = z.object({
			permissionMode: z.literal("no-permissions"),
			methods: z.array(z.enum(COMPUTER_USE_METHODS)),
			brokerVerified: z.boolean(),
		}).passthrough().parse(statusResult.structuredContent);
		assert.deepEqual(status.methods, COMPUTER_USE_METHODS);
		assert.equal(status.brokerVerified, true);
	} finally {
		await client.close().catch(() => undefined);
		await rm(stateRoot, { recursive: true, force: true });
	}
});

test("stdio MCP closes its session and exits on stdin end or a termination signal", async () => {
	const stateRoot = await mkdtemp(path.join(os.tmpdir(), "direct-computer-use-mcp-exit-test."));
	try {
		for (const stop of ["stdin", "SIGTERM", "SIGHUP"] as const) {
			const child = spawn(process.execPath, [path.resolve("src/mcp-server.ts")], {
				cwd: process.cwd(),
				env: { ...stringEnvironment(), CODEX_COMPUTER_USE_HOME: stateRoot },
				stdio: ["pipe", "pipe", "pipe"],
			});
			const exited = new Promise<number | null>((resolve) => child.once("exit", (code) => resolve(code)));
			const ready = new Promise<void>((resolve) => child.stdout.once("data", () => resolve()));
			child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } } })}\n`);
			await ready;
			const started = Date.now();
			if (stop === "stdin") child.stdin.end();
			else child.kill(stop);
			assert.equal(await exited, 0, stop);
			assert.ok(Date.now() - started < 5_000, stop);
		}
	} finally {
		await rm(stateRoot, { recursive: true, force: true });
	}
});
