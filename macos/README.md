# Optional macOS locked-use complement

This directory is the canonical source for MacLock: native protection, authorization
plugin, reversible installer and isolated contracts, versioned with the proxy.
It wraps the **installed, signed OpenAI Computer Use tools**; no proprietary OpenAI
binary is redistributed. Without `CODEX_COMPUTER_USE_NATIVE_LOCK=1`, the proxy's
normal behavior is unchanged. There is no root/postinstall hook.

## Continuous protection — active local deployment

The proxy now retains one native lease across nearby calls in the same official
session. Supervised acceptance on 2026-09-28 completed **seven Finder calls in
8.647 seconds with one native protection cycle**, verified menu actions and final
relock. Persistent native installation and the versioned proxy are now active.
The user's visual impression of the transitions has not yet been confirmed; the
result below records tool, state and native lifecycle evidence.

The complement is maintained in this fork on branch `main`. Git publication
and deployment of an installed runtime tarball are separate operations.

- The native coordinator acknowledges `B` at each real call start: **120 seconds
  maximum for that call**. The deadline is not an absolute two-minute session cap.
- A successful call sends `I`, acknowledged before returning: **30 seconds idle**.
  The curtain remains black between calls. Thirty seconds accommodates the next
  agent/tool round trip without leaving protection held for the lifetime of an MCP.
- No periodic heartbeat. Repeated `B` during a call or repeated `I` while idle is
  rejected; only actual call transitions renew the deadline. Native timers enforce
  both limits independently if the proxy freezes. EOF, cancellation, errors or local
  input revoke the operation. Local input still triggers relock and suppression
  until manual unlock. The Space, input guard and authorization ACK are unchanged.
- At normal idle expiry, native cleanup/relock completes and reports `IDLE_CLOSED`.
  The next call acquires a new lease, preserving the official session and its indices.
  A pause longer than 30 seconds therefore causes a new curtain cycle.
- `session.close()` and one-shot calls wait for native cleanup. A retained call's
  success **does not mean the Mac has relocked**: audit `outcome=ok` is the tool
  result; `brokerCleanupVerified=false` remains correct until session cleanup.
- `list_apps` never opens or renews a native lease; status only verifies the broker.
  MCP retained sessions start at `get_app_state`, as before. Idle leases still expire
  even if inventory/status requests continue. Other direct one-shot tools release
  on session close. One global coordinator remains exclusive: another client gets
  BUSY while protection is held; there is no cross-client queue or shared lease.

The new protocol uses `SEQUENCE` / `READY_SEQUENCE`, with acknowledged call boundaries.
Upgrade both native and proxy together; mixed versions fail instead of dispatching
under an unacknowledged protection contract.

## Lock screen with Touch ID — hidden password field (2026-10-31)

With the built-in display active, the macOS 27.2 lock screen offers Touch ID ("Use o Touch ID ou Digite a Senha")
and hides its password field until a key arrives. The arming Return then only revealed the field
(`keyPressed: Password view hidden`); no authorization ran, the attempt expired and the call ended in
`ABORT unlock-or-visible-coverage-timeout` with the Mac still locked. While the attempt is still armed (not consumed
by the plugin), the coordinator now sends one more Return to the same loginwindow at least 0.5 s after the first
(`MLShouldRepeatReturn`, contract in `test-attempt.c`). Like the first, it comes from the coordinator's PID, which the
input guard already exempts. A visible field is submitted by the first Return and consumes the attempt, so no repeat
follows. Requires reinstalling the native complement (`remove` + `install`, below).

Deployed and accepted on 2026-10-31, with the OpenCode server on a Linux machine (OrbStack `dev`) that starts the MCP
through `mac`. Three pieces:

- Proxy package from this fork (lsof `-w` cleanup fix) in the versioned directory
  `~/.local/share/mac-lock/proxy/locked-use-wake-lsof-20261031`; the previous directories stay untouched.
- Native complement rebuilt from this branch in a Mac-disk copy (`~/.local/share/mac-lock/src/…`; flock does not work
  on the OrbStack mount, so `test_install_native` fails there) and reinstalled with `remove` + `install
  --persistent-locked-use --controller-app ~/.local/share/opencode-custom-v2/mac-controller/OpenCode Custom
  Controller.app`. That controller (opencode2 `custom-mac-controller`) carries the same designated requirement as
  the server, so `controllerRequirement` is unchanged; it also disclaims responsibility, so TCC checks of the
  coordinator and Guardian see `local.opencode.custom` instead of OrbStack.
- MCP command: `mac ~/.local/share/opencode-custom-v2/bin/mac-controller node <proxy>/dist/mcp-server.js` with
  `CODEX_COMPUTER_USE_NATIVE_LOCK=1` (passed through `ORBENV`).

Supervised acceptance (locked, Touch ID lock screen, built-in and external displays): one Finder `get_app_state`
returned the accessibility tree and a screenshot in 3.6 s. Native log: `DISPLAY_WAKE_READY` → `SPACE_ATTACH` →
arming Return → `attempt still armed; repeating loginwindow Return` → grant reported with unlock and Guardian
coverage confirmed → `SPACE_CLEANUP` → `DISPLAY_WAKE_END releaseStatus=0` → `result=CLOSED lockState=1`, no
suppression marker left.

## Stale suppression marker (2026-11-02)

Two locked calls failed on 2026-10-31, right after the OpenCode server moved back from Linux to the Mac. The coordinator
still running then had been started through the Linux chain, and both failures left `run/suppressed`. The Mac then
rebooted, and the user logged in, but no coordinator was running to observe that manual unlock, so the marker survived.
Two days later, the first call started a fresh coordinator, whose first lease arrived before the timer's first check
and got `BUSY_OR_SUPPRESSED` even with the Mac unlocked. Had the Mac been locked, as when the user works from the
iPhone, every locked call would have been refused until someone unlocked the Mac by hand.

The marker still means "refuse leases until someone unlocks the Mac by hand", and the coordinator now treats that
unlock as already done (`MLSuppressionSpent`, contract in `test-lock-state.m`) in two cases:

- **Seen unlocked with no lease in progress:** what the timer already checked. The check now also runs when a lease
  arrives, so a fresh coordinator no longer races its first lease.
- **Written before the current boot (`kern.boottime`):** a coordinator only runs inside a logged-in graphical
  session, and that login came after the marker. Normally someone typed the password (with FileVault, at the
  pre-boot screen). A login without the password, such as auto-login, leaves the session unlocked for whoever is at
  the Mac anyway, so the old marker would no longer protect anything.

A marker written during the current boot still refuses leases while the Mac stays locked. The proxy now explains
`FAILED BUSY_OR_SUPPRESSED`, and a readiness failure whose relock is not confirmed keeps the guard's reason in its
message. Before, only `readiness failed and relock was not confirmed` reached the caller.

Back on the Mac, the MCP command is plain `node <proxy>/dist/mcp-server.js` with `CODEX_COMPUTER_USE_NATIVE_LOCK=1`.
The coordinator's privacy checks are attributed to the server (`OpenCode Custom.app`, `local.opencode.custom`).
Supervised acceptance with the previous build on 2026-11-02, Mac locked, Touch ID lock screen, built-in and external
displays: Finder with the display on, the Gmail web app, and Finder with every display asleep (`DISPLAY_WAKE_REQUEST
… loginUI=0`). Each read took 5.3–5.7 s and ended `result=CLOSED lockState=1` with no marker left. One Gmail
`get_app_state` through OpenCode's MCP tools took 3.6 s, and the retained lease then closed idle and relocked.

## Display asleep + locked — accepted and active (2026-09-29)

The regular-use failure `FAILED login-surface-not-observable` occurred before Space
creation: the session was locked and active, but display sleep hid the login UI.
It was not a Safari permission failure. The failure observed on 2026-09-28 at 20:21
was corrected and qualified on this host on 2026-09-29. The fix is now **installed
and active**, on top of continuous baseline `ef965bc29d47a0d879663068d42bab71e7112166`.
The display-wake fix is included alongside continuous protection in this fork's `main`.

### Real Safari acceptance and deployment

Private report: `macos/build/e2e-display-wake-2026-09-29T13-51-08-046Z.json`.
Start **13:51:08.046 UTC**, finish **13:51:14.805 UTC**, duration **6.759 seconds**.

- Before: locked=1, login UI=0, active graphical session=1, all displays asleep=1.
  After the user locked, the supervisor issued `pmset displaysleepnow` once and
  waited for actual off-state confirmation (about 27 seconds after the request).
  No global sleep timer or power preference was changed.
- One official Safari `get_app_state`: `isError=false`, zero model turns. During
  the protected operation, the session was unlocked and all displays were awake.
  The supervisor checked a useful Safari image rather than a curtain capture;
  private content is not reproduced here or committed.
- Final state: locked=1, login UI=1; `accepted=true`, `brokerCleanupVerified=true`,
  `lifecycleOrdered=true`; exactly one attach, cleanup and power-hold release.
- Native log order: DISPLAY_WAKE_REQUEST → READY → Space → Allow → visible →
  Space cleanup → DISPLAY_WAKE_END releaseStatus=0 → CLOSED lockState=1.

The persistent native installation matched the tested build hash. The supervisor
activated `~/.local/share/mac-lock/proxy/locked-use-wake-20260928/node_modules/codex-computer-use-mcp/dist/mcp-server.js`
in the same `codex-computer-use` entry in `~/.config/opencode/opencode.json`, retaining
`CODEX_COMPUTER_USE_NATIVE_LOCK=1`. Previous entry backup:
`~/.local/share/mac-lock/backups/codex-computer-use-before-wake-20260929-105215.json`
(mode `0600`). Actual MCP status confirmed `brokerVerified=true`; the observed
coordinator was PID **99094**, `coordinator-auto`. No backend restart was performed.
The installation/coordinator remain active; the PID is an observation, not authority.

Installed tarball SHA-256:
`106de015c045e1ec038e3c828d7fd36a253edef2f28e4134e1e15128d7c08248`.
Only documentation was updated after this acceptance; no source, tests, build,
package or production configuration changed in this finalization.

After an authenticated lease and signed parent verification, the Guardian:

1. Acquires `PreventUserIdleDisplaySleep` for its protection lifetime. This prevents
   idle dimming but cannot wake an already-off display by itself.
2. If the login UI is hidden, calls public `IOPMAssertionDeclareUserActivity` once,
   with `kIOPMUserActiveLocal` for visible display activity. No HID/password/click
   or early authentication event is posted.
3. Waits up to **3 seconds**, checking cancellation/EOF, active graphical session,
   known locked state, live Apple-signed loginwindow and observable login UI.
   API success alone is insufficient. Only then does the unchanged Shield start;
   Return/Allow still follow confirmed protection.
4. Releases the activity assertion after preparation. The display hold remains in
   the single Guardian through calls, retained idle and confirmed relock, then is
   released after curtain teardown. Preparation/start failures release assertions.

The parent preparation budget is 6 seconds (3 wake + 3 guard), overall unlock/
coverage 11 seconds (previous 8 + wake), and proxy readiness 15 seconds (including
coordinator startup). Call 120-second and idle 30-second limits are unchanged.
No power preference, TCC or lock policy is changed. This covers display sleep in a
running graphical session, not system sleep, shutdown, headless use or a closed lid.
The prior uncertain-Allow behavior still retains the Guardian; its display hold
follows that protective lifetime, without a new watchdog or periodic wake request.

Source: Apple's [IOPMLib.h](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h),
also checked in the installed Xcode SDK. It documents display power-on without
special privileges, idle prevention's no-wake/lid/system-sleep limitations, and
`IOPMAssertionRelease` for teardown. `Local` selects the visible display required
by the secure login UI, not remote GPU-only activity.

### Suppression and installation/test reference

Suppression is unchanged: existing `run/suppressed` denies the lease before wake.
The old marker cannot distinguish display startup failure from physical input;
never delete it to force an automatic retry. Clear it through the existing manual
unlock observation or the explicit remove/install upgrade below. Startup failures
retain the existing suppression policy. Since 2026-11-02 a marker older than the
current boot also counts as cleared (see "Stale suppression marker" above).

The wake upgrade is complete. For a future reinstall, after IDLE, retain the previous
tarballs, installed proxies and entry backups. Reference commands from the checkout root:

```sh
make -C macos native
sudo python3 macos/native/install-native.py remove
sudo python3 macos/native/install-native.py install --persistent-locked-use --controller-app "$CONTROLLER_APP"
npm install --omit=dev --prefix "$HOME/.local/share/mac-lock/proxy/locked-use-wake-20260928" "$PWD/macos/build/locked-use-wake-20260928/codex-computer-use-mcp-0.5.0.tgz"
```

The supervisor completed activation by switching only the existing MCP script path
to the wake version, retaining the opt-in. No reinstall or additional test is pending.

The user locks and lets displays **actually turn off**, rather than waiting a fixed
seven seconds. The read-only preflight must show lock 1, login UI query OK/state 0,
active graphical session and all displays asleep:

```sh
./macos/build/lock-state-contract --inspect
CODEX_COMPUTER_USE_NATIVE_LOCK=1 node macos/native/e2e-display-wake.mjs
```

Only the supervisor executes this GUI acceptance, from the authorized backend chain.
It makes one official Finder `get_app_state`, checks protected unlocked/awake state,
closes the lease and requires final lock/login UI. Native logs must order wake request
→ locked UI ready → Space → existing Return trigger → Space cleanup → successful
power-hold release → CLOSED/locked. Private results stay in `macos/build/`. To use
the original target instead, pass `com.apple.Safari` as the sole argument; it still
uses Computer Use, not Safari DevTools or another conversation's content.

`test-display-wake.m` mocks all power calls and the clock: readiness, already-visible
UI, timeout, session/unknown/signature/API failures and channel cancel/EOF with release.
These tests do not wake a display or authorize anything. The subsequent real
powerd/Safari acceptance is recorded above and was executed by the supervisor.
Candidate checks passed: **9 native contract executables, 11 Python tests, 68 proxy
tests**, package-consumer native build/contracts, check/check:pi/build, three menu
parser contracts, driver syntax and diff whitespace. These are not a real wake test.

## Build and isolated verification

Requires macOS, Xcode Command Line Tools, Python 3 and Node 22+. From the package root:

```sh
npm run build
make -C macos native
make -C macos test-native
```

The native build is signed ad hoc by default. `SIGN_IDENTITY` can select an existing
signing identity. Installed files are root-owned; controller authority is a persistent
UID plus signing requirement, not a process ID. The installer requires the existing
`local.opencode.custom` controller bundle and its persistent certificate.

Contracts use fixtures, local sockets and mock authorization callbacks; they do not
install, request real authentication, draw a curtain or change TCC. `make -C macos
trials` builds a separate diagnostic executable; trials are never in the installed
app. Native build output, screenshots, logs and E2E reports are excluded from Git/npm.

Pre-deployment checks (2026-09-28): `npm run check`, `npm run check:pi`, build and all
**68 proxy tests passed**, including actual signed read-only `list_apps`. Native:
**8 contract executables and 11 Python tests passed**. The package smoke test also
installs the tarball in an isolated consumer and builds/runs those native contracts
there, proving relocation without the old checkout. Driver syntax and whitespace
checks passed. Continuous lifecycle coverage includes reuse, idle/reacquisition,
begin during idle cleanup, per-call deadlines, active/idle input revocation, errors,
cancellation, final cleanup failure and refusal of the old protocol. None of these
checks substitutes for real execution; the subsequent supervised result is below.

## Administrative installation / upgrade

Native installation is manual opt-in, in `/Library/Application Support/MacLock`
and `/Library/Security/SecurityAgentPlugins/MacLockAuthorization.bundle`.
No LaunchAgent: the authorized backend's descendant starts/reuses the coordinator,
transferring the same singleton flock through the existing child stdin descriptor.
The wake-enabled continuous version is installed and remains active. Commands in this
section are references for a future installation/upgrade, not pending activation steps.

For an upgrade, stop issuing Computer Use calls and allow the current operation to
finish. The old per-call version is IDLE between calls; the continuous version becomes IDLE
after session close or the 30-second idle cleanup. Remove refuses ACTIVE rather than
killing a Guardian. From this package root, with the actual controller bundle path:

```sh
# Existing installation only: disable, confirm IDLE/no Guardian, shutdown, remove.
sudo python3 macos/native/install-native.py remove
make -C macos native
sudo python3 macos/native/install-native.py install --persistent-locked-use --controller-app "$CONTROLLER_APP"
```

For a fresh installation, omit `remove`. The old checkout's remove entrypoint remains
valid for the prior installation. Policy removal edits only MacLock's own reference
and rule, preserving Apple/OpenAI alternatives and later unrelated changes.
The optional `--experimental-locked-use` instead selects a ten-minute global window.

Install this fork's tarball in a **new versioned directory**, never over the working
`locked-use-20260928` installation. The earlier continuous-only installation used,
from the checkout root (the current wake package is recorded above):

```sh
npm install --omit=dev --prefix "$HOME/.local/share/mac-lock/proxy/locked-use-continuous-20260928" "$PWD/macos/build/locked-use-continuous-20260928/codex-computer-use-mcp-0.5.0.tgz"
```

The npm package contains native **source**, not prebuilt binaries. Alternatively,
build/install from its installed `node_modules/codex-computer-use-mcp/macos` directory;
the complement is self-contained and does not depend on the historical checkout.
It keeps upstream version `0.5.0`; use the versioned directory and tarball checksum
to distinguish this fork. Registry/global `npx` commands may run a different package.

Historical continuous-only activation on 2026-09-28: the supervisor updated the existing `codex-computer-use` entry in
`~/.config/opencode/opencode.json`, changing only `command[1]` to
`~/.local/share/mac-lock/proxy/locked-use-continuous-20260928/node_modules/codex-computer-use-mcp/dist/mcp-server.js`
(an absolute path in the actual JSON). `CODEX_COMPUTER_USE_NATIVE_LOCK=1` was retained.
The previous entry was backed up to
`~/.local/share/mac-lock/backups/codex-computer-use-before-continuous-20260928-181213.json`
with mode `0600`. The example config remains disabled and was not loaded directly.

Actual `computer_use_status` confirmed `brokerVerified=true` and the updated paths;
the supervisor observed 30 Location MCP processes using the new package. The native
coordinator was PID 93888 (`coordinator-auto`), with no Guardian remaining after the
test. These are deployment observations, not persistent process identities. The
backend was not restarted. This deployment was subsequently superseded by the
wake-enabled installation and coordinator recorded above.

## Supervised Finder acceptance — passed for continuous protection

Local private report:
`macos/build/e2e-finder-continuous-2026-09-28T21-11-45-192Z.json`.
Started **21:11:45.192 UTC**, finished **21:11:53.839 UTC** on 2026-09-28
(**8.647 seconds**).

- Seven calls in the same official session, route `prepare-open-help`, expected 7.
- `preparationVerified=true`, `acceptanceVerified=true`, Help index **423**:
  the already-open Help menu was cancelled, a fresh closed menu-bar state was
  verified, Help was opened by the observed index and cancelled again with the
  final closed state verified.
- One `SPACE_ATTACH`, one `SPACE_CLEANUP`, one `CLOSED lockState=1`.
- Broker cleanup confirmed and the Mac locked afterward; the driver also required
  zero model turns and unlocked state during each protected call.
- The installed runtime matched checkout hashes before execution. This validates
  the continuous lifecycle and menu sequence on this host. No additional claim
  about the user's visual perception or frame-by-frame coverage is made.

The prior persistent, per-call version passed a real five-call Finder sequence on
2026-09-28: 18.766 seconds, retained Help index, zero model turns, relock after every
call and verified cleanup. This establishes the baseline, **not acceptance of the
new continuous lifecycle**. Private reports remain in the historical local checkout,
outside this repository/package.

The procedure used was: prepare Finder without a modal dialog, lock manually, then
run from the authorized backend's chain, without manually starting a coordinator:

```sh
CODEX_COMPUTER_USE_NATIVE_LOCK=1 node macos/native/e2e-finder-sequence.mjs
```

The driver keeps one official session: full state → Help by fresh index → state →
declared `Cancel` secondary action → state → close. If the first observation is an
already-open Help menu declaring `Cancel`, it performs that action once and reads a
fresh state. Preparation succeeds only if that read shows a closed Help entry in the
menu bar; otherwise the driver stops without a click/retry. This produces seven calls
instead of five. Every action uses an index from the latest state, and every `Cancel`
must be explicitly advertised on that element. No Escape fallback is assumed.

The report includes route (`closed-help` or `prepare-open-help`), expected step count,
each step's purpose, preparation confirmation and final Help-closed confirmation.
It requires unlocked state during the five or seven protected calls,
zero model turns, one `SPACE_ATTACH`, one `SPACE_CLEANUP`, one `CLOSED lockState=1`
and final confirmed relock. A private report is written only under `macos/build/`.
User confirmation of a continuous visual curtain remains unrecorded. Do not retry
a failed action automatically. The driver reads the
native log only to count lifecycle events; ensure no competing caller during acceptance.

Two supervised attempts with the first continuous candidate stopped after initial
inspection because Help was already open (2026-09-28). Both confirmed one native
attach/cleanup and final relock; neither qualified the action sequence. The revised
driver handles that observed precondition explicitly. Its parsing contract is checked
with `node --test macos/native/test-finder-menu.mjs`; real `Cancel` preparation and
final closure then passed in the seven-call acceptance above. The two earlier
precondition failures remain preserved as private evidence.

The installed runtime tarball is unchanged, SHA-256
`c352b949b3c1f6479a31d87b6b54a73fa5ab3b457ac93f14e28f42fdda528945`.
It does **not** contain the latest Cancel-based acceptance driver/parser; acceptance
used the current driver source with the matching runtime. Building a new package
from this branch includes the updated driver/parser and requires a new artifact
directory/checksum. Publishing the Git branch does not rebuild or overwrite the
installed runtime tarball.

## Status, removal and rollback

```sh
node /absolute/path/to/installed/codex-computer-use-mcp/dist/mcp-server.js --status
sudo python3 macos/native/install-native.py remove
```

For rollback of the active continuous version: after IDLE, remove its native installation, rebuild
and install the previous native source, and restore only the backed-up MCP entry
pointing to `locked-use-20260928`. The prior tarball, installed proxy and historical
native build remain the rollback baseline. Restoring only the old proxy while
leaving the new native protocol installed is not a complete rollback.

## Host-specific compatibility and limits

Baseline: macOS 27.0 build 26A428 arm64, two displays, Codex
0.158.0-alpha.2.1 / Computer Use component 1001242, existing controller TCC grants.
SkyLight Space ABI and lock-state/UI notifications are private and qualified for
that host, not promised across macOS versions. `WindowSpace.m` retains the upstream
MIT attribution and `native/SkyLightWindow-LICENSE.txt` is shipped in the native app.
An API return/metadata sample is not a frame-by-frame visual guarantee.

There is one Guardian, no backup curtain. An uncertain in-flight Allow can retain
coverage until a safe relock is confirmed; timeouts never authorize hiding it.
Display changes abort/relock. Input protection remains active throughout retained
idle periods. There is no new remote auth, credential storage, model turn, UI setting
or app/intent classification.
