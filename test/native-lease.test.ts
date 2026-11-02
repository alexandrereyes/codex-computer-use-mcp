import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { acquireNativeLease } from "../src/native-lease.ts";

const helper = `
const fs = require('node:fs');
const [mode, result] = process.argv.slice(1);
process.stdin.resume();
if (mode === 'busy') process.stdout.write('FAILED BUSY_OR_SUPPRESSED\\n', () => process.exit(4));
if (mode === 'abort-stuck') { console.log('ABORT guardian:FAILED space-attach'); setInterval(() => {}, 1000); }
process.stdin.on('end', () => { fs.writeFileSync(result, 'EOF'); if (mode !== 'abort-stuck') process.exit(mode === 'abort' || mode === 'crash' ? 1 : 0); });
process.stdin.on('data', data => {
 for (const byte of data.toString()) {
  fs.appendFileSync(result + '.commands', byte);
  if (byte === 'B' && mode === 'idle-boundary') { console.log('IDLE_CLOSED'); process.exit(0); }
  console.log(byte === 'B' ? 'ACTIVE' : 'IDLE');
  if (byte === 'I' && mode === 'idle') setTimeout(() => { console.log('IDLE_CLOSED'); process.exit(0); }, 20);
 }
});
if (mode !== 'pending' && mode !== 'busy' && mode !== 'abort-stuck') console.log(mode === 'legacy' ? 'READY' : 'READY_SEQUENCE');
if (mode === 'abort') setTimeout(() => console.log('ABORT input'), 10);
if (mode === 'crash') setTimeout(() => process.kill(process.pid, 'SIGKILL'), 10);
`;
test("optional native integration is disabled by default", async () => {
	const previous = process.env.CODEX_COMPUTER_USE_NATIVE_LOCK;
	delete process.env.CODEX_COMPUTER_USE_NATIVE_LOCK;
	try { assert.equal(await acquireNativeLease(() => assert.fail("unexpected abort")), undefined); }
	finally {
		if (previous === undefined) delete process.env.CODEX_COMPUTER_USE_NATIVE_LOCK;
		else process.env.CODEX_COMPUTER_USE_NATIVE_LOCK = previous;
	}
});
test("the old per-call helper cannot acknowledge the continuous contract", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-legacy."));
	try {
		await assert.rejects(acquireNativeLease(() => assert.fail("not ready"), undefined,
			{ command: process.execPath, args: ["-e", helper, "legacy", path.join(root, "result")] }), /revoked/);
		assert.equal(await readFile(path.join(root, "result"), "utf8"), "EOF");
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("five calls share one native lease; old call cancellation is detached after idle", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-sequence."));
	try {
		const result = path.join(root, "result");
		const controller = new AbortController();
		const lease = await acquireNativeLease(() => assert.fail("unexpected abort"), controller.signal,
			{ command: process.execPath, args: ["-e", helper, "ok", result] });
		for (let call = 0; call < 5; call++) { assert.equal(await lease!.begin(), true); await lease!.idle(); controller.abort(); }
		assert.equal(await readFile(result + ".commands", "utf8"), "BIBIBIBIBI");
		await lease!.finish();
		assert.equal(await readFile(result, "utf8"), "EOF");
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("native idle expiry and begin at the cleanup boundary do not poison the broker", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-idle."));
	try {
		for (const mode of ["idle", "idle-boundary"]) {
			const lease = await acquireNativeLease(() => assert.fail("normal idle is not abort"), undefined,
				{ command: process.execPath, args: ["-e", helper, mode, path.join(root, mode)] });
			if (mode === "idle") {
				assert.equal(await lease!.begin(), true); await lease!.idle();
				await new Promise(resolve => setTimeout(resolve, 100));
			}
			assert.equal(await lease!.begin(), false);
			await lease!.finish();
		}
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("native lease waits for EOF cleanup confirmation and finish is idempotent", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-lease."));
	try {
		const result = path.join(root, "result");
		const lease = await acquireNativeLease(() => assert.fail("unexpected abort"), undefined, { command: process.execPath, args: ["-e", helper, "ok", result] });
		await lease!.finish(); await lease!.finish();
		assert.equal(await readFile(result, "utf8"), "EOF");
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("native guard revocation reaches caller and cannot be reported as successful cleanup", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-abort."));
	try {
		let notify!: () => void;
		const aborted = new Promise<void>((resolve) => { notify = resolve; });
		const lease = await acquireNativeLease(() => notify(), undefined, { command: process.execPath, args: ["-e", helper, "abort", path.join(root, "result")] });
		await aborted;
		await assert.rejects(lease!.finish(), /revoked/);
		assert.equal(await readFile(path.join(root, "result"), "utf8"), "EOF");
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("cancellation closes the native channel; already-cancelled requests do not start a helper", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-cancel."));
	try {
		const controller = new AbortController();
		const command = { command: process.execPath, args: ["-e", helper, "ok", path.join(root, "result")] };
		const lease = await acquireNativeLease(() => {}, controller.signal, command);
		controller.abort();
		await assert.rejects(lease!.finish(), /cancelled/);
		assert.equal(await readFile(path.join(root, "result"), "utf8"), "EOF");
		await assert.rejects(acquireNativeLease(() => {}, controller.signal, command), /cancelled/);
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("cancellation before native readiness closes startup instead of leaving it armed", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-startup-cancel."));
	try {
		const controller = new AbortController();
		const started = acquireNativeLease(() => {}, controller.signal, { command: process.execPath, args: ["-e", helper, "pending", path.join(root, "result")] });
		controller.abort();
		await assert.rejects(started, /cancelled/);
		assert.equal(await readFile(path.join(root, "result"), "utf8"), "EOF");
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("a busy or suppressed refusal explains itself", async () => {
	await assert.rejects(acquireNativeLease(() => assert.fail("never ready"), undefined,
		{ command: process.execPath, args: ["-e", helper, "busy", "unused"] }),
	/FAILED BUSY_OR_SUPPRESSED \(another call is using the Mac, or an earlier failure suspended locked use until someone unlocks the Mac by hand\)/);
});
test("a readiness failure without confirmed relock keeps the guard's reason in the message", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "native-stuck."));
	try {
		await assert.rejects(acquireNativeLease(() => assert.fail("never ready"), undefined,
			{ command: process.execPath, args: ["-e", helper, "abort-stuck", path.join(root, "result")] }),
		(error: Error) => {
			assert.ok(error instanceof AggregateError);
			assert.match(error.message, /^Native Computer Use readiness failed and relock was not confirmed: .*ABORT guardian:FAILED space-attach; cleanup: .*relock was not confirmed$/);
			return true;
		});
	} finally { await rm(root, { recursive: true, force: true }); }
});
test("native helper crash aborts the call and does not confirm relock", async () => {
	let notify!: () => void;
	const aborted = new Promise<void>((resolve) => { notify = resolve; });
	const lease = await acquireNativeLease(() => notify(), undefined, { command: process.execPath, args: ["-e", helper, "crash", "unused"] });
	await aborted;
	await assert.rejects(lease!.finish(), /without confirmed cleanup/);
});
