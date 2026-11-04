# Codex Computer Use MCP

Expose OpenAI's official signed macOS Computer Use tools directly to Pi and MCP clients. The calling agent chooses each method and its arguments. This package runs no nested model and generates no action plan.

OpenAI does not produce or endorse this independent project. It relies on an experimental app-server API and installed ChatGPT components that may change.

## Requirements

- macOS with an unlocked user session
- Node.js 22 or newer
- the official ChatGPT macOS app, by default at `/Applications/ChatGPT.app`
- the Computer Use component installed by ChatGPT, by default under `~/.codex/computer-use/`
- Pi 0.99.0 or newer when using the Pi integration

macOS Screen Recording, Accessibility and TCC controls still apply.

Discovery and the `config.json` overrides are described under [Paths](#paths). A present but invalid binary fails verification and never falls back to another one. `computer_use_status` reports `codexPath` on successful verification or `brokerError` on failure.

If the Codex binary bundled with ChatGPT is temporarily incompatible with the installed Computer Use component, set `CODEX_COMPUTER_USE_CODEX_PATH` to the canonical path of a compatible native Codex binary from an official OpenAI installation. It takes precedence over `codexPath` in `config.json` and over discovery:

```bash
export CODEX_COMPUTER_USE_CODEX_PATH=/absolute/path/to/codex
```

The adapter verifies the selected binary's code signature and OpenAI Team ID before use. It rejects unsigned binaries, binaries signed by another team and, for this variable, symlinked or relative paths.

### Optional native macOS locked-use complement

Native integration is disabled by default. Explicit `CODEX_COMPUTER_USE_NATIVE_LOCK=1` requires the manually installed MacLock helper at `/Library/Application Support/MacLock/MacLock.app`; a missing helper is an error, not a silent fallback. Source, installer, contracts and instructions are included in [`macos/`](macos/README.md). There is no automatic/root install hook and no redistributed OpenAI binary. The ordinary unlocked-session requirement above remains the default.

The continuous-protection version retains one curtain across nearby calls in the official session: at most 120 seconds per active call, then 30 seconds idle, enforced natively and renewed only by real call transitions, without heartbeats. The proxy times out a protected call after 115 seconds, so it ends the lease itself before the native deadline, which treats an overrun as a frozen proxy and suppresses locked use until manual unlock. Session close, errors, cancellation or local input revoke protection; normal idle cleanup permits a fresh lease on the next call without discarding the official session. `list_apps` and status do not acquire/renew protection. A successful retained call does not imply relock; `brokerCleanupVerified` remains false until session cleanup. Other clients receive BUSY while the single global guard is held.

The continuous baseline passed seven Finder calls in **8.647 seconds** on 2026-09-28. The wake-enabled version is now **installed and active**, after supervised Safari acceptance on 2026-09-29 in **6.759 seconds**: started locked with all displays asleep and login UI hidden, woke the display through public IOPM APIs, confirmed the locked login UI before protection/Allow, returned a useful Safari image, and finished locked with cleanup and power-hold release confirmed. There was one native protection cycle, no tool error and zero model turns. This qualifies **display sleep**, not system sleep, shutdown or a closed lid. No global power timers or backend restart were involved. This fork's `main` includes continuous protection and the display-wake fix. Deployment details, the unchanged installed package checksum and private-evidence references are in `macos/README.md`. There is no LaunchAgent or OpenCode core change. Private macOS SPI compatibility is host-specific. A cleanup error does not imply an official action was rolled back; never automatically repeat a mutation.

## Pi

Install from npm:

```bash
pi install npm:codex-computer-use-mcp
```

The extension registers the ten official Computer Use methods as Pi tools named `computer_use_<method>`, such as `computer_use_get_app_state` and `computer_use_click`. They use Pi's `codemode` exposure, so agents call and compose them from Pi's built-in `codemode` tool together with other Pi and MCP tools:

```js
const state = await tools.computer_use_get_app_state({ app: "TextEdit" });
text(state.text);
image(state.screenshot);

await tools.computer_use_click({ app: "TextEdit", element_index: "7" });
await tools.computer_use_type_text({ app: "TextEdit", text: "hello" });
const next = await tools.computer_use_get_app_state({ app: "TextEdit" });
text(next.text);
```

`element_index` accepts a string or a safe integer for all five methods that use it. Integers are converted to strings before reaching the official tools; string identifiers are preserved exactly. Use indices from the latest app state, because actions can invalidate earlier indices.

The extension does not change which tools are active. Turn on `codemode` with `"defaultTools": ["+codemode"]` in `settings.json` or with `pi --tools +codemode`; Pi also turns it on when an MCP server uses `codemode` exposure. When neither `codemode` nor a Computer Use tool is active, the extension shows one notice at the first prompt.

`computer_use_get_app_state` resolves to `{ app, text, screenshot }`, where `screenshot` is an image block for `image()` or `null`. It may return an accessibility-tree diff after the first inspection; pass `disableDiff: true` to request a fresh full tree. `computer_use_list_apps` resolves to the official text inventory produced by the app-server transport; unlike native `@oai/sky`, that transport does not provide the structured app array. Other methods resolve to their official text output. A failed call rejects with the official error text. Calls run one at a time, and calls after `get_app_state` reuse the signed session until the agent settles. The namespace instructions, available from `describeNamespace("computer_use")`, summarise this workflow.

Use `/computer-use-status` to inspect the installed component and transport status.

To run a source checkout:

```bash
npm ci
npm run build
pi -ne -e /absolute/path/to/codex-computer-use-mcp/integrations/pi/index.ts
```

## MCP

Running the package binary starts a stdio MCP server with the same ten methods and `computer_use_status`:

```bash
npx codex-computer-use-mcp
```

Example OpenCode V2 configuration:

```json
{
  "mcp": {
    "servers": {
      "codex-computer-use": {
        "type": "local",
        "command": ["codex-computer-use-mcp"]
      }
    }
  }
}
```

This fork has been verified with the ChatGPT-bundled Codex `0.154.0-alpha.6.2`.
Use `CODEX_COMPUTER_USE_CODEX_PATH` only when the installed ChatGPT component
requires a different compatible OpenAI-signed Codex binary.

Example Pi MCP configuration:

```json
{
  "mcpServers": {
    "computer-use": {
      "command": "npx",
      "args": ["codex-computer-use-mcp"],
      "lifecycle": "lazy",
      "requestTimeoutMs": 180000,
      "directTools": false
    }
  }
}
```

## Behaviour

The adapter has one mode. Pi and MCP both expose the ten official methods as typed tools; Pi gives them `codemode` exposure. Both are available without wrapper permission prompts. It adds no app allowlist, action gate, intent classifier, selector rewrite or focus policy. App-server uses Codex Full access. The adapter forwards any elicitation that the official host still emits.

Production calls require verified OpenAI-signed app-server and Computer Use binaries with Team ID `2DC432GLL2`. The adapter uses an isolated, credential-free app-server context. It rejects any model-turn activity. Calls after `get_app_state` reuse the signed session, preserving element identifiers and official app state.

Closing a retained session sends a matching native `turn-ended` notification through the signed app-server before terminating its private processes. This lets the shared Computer Use service remove that session's software cursor without terminating the service. Cancellation and tool timeouts briefly wait for an outstanding native reply before notifying, so a late reply cannot recreate the cursor after cleanup. A stalled request, failed notification, or lost transport can prevent native cleanup. The call still returns its result, because the action already ran, and private process teardown still runs. `brokerCleanupVerified` describes private process cleanup, not visual confirmation that a cursor disappeared.

The service hides cursors only once every turn it has seen has ended: one turn that never receives `turn-ended` keeps every later cursor on screen for as long as the service runs, which is as long as the ChatGPT app when the app started it. Each session therefore records its open turn under `open-turns/` in the state directory before its first call and removes the record once its notification succeeds. Closing a session also ends, through the same signed path, up to eight recorded turns whose owning process or session is gone; records older than seven days are dropped. The MCP server ends its retained session's turn when stdin ends or on `SIGTERM`, `SIGINT` or `SIGHUP`, then kills its private processes at once, within the stdio client's grace period, rather than leaving the turn to a later session.

Audit records contain bounded metadata. They exclude arguments, app content, screenshots, prompts and credentials. MCP and CLI state defaults to `~/.direct-computer-use`. Pi state defaults to `direct-computer-use` under the Pi agent directory. Set `CODEX_COMPUTER_USE_HOME` to override either default.

### Paths

By default the adapter checks `/Applications/ChatGPT.app`, then `~/Applications/ChatGPT.app` in the OS account's home directory. In each bundle it looks for `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`, then `Contents/Resources/codex` on older ChatGPT builds. It uses the Computer Use app at `~/.codex/computer-use/Codex Computer Use.app`, falling back to the copy bundled in either ChatGPT installation on older builds. It does not use an arbitrary `codex` on `PATH` or the ambient `CODEX_CLI_PATH`.

When ChatGPT is installed elsewhere or moves these files, set either path in `config.json` in the state directory:

```json
{
  "codexPath": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
  "computerUseAppPath": "/Users/me/.codex/computer-use/Codex Computer Use.app"
}
```

The adapter reads this file when it starts each Computer Use session, so changes apply without restarting Pi or the MCP server. Configured binaries must pass the same OpenAI signature and Team ID checks. Explicit overrides take precedence: a missing or invalid configured binary never silently falls back to another installation.

If a component is missing, install or update the [official ChatGPT macOS app](https://chatgpt.com/download), open it, and install its Computer Use component. Installing this npm package alone does not install those signed components. The error lists every path checked and the exact config file to edit. Correct `codexPath` / `computerUseAppPath` there, or remove a stale override to restore automatic discovery. For Pi this is normally `~/.pi/agent/direct-computer-use/config.json`; for standalone MCP/CLI it is `~/.direct-computer-use/config.json`. `CODEX_COMPUTER_USE_HOME` overrides the state directory. `/computer-use-status` and `codex-computer-use-mcp --status` show the effective config path and the current error.

Pi limits returned text to 50KB or 2,000 lines. When text exceeds that limit, the complete text is written to a mode-0600 file in a private directory under `/tmp`. Images are returned directly and are never spilled to disk.

## Development

```bash
npm ci
npm run check
npm run check:pi
npm test
npm run build
```

## License

MIT
