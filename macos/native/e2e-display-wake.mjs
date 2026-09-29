// Supervisor only. Start locked with displays asleep; one official read-only state call.
import { spawnSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createOfficialDirectToolSession } from "../../dist/direct-broker.js";

if (process.env.CODEX_COMPUTER_USE_NATIVE_LOCK !== "1") throw new Error("Native opt-in required");
const inspect = () => {
    const r = spawnSync(fileURLToPath(new URL("../build/lock-state-contract", import.meta.url)), ["--inspect"], { encoding: "utf8", timeout: 5000 });
    const output = r.stdout ?? "";
    const flag = name => r.status === 0 && new RegExp(`\\b${name}=1\\b`).test(output);
    return { status: r.status, output, locked: flag("lockState"), unlocked: r.status === 0 && /\blockState=0\b/.test(output),
        loginUIQueryOK: flag("loginUIQueryOK"), loginUIShown: flag("loginUI"), graphicalSession: flag("graphicalSession"),
        displaysAsleep: flag("allDisplaysAsleep"), displaysAwake: flag("allDisplaysAwake") };
};
const nativeLog = () => readFile("/Library/Application Support/MacLock/run/native.log", "utf8")
    .catch(error => { if (error.code === "ENOENT") return ""; throw error; });
const beforeLog = await nativeLog();
const report = { started: new Date().toISOString(), app: process.argv[2] ?? "com.apple.finder", before: inspect() };
if (!report.before.locked || !report.before.loginUIQueryOK || report.before.loginUIShown ||
    !report.before.graphicalSession || !report.before.displaysAsleep)
    throw new Error("Precondition not met: require locked=1, login UI query OK/state=0, active graphical session and all displays asleep. No tool called.");
let session;
try {
    session = await createOfficialDirectToolSession();
    report.result = await session.call("get_app_state", { app: report.app, disableDiff: true }, { timeoutMs: 30_000 });
    report.during = inspect();
    if (report.result.isError || report.result.modelTurnsStarted !== 0 || !report.during.unlocked || !report.during.displaysAwake)
        throw new Error("Official state/awake protected session not confirmed");
} catch (error) { report.error = error.message; }
finally {
    try { if (session) { await session.close(); report.brokerCleanupVerified = true; } }
    catch (error) { report.cleanupError = error.message; }
}
report.after = inspect(); report.finished = new Date().toISOString();
const afterLog = await nativeLog();
const trace = afterLog.startsWith(beforeLog) ? afterLog.slice(beforeLog.length) : "";
const markers = ["DISPLAY_WAKE_REQUEST ", "DISPLAY_WAKE_READY ", "SPACE_ATTACH ",
    "MacLock guard ready; requesting loginwindow Return", "SPACE_CLEANUP ", "DISPLAY_WAKE_END releaseStatus=0",
    "MacLock lease finished guarded=1 result=CLOSED lockState=1"];
const positions = markers.map(marker => trace.indexOf(marker));
report.lifecycleOrdered = positions.every((position, i) => position >= 0 && (i === 0 || position > positions[i - 1]));
report.nativeCycles = { attached: (trace.match(/^SPACE_ATTACH /gm) ?? []).length,
    cleaned: (trace.match(/^SPACE_CLEANUP /gm) ?? []).length, powerReleased: (trace.match(/^DISPLAY_WAKE_END releaseStatus=0$/gm) ?? []).length };
report.accepted = !report.error && !report.cleanupError && report.brokerCleanupVerified === true && report.after.locked &&
    report.after.loginUIQueryOK && report.after.loginUIShown && report.lifecycleOrdered && Object.values(report.nativeCycles).every(count => count === 1);
const path = new URL(`../build/e2e-display-wake-${report.started.replace(/[:.]/g, "-")}.json`, import.meta.url);
await writeFile(path, JSON.stringify(report, null, 2) + "\n", { flag: "wx" });
console.log(JSON.stringify({ report: fileURLToPath(path), accepted: report.accepted, app: report.app,
    error: report.error, cleanupError: report.cleanupError, lifecycleOrdered: report.lifecycleOrdered, nativeCycles: report.nativeCycles,
    lockedAfter: report.after.locked, brokerCleanupVerified: report.brokerCleanupVerified }, null, 2));
if (!report.accepted) process.exitCode = 1;
