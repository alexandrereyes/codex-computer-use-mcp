// Supervised only: same official session, Help menu by retained index, declared Cancel.
import { spawnSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createOfficialDirectToolSession } from "../../dist/direct-broker.js";
import { finderHelpMenu } from "./finder-menu.mjs";

if (process.env.CODEX_COMPUTER_USE_NATIVE_LOCK !== "1") throw new Error("Native opt-in is required");
const inspect = () => {
    const r = spawnSync(fileURLToPath(new URL("../build/lock-state-contract", import.meta.url)), ["--inspect"], { encoding: "utf8", timeout: 5000 });
    return { status: r.status, output: r.stdout ?? "", locked: r.status === 0 && /\blockState=1\b/.test(r.stdout ?? ""),
        unlocked: r.status === 0 && /\blockState=0\b/.test(r.stdout ?? "") };
};
const nativeLog = () => readFile("/Library/Application Support/MacLock/run/native.log", "utf8")
    .catch(error => { if (error.code === "ENOENT") return ""; throw error; });
const beforeLog = await nativeLog();
const report = { started: new Date().toISOString(), before: inspect(), steps: [] };
if (!report.before.locked) throw new Error("Start with the Mac locked and Finder without modal dialogs; an open Help menu is handled explicitly");
const menuState = result => finderHelpMenu(result.content.filter(c => c.type === "text").map(c => c.text).join("\n"));
let session;
try {
    session = await createOfficialDirectToolSession();
    const call = async (purpose, method, args) => {
        const result = await session.call(method, { app: "com.apple.finder", ...args }, { timeoutMs: 30_000 });
        const after = inspect();
        report.steps.push({ purpose, method, args, result, after });
        if (result.isError || result.modelTurnsStarted !== 0 || !after.unlocked || result.brokerCleanupVerified)
            throw new Error(`Failed step or unexpected per-call relock: ${method}`);
        return result;
    };
    let menu = menuState(await call("inspect-initial-state", "get_app_state", { disableDiff: true }));
    report.route = menu.state === "open" ? "prepare-open-help" : "closed-help";
    report.expectedSteps = menu.state === "open" ? 7 : 5;
    if (menu.state === "open") {
        report.preparationCancelIndex = menu.index;
        await call("prepare-close-existing-help", "perform_secondary_action", { element_index: menu.index, action: menu.action });
        menu = menuState(await call("verify-preparation", "get_app_state", { disableDiff: true }));
        if (menu.state !== "closed") throw new Error("Help Cancel did not produce a closed menu-bar state; preparation failed, no click or retry attempted");
        report.preparationVerified = true;
    }
    report.helpMenuIndex = menu.index;
    await call("open-help-by-observed-index", "click", { element_index: menu.index }); // No intervening refresh/retry.
    menu = menuState(await call("verify-help-open", "get_app_state", { disableDiff: true }));
    if (menu.state !== "open") throw new Error("Help click did not expose a menu declaring Cancel; stopping without guessed actions");
    report.finalCancelIndex = menu.index;
    await call("close-help-by-declared-action", "perform_secondary_action", { element_index: menu.index, action: menu.action });
    menu = menuState(await call("verify-help-closed", "get_app_state", { disableDiff: true }));
    if (menu.state !== "closed") throw new Error("Final Help Cancel did not produce a closed menu-bar state");
    report.acceptanceVerified = true;
} catch (error) {
    report.error = { name: error.name, message: error.message };
} finally {
    try { if (session) { await session.close(); report.brokerCleanupVerified = true; } }
    catch (error) { report.cleanupError = error.message; }
}
report.after = inspect(); report.finished = new Date().toISOString();
const afterLog = await nativeLog();
const trace = afterLog.startsWith(beforeLog) ? afterLog.slice(beforeLog.length) : "";
report.nativeCycles = { attached: (trace.match(/^SPACE_ATTACH /gm) ?? []).length,
    cleaned: (trace.match(/^SPACE_CLEANUP /gm) ?? []).length,
    closedLocked: (trace.match(/^MacLock lease finished guarded=1 result=CLOSED lockState=1$/gm) ?? []).length };
const path = new URL(`../build/e2e-finder-continuous-${report.started.replace(/[:.]/g, "-")}.json`, import.meta.url);
await writeFile(path, JSON.stringify(report, null, 2) + "\n", { flag: "wx" });
console.log(JSON.stringify({ report: fileURLToPath(path), completedSteps: report.steps.length,
    route: report.route, expectedSteps: report.expectedSteps, preparationVerified: report.preparationVerified,
    acceptanceVerified: report.acceptanceVerified,
    helpMenuIndex: report.helpMenuIndex, error: report.error, cleanupError: report.cleanupError,
    brokerCleanupVerified: report.brokerCleanupVerified, lockedAfter: report.after.locked, nativeCycles: report.nativeCycles }, null, 2));
if (report.error || report.cleanupError || !report.acceptanceVerified || report.steps.length !== report.expectedSteps || !report.brokerCleanupVerified || !report.after.locked ||
    Object.values(report.nativeCycles).some(count => count !== 1)) process.exitCode = 1;
