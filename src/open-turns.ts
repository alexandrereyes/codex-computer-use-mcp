import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";

/**
 * Native turns that may still be open in the shared Computer Use service.
 *
 * The service keeps every software cursor on screen while any thread it has seen lacks a
 * `turn-ended` notification, and only a signed app-server can send one. A session that dies
 * before its own notification (killed proxy, lost transport, unsettled request) would keep every
 * cursor visible until the service restarts. Each session records its turn before the first call
 * and removes the record once the service confirms the notification; a later session ends the
 * turns whose owner is gone.
 */

// The thread ID names the record file, so it must be a plain file name.
const threadIdSchema = z.string().regex(/^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$/);

const recordSchema = z.object({
	threadId: threadIdSchema,
	turnId: z.string().min(1).max(128),
	ownerPid: z.number().int().positive(),
	ownerSession: z.string().min(1).max(128),
	createdAt: z.number().int().nonnegative(),
});

export type OpenTurn = z.infer<typeof recordSchema>;

/** Records past this age are dropped without notification; the service has restarted since. */
const MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
/** Bound on stale turns ended by one close, so a backlog cannot stall teardown. */
export const OPEN_TURN_SWEEP_LIMIT = 8;

const liveSessions = new Set<string>();

export function openTurnsDirectory(stateRoot: string): string {
	return path.join(stateRoot, "open-turns");
}

function recordFile(directory: string, threadId: string): string {
	return path.join(directory, `${threadId}.json`);
}

function processAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error: any) {
		return error?.code === "EPERM";
	}
}

export function isRecordableThreadId(threadId: string): boolean {
	return threadIdSchema.safeParse(threadId).success;
}

export async function recordOpenTurn(directory: string, turn: OpenTurn): Promise<void> {
	liveSessions.add(turn.ownerSession);
	await mkdir(directory, { recursive: true, mode: 0o700 });
	await writeFile(recordFile(directory, turn.threadId), JSON.stringify(turn), { mode: 0o600 });
}

export async function forgetOpenTurn(directory: string, threadId: string): Promise<void> {
	await rm(recordFile(directory, threadId), { force: true });
}

export function releaseOpenTurnSession(ownerSession: string): void {
	liveSessions.delete(ownerSession);
}

/** Turns whose owning session can no longer end them, oldest first. Unreadable and expired records are removed. */
export async function staleOpenTurns(
	directory: string,
	options: { now?: number; isAlive?: (pid: number) => boolean; limit?: number } = {},
): Promise<OpenTurn[]> {
	const now = options.now ?? Date.now();
	const isAlive = options.isAlive ?? processAlive;
	let names: string[];
	try { names = await readdir(directory); }
	catch { return []; }
	const stale: OpenTurn[] = [];
	for (const name of names) {
		if (!name.endsWith(".json")) continue;
		const file = path.join(directory, name);
		let turn: OpenTurn;
		try {
			turn = recordSchema.parse(JSON.parse(await readFile(file, "utf8")));
			if (recordFile(directory, turn.threadId) !== file) throw new Error("Record name does not match its thread");
		} catch {
			await rm(file, { force: true }).catch(() => undefined);
			continue;
		}
		if (now - turn.createdAt > MAX_AGE_MS) {
			await rm(file, { force: true }).catch(() => undefined);
			continue;
		}
		const ownerGone = turn.ownerPid === process.pid ? !liveSessions.has(turn.ownerSession) : !isAlive(turn.ownerPid);
		if (ownerGone) stale.push(turn);
	}
	stale.sort((left, right) => left.createdAt - right.createdAt);
	return stale.slice(0, options.limit ?? OPEN_TURN_SWEEP_LIMIT);
}
