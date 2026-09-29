# Codex Computer Use MCP

Expose OpenAI's official signed macOS Computer Use tools directly to Pi and MCP clients. The calling agent chooses each method and its arguments. This package runs no nested model and generates no action plan.

OpenAI does not produce or endorse this independent project. It relies on an experimental app-server API and installed ChatGPT components that may change.

## Requirements

- macOS with an unlocked user session
- Node.js 22 or newer
- the official ChatGPT macOS app at `/Applications/ChatGPT.app`
- the Computer Use component installed by ChatGPT under `~/.codex/computer-use/`
- Pi 0.80.7 or newer when using the Pi integration

macOS Screen Recording, Accessibility and TCC controls still apply.

The broker is discovered at `ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`, with fallback to `Contents/Resources/codex` only when the current layout is absent. A configured override takes precedence; failed verification never falls back to another binary. `computer_use_status` reports `brokerPath` on successful verification or `verificationError` on failure.

If the Codex binary bundled with ChatGPT is temporarily incompatible with the installed Computer Use component, set `CODEX_COMPUTER_USE_CODEX_PATH` to the canonical path of a compatible native Codex binary from an official OpenAI installation:

```bash
export CODEX_COMPUTER_USE_CODEX_PATH=/absolute/path/to/codex
```

The adapter verifies the selected binary's code signature and OpenAI Team ID before use. It rejects unsigned binaries, binaries signed by another team and symlinked paths.

### Optional native macOS locked-use complement

Native integration is disabled by default. Explicit `CODEX_COMPUTER_USE_NATIVE_LOCK=1` requires the manually installed MacLock helper at `/Library/Application Support/MacLock/MacLock.app`; a missing helper is an error, not a silent fallback. Source, installer, contracts and instructions are included in [`macos/`](macos/README.md). There is no automatic/root install hook and no redistributed OpenAI binary. The ordinary unlocked-session requirement above remains the default.

The continuous-protection version retains one curtain across nearby calls in the official session: at most 120 seconds per active call, then 30 seconds idle, enforced natively and renewed only by real call transitions, without heartbeats. Session close, errors, cancellation or local input revoke protection; normal idle cleanup permits a fresh lease on the next call without discarding the official session. `list_apps` and status do not acquire/renew protection. A successful retained call does not imply relock; `brokerCleanupVerified` remains false until session cleanup. Other clients receive BUSY while the single global guard is held.

The continuous baseline passed seven Finder calls in **8.647 seconds** on 2026-09-28. The wake-enabled version is now **installed and active**, after supervised Safari acceptance on 2026-09-29 in **6.759 seconds**: started locked with all displays asleep and login UI hidden, woke the display through public IOPM APIs, confirmed the locked login UI before protection/Allow, returned a useful Safari image, and finished locked with cleanup and power-hold release confirmed. There was one native protection cycle, no tool error and zero model turns. This qualifies **display sleep**, not system sleep, shutdown or a closed lid. No global power timers or backend restart were involved. This fork's `main` includes continuous protection and the display-wake fix. Deployment details, the unchanged installed package checksum and private-evidence references are in `macos/README.md`. There is no LaunchAgent or OpenCode core change. Private macOS SPI compatibility is host-specific. A cleanup error does not imply an official action was rolled back; never automatically repeat a mutation.

## Pi

Install from npm:

```bash
pi install npm:codex-computer-use-mcp
```

The extension registers and activates one composable tool:

```text
computer_use({ code: string })
```

The code runs with `sky`, `emit`, `emitImage` and a persistent `store` object. `sky` exposes all ten official Computer Use methods, so known sequential actions can run without a model round-trip between each action:

```js
const state = await sky.get_app_state({ app: "TextEdit" });
emit(state.text);

await sky.click({ app: "TextEdit", element_index: "7" });
await sky.type_text({ app: "TextEdit", text: "hello" });
const next = await sky.get_app_state({ app: "TextEdit" });
emit(next.text);
```

Only values passed to `emit(...)` or `emitImage(...)` are returned to Pi. `list_apps` returns the official text inventory produced by the app-server transport; unlike native `@oai/sky`, that transport does not provide the structured app array. `get_app_state` may return an accessibility-tree diff after the first inspection; pass `disableDiff: true` to request a fresh full tree. Screenshot payloads remain in the parent process and cross the code-worker boundary only as small opaque handles. Code runs in a worker so an unbounded loop can be terminated without freezing Pi; time spent inside an official Computer Use call does not count toward the code execution slice. If a later action fails, Pi still receives earlier emitted observations and the attempted method sequence.

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

The adapter has one mode. Pi exposes the ten official methods through the single `computer_use` code tool; MCP exposes them as ten typed methods. Both are available without wrapper permission prompts. It adds no app allowlist, action gate, intent classifier, selector rewrite or focus policy. App-server uses Codex Full access. The adapter forwards any elicitation that the official host still emits.

Production calls require verified OpenAI-signed app-server and Computer Use binaries with Team ID `2DC432GLL2`. The adapter uses an isolated, credential-free app-server context. It rejects any model-turn activity. Calls after `get_app_state` reuse the signed session, preserving element identifiers and official app state.

Audit records contain bounded metadata. They exclude arguments, app content, screenshots, prompts and credentials. MCP and CLI state defaults to `~/.direct-computer-use`. Pi state defaults to `direct-computer-use` under the Pi agent directory. Set `CODEX_COMPUTER_USE_HOME` to override either default.

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
