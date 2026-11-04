# Fork notes

Read this before merging upstream, after the ChatGPT app updates its Codex or Computer Use
components, and before deploying. It lists what this fork adds, what must survive a merge,
and what was learned about the official components. Deployment history and acceptance
evidence stay in `macos/README.md`.

## Remotes and history

- `origin`: `alexandrereyes/codex-computer-use-mcp` (this fork). `upstream`:
  `tmustier/codex-computer-use-mcp`, which tags its releases (`v0.6.3`, `v0.6.4`, …).
- `main` is upstream plus the fork. Fixes live on `fix/<name>` branches merged with
  `--no-ff`. Upstream syncs use `sync/upstream-vX.Y.Z`, merged as
  "Merge upstream vX.Y.Z into the fork, keeping MacLock", with the conflict resolution in
  the merge message (see `8dc9218`).
- Last upstream merged: `v0.6.3` (`03d003d`), on 2026-11-03. Not merged yet: `v0.6.4`
  (`8aa20f3`, recovery hints for Computer Use failures and a 30 s codesign limit).
- The package keeps upstream's version number; the installed directory name and the
  tarball checksum identify a fork build.

## What the fork adds — keep it through merges

1. **MacLock, locked use** (`macos/`, `src/native-lease.ts`, enabled by
   `CODEX_COMPUTER_USE_NATIVE_LOCK=1`). Every call except `list_apps` runs inside a native
   lease. `NATIVE_CALL_TIMEOUT_MS` (115 s) must stay below the native 120 s deadline, which
   otherwise suppresses locked use until a manual unlock. `fail()` and `cancel()` finish the
   lease at once. `package.json` `files` ships the `macos/` sources, and
   `test/package.test.ts` installs them from both registry and git consumers.
2. **Codex broker selection.** `CODEX_COMPUTER_USE_CODEX_PATH` wins over `config.json`, is
   canonical-only and is still signature and Team ID checked.
3. **Cleanup reporting.** `lsof -w`, so warnings about unrelated mounts are not enumeration
   failures. `withCleanupFailure` and `cleanupFailureMessage` report a cleanup failure
   together with the failure it followed.
4. **Open-turn record and shutdown** (2026-11-04, `src/open-turns.ts`). Each session
   records its turn under `<state>/open-turns/` before its first call and forgets it once
   `turn-ended` succeeds. `close()` and `shutdown()` also end up to eight recorded turns whose
   owner is gone. Production callers pass `openTurnsDir` (session executor and one-shot
   service). `mcp-server.ts` calls `DirectSessionExecutor.shutdown()` on stdin end and
   `SIGTERM`/`SIGINT`/`SIGHUP`, bounded to 3.5 s to fit the stdio client's 2 s + 2 s grace.
   `shutdown()` kills the private group with one `SIGKILL` instead of the freeze-and-verify
   teardown, so a late `SIGKILL` cannot leave stopped processes.
5. **Audit.** Retained-session calls record `brokerCleanupVerified=false`; the session close
   is the cleanup boundary.

If upstream adds its own turn tracking or shutdown handling, prefer it only if it still
covers both cases: a killed session's turn is ended later by another session, and stdin end
or `SIGTERM` ends the retained turn within the client's grace. Otherwise keep the fork's.

## Facts about the official components

Observed on 2026-11-04 with codex-cli `0.166.0-alpha.5.1` and Computer Use `1001641`.
Re-verify them after an upgrade of either component.

- `SkyComputerUseService` draws a "Software Cursor" window per target app. It hides the
  cursors only once **every** turn it has seen has received `turn-ended`, so one open turn
  keeps every later cursor on screen.
- `turn-ended` only works when a signed parent sends it, here the app-server's
  `command/exec`. Run from a shell, the client exits 0 and nothing happens. An exit code of 0
  does not prove the cursor went away.
- When a client process dies, its turn does not end. A later session can still end it with
  the recorded thread and turn IDs.
- After `turn-ended`, further calls on that turn fail with "Computer Use is unavailable
  because the current turn ended".
- Lifetime: the service lives as long as the ChatGPT app when the app starts it. When
  launchd starts it on demand, it exits with its last client, and that hides leaks in
  isolated tests. To reproduce a leak, keep another client connected.
- A client started through a non-`exec` wrapper is refused with "Sender process is not
  authenticated".
- The service binary contains its own unlock-guard symbols (`beginUnlockGuard…`,
  `autoUnlockedThreadIDs`). If an upgrade starts unlocking by itself, check how that
  interacts with MacLock.

## Upstream merge checklist

1. `git fetch upstream --tags`, `git switch -c sync/upstream-vX.Y.Z main`,
   `git merge vX.Y.Z`.
2. Resolve conflicts keeping the list above. In `src/direct-broker.ts`, check the native
   lease calls, `NATIVE_CALL_TIMEOUT_MS`, the turn record before the first call,
   `endOwnTurn`, `endStaleTurns`, `shutdown`, and `openTurnsDir` in the callers.
3. Run the verification from `AGENTS.md` and `make -C macos test-native`. Two tests bound
   elapsed time ("failed or stalled cursor cleanup", "drain expiry"). They fail on a heavily
   loaded host, `main` included, because `lsof` alone can take about 1.5 s. Compare against
   `main` before treating them as regressions.
4. Live checks with benign apps (Finder): an unlocked read; the cursor check below; and,
   when native code changed, the supervised locked acceptance in `macos/README.md`.
5. Deploy as below, merge with `--no-ff`, push `origin`, and record the deployment in
   `macos/README.md`. Show the user any upstream PR or issue text before posting it.

## Cursor check

List the cursor windows, which should be zero once no session is open:

```swift
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowName as String] as? String) == "Software Cursor" {
  print(w[kCGWindowOwnerPID as String] ?? "", w[kCGWindowNumber as String] ?? "", w[kCGWindowBounds as String] ?? "")
}
```

Run it with `swift cursors.swift`. To test: run `get_app_state` and `click` in Finder, then
close the session through stdin end, `SIGTERM` or the 120 s idle close. Expect no cursor
windows and an empty `open-turns/`. To test the record path, `SIGKILL` a session after its
click while another client keeps the service alive. Its cursor and record must remain, and
the next session's close must remove both.

To clear stuck cursors right away, terminate `SkyComputerUseService`. launchd relaunches it
on the next call. This interrupts any Computer Use the ChatGPT app is running.

## Deployment

1. `npm pack --pack-destination macos/build/<name>/`, with a new versioned name such as
   `locked-use-v0.6.3-open-turns-a3768d8-20261104`.
2. `npm install --omit=dev --prefix ~/.local/share/mac-lock/proxy/<name> <tarball>`. Never
   install over an existing directory.
3. Back up the current `codex-computer-use` entry, mode `0600`, under
   `~/.local/share/mac-lock/backups/`.
4. In `~/.config/opencode/opencode.json`, change only `command[1]` to the new
   `dist/mcp-server.js`. Keep `CODEX_COMPUTER_USE_NATIVE_LOCK=1`. OpenCode reloads the
   servers by itself.
5. Write `deployment.json` in the installed directory with the commit, checksum, backup and
   acceptance results.
6. To roll back, restore `command[1]` from the backup.

Native changes also need the administrative reinstall described in `macos/README.md`.

## Diagnostics

- Calls: `~/.direct-computer-use/audit/direct-computer-use.jsonl`, one record per call with
  method, outcome and duration; app names are hashed. OpenCode's own log does not record
  MCP tool calls.
- Open turns: `~/.direct-computer-use/open-turns/`. A record that persists while no session
  is open means its turn could not be ended yet.
- MacLock: `/Library/Application Support/MacLock/run/native.log`, which has no timestamps,
  and `run/suppressed`, which blocks locked use until a manual unlock.
