import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
	forgetOpenTurn,
	isRecordableThreadId,
	recordOpenTurn,
	releaseOpenTurnSession,
	staleOpenTurns,
	type OpenTurn,
} from "../src/open-turns.ts";

function deadPid(): number {
	const result = spawnSync(process.execPath, ["-e", ""]);
	assert.ok(result.pid);
	return result.pid;
}

function turn(threadId: string, overrides: Partial<OpenTurn> = {}): OpenTurn {
	return { threadId, turnId: `${threadId}-turn`, ownerPid: deadPid(), ownerSession: `${threadId}-session`, createdAt: Date.now(), ...overrides };
}

test("a recorded turn is stale only once its owner is gone", async () => {
	const directory = path.join(await mkdtemp(path.join(os.tmpdir(), "open-turns-test.")), "open-turns");
	try {
		await recordOpenTurn(directory, turn("dead-owner", { createdAt: 2 }));
		await recordOpenTurn(directory, turn("live-other-process", { ownerPid: process.ppid }));
		await recordOpenTurn(directory, turn("live-session", { ownerPid: process.pid }));
		await recordOpenTurn(directory, turn("released-session", { ownerPid: process.pid, createdAt: 1 }));
		releaseOpenTurnSession("released-session-session");

		const stale = await staleOpenTurns(directory, { now: 3 });
		assert.deepEqual(stale.map((item) => item.threadId), ["released-session", "dead-owner"]);
		assert.equal(stale[0].turnId, "released-session-turn");

		await forgetOpenTurn(directory, "dead-owner");
		assert.deepEqual((await staleOpenTurns(directory, { now: 3 })).map((item) => item.threadId), ["released-session"]);
		releaseOpenTurnSession("live-session-session");
	} finally { await rm(path.dirname(directory), { recursive: true, force: true }); }
});

test("unreadable, misnamed and expired records are removed without being ended", async () => {
	const directory = path.join(await mkdtemp(path.join(os.tmpdir(), "open-turns-prune-test.")), "open-turns");
	try {
		await recordOpenTurn(directory, turn("expired", { createdAt: 0 }));
		await recordOpenTurn(directory, turn("recent", { createdAt: 8 * 24 * 60 * 60 * 1000 }));
		await writeFile(path.join(directory, "broken.json"), "{");
		await writeFile(path.join(directory, "misnamed.json"), JSON.stringify(turn("other")));
		await writeFile(path.join(directory, "notes.txt"), "kept");

		const stale = await staleOpenTurns(directory, { now: 8 * 24 * 60 * 60 * 1000 + 1 });
		assert.deepEqual(stale.map((item) => item.threadId), ["recent"]);
		assert.deepEqual((await readdir(directory)).sort(), ["notes.txt", "recent.json"]);
	} finally { await rm(path.dirname(directory), { recursive: true, force: true }); }
});

test("a sweep is bounded and a missing directory has no stale turns", async () => {
	const directory = path.join(await mkdtemp(path.join(os.tmpdir(), "open-turns-limit-test.")), "open-turns");
	try {
		assert.deepEqual(await staleOpenTurns(directory), []);
		for (let index = 0; index < 5; index += 1) await recordOpenTurn(directory, turn(`thread-${index}`, { createdAt: 10 - index }));
		assert.deepEqual((await staleOpenTurns(directory, { now: 20, limit: 2 })).map((item) => item.threadId), ["thread-4", "thread-3"]);
	} finally { await rm(path.dirname(directory), { recursive: true, force: true }); }
});

test("only plain thread IDs name a record", () => {
	assert.equal(isRecordableThreadId("01a1a764-41a6-7e42-a903-9fce88bfcc3e"), true);
	for (const unsafe of ["", "../escape", "a/b", ".hidden", "x".repeat(129)]) assert.equal(isRecordableThreadId(unsafe), false, unsafe);
});
