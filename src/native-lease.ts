import { spawn, spawnSync } from "node:child_process";
import { existsSync, realpathSync, statSync } from "node:fs";
import { createInterface } from "node:readline";

const HELPER = "/Library/Application Support/MacLock/MacLock.app/Contents/MacOS/mac-lock";
export interface NativeLease {
	/** False means the native idle timeout already completed cleanup; acquire a new lease. */
	begin(): Promise<boolean>;
	idle(): Promise<void>;
	finish(): Promise<void>;
}

/** Lifecycle transport only: the native service owns local authorization and desktop protection. */
export async function acquireNativeLease(
	onAbort: (error: Error) => void,
	signal?: AbortSignal,
	/** Test-only helper override. Production uses the root-installed, signed component. */
	testCommand?: { command: string; args: string[] },
): Promise<NativeLease | undefined> {
	if (!testCommand) {
		if (process.env.CODEX_COMPUTER_USE_NATIVE_LOCK !== "1") return undefined;
		if (!existsSync(HELPER)) throw new Error("Native Computer Use explicitly enabled but helper is not installed");
		const info = statSync(HELPER);
		if (realpathSync(HELPER) !== HELPER || info.uid !== 0 || (info.mode & 0o022) !== 0 ||
			spawnSync("/usr/bin/codesign", ["--verify", "--strict", HELPER], { timeout: 5_000 }).status !== 0) {
			throw new Error("Native Computer Use helper verification failed");
		}
	}
	if (signal?.aborted) throw new Error("Native Computer Use lease cancelled");
	const child = spawn(testCommand?.command ?? HELPER, testCommand?.args ?? ["lease-auto"], { stdio: ["pipe", "pipe", "pipe"] });
	child.stderr.resume();
	let ready = false;
	let finishing = false;
	let idle = true;
	let idleClosed = false;
	let released = false;
	let waiting: { expected: string; resolve(value: boolean): void; reject(error: Error): void } | undefined;
	let failure: Error | undefined;
	let finishPromise: Promise<void> | undefined;
	let resolveReady!: () => void;
	let rejectReady!: (error: Error) => void;
	const started = new Promise<void>((resolve, reject) => { resolveReady = resolve; rejectReady = reject; });
	const fail = (message: string): void => {
		if (failure) return;
		failure = new Error(message);
		rejectReady(failure);
		waiting?.reject(failure);
		if (ready) onAbort(failure);
		child.stdin.end();
	};
	const lines = createInterface({ input: child.stdout });
	lines.on("line", (line) => {
		if (line === "READY_SEQUENCE" && !ready && !finishing && !failure) { ready = true; resolveReady(); }
		else if (ready && line === waiting?.expected && !failure) {
			idle = line === "IDLE";
			waiting.resolve(true);
		}
		else if (ready && idle && line === "IDLE_CLOSED" && !failure) idleClosed = true;
		else fail(`Native Computer Use guard revoked the operation: ${line.slice(0, 160)}`);
	});
	child.stdin.on("error", () => {
		// A begin can race normal idle cleanup. Exit + IDLE_CLOSED decides whether retry is safe.
		if (!ready || !idle) fail("Native Computer Use lease channel failed");
	});
	child.on("error", () => fail("Native Computer Use helper could not start"));
	const exited = new Promise<void>((resolve) => child.once("close", (code) => {
		if (code !== 0 || (!finishing && !idleClosed)) fail("Native Computer Use helper ended without confirmed cleanup");
		released = true;
		if (!failure) waiting?.resolve(false);
		signal?.removeEventListener("abort", abort);
		lines.close();
		resolve();
	}));
	const abort = (): void => fail("Native Computer Use lease cancelled");
	signal?.addEventListener("abort", abort, { once: true });
	const command = async (byte: string, expected: string): Promise<boolean> => {
		if (failure) throw failure;
		if (released) return false;
		if (finishing || waiting) throw new Error("Native Computer Use transition already pending or closing");
		let timer: NodeJS.Timeout | undefined;
		try {
			return await new Promise<boolean>((resolve, reject) => {
				waiting = { expected, resolve, reject };
				timer = setTimeout(() => fail("Native Computer Use call transition timed out"), 12_000);
				child.stdin.write(byte);
			});
		} finally { clearTimeout(timer); waiting = undefined; }
	};
	const finish = (): Promise<void> => {
		finishPromise ??= (async () => {
			finishing = true;
			child.stdin.end(); // Native EOF revokes the operation independently of this process.
			let timer: NodeJS.Timeout | undefined;
			try {
				await Promise.race([exited, new Promise<never>((_, reject) => {
					timer = setTimeout(() => {
						child.kill("SIGKILL");
						reject(new Error("Native Computer Use relock was not confirmed"));
					}, 12_000);
				})]);
				if (failure) throw failure;
			} finally { clearTimeout(timer); signal?.removeEventListener("abort", abort); lines.close(); }
		})();
		return finishPromise;
	};
	// Includes coordinator startup (3 s), display wake (3 s), and existing guard/unlock (8 s).
	const timer = setTimeout(() => fail("Native Computer Use guard readiness timed out"), 15_000);
	try {
		await started;
		return {
			begin: () => command("B", "ACTIVE"),
			idle: async () => {
				if (!await command("I", "IDLE")) throw new Error("Native Computer Use closed before call completion");
				signal?.removeEventListener("abort", abort); // Later calls own their cancellation, not this completed call.
			},
			finish,
		};
	}
	catch (error) {
		try { await finish(); }
		catch (cleanupError) {
			if (cleanupError !== error) throw new AggregateError([error, cleanupError], "Native Computer Use readiness failed and relock was not confirmed");
		}
		throw error;
	}
	finally { clearTimeout(timer); }
}
