# porthole-mcp

Expo config plugin for [Porthole](https://github.com/adrum/porthole-mcp): it
puts the Porthole harness into your iOS app's Debug builds, so coding agents
like Claude Code, Codex and Cursor can inspect, drive and audit the running
app over MCP. No Screen Recording or Accessibility permission is involved.

```sh
npm install --save-dev porthole-mcp
```

```json
{ "expo": { "plugins": ["porthole-mcp"] } }
```

`expo prebuild` adds the harness to the app target as a local Swift package
(shipped inside this npm package, so no network or Git access is needed) and
starts it at the top of `didFinishLaunchingWithOptions`, inside `#if DEBUG`.
Release builds compile it to empty stubs. Pass
`["porthole-mcp", {"hub": "unix:/path/to/hub.sock"}]` to dial a different
hub. Supports Swift AppDelegates (Expo SDK 51 and later).

The harness connects to the Porthole app, which runs the hub and the MCP
server your agent talks to. See the
[repository](https://github.com/adrum/porthole-mcp) for the tools, selectors
and accessibility audits.

MIT licensed.
