# porthole-mcp protocol, version 2

porthole-mcp has three kinds of process. This document defines how they talk.

- **The hub** (`porthole-mcp daemon`) is long-running. It keeps a connection
  to every app that runs the harness and carries out the tools.
- **Apps** run a harness (the Swift `Porthole` module, or anything else that
  implements this document). The harness dials the hub when the app starts
  and stays connected.
- **Clients** of the hub: the stdio MCP process an agent starts
  (`porthole-mcp`), the CLI (`porthole-mcp status`) and the menu bar app.

The hub, the MCP relay and the menu bar app ship as the Porthole app; this
repository holds the harness and this protocol.

```
agent ──stdio──▶ porthole-mcp ─┐                      ┌─◀── app (Porthole harness)
                             ├──▶ hub.sock ◀── hub ─┼─◀── app
menu bar app, CLI ───────────┘   (porthole-mcp daemon)└─◀── app
```

Version 1, where each app listened on its own socket and the server
connected per request, is retired.

## The hub

- The hub runs as a per-user LaunchAgent, label
  `com.austindrummond.porthole-mcp.daemon`, with `KeepAlive`, so launchd
  restarts it if it stops. Without the LaunchAgent, the first stdio client
  that can't connect starts `porthole-mcp daemon` itself, detached; a hub
  started that way exits after 15 minutes with no clients and no apps.
- The hub listens on one Unix socket, `<dir>/hub.sock`, where `<dir>` is
  `$PORTHOLE_MCP_DIR` or `/tmp/porthole-mcp-<uid>/`, `<uid>` being the numeric
  user id. iOS, tvOS, watchOS and visionOS Simulator apps are host processes
  running as that user, so they reach the same path. A harness in the
  Simulator must use this literal host path, never `NSTemporaryDirectory()`,
  which points inside the simulated device.
- The hub creates `<dir>` with mode `0700` and the socket with mode `0600`.
  It refuses to start if `<dir>` exists but is owned by another user or is
  group- or world-accessible. File permissions are the access control:
  anyone who can connect can drive every connected app.
- Only one hub runs per directory. A hub that finds a live `hub.sock`
  (one that accepts a connection) exits; it removes a dead one and takes
  over.

Every connection to `hub.sock` starts as HTTP/1.1. The path picks what it is:

| path | kind | used by |
| --- | --- | --- |
| `GET /v2/app` | WebSocket upgrade: an app link | harnesses |
| `GET /v2/mcp` | WebSocket upgrade: one MCP session | the stdio process |
| `GET /v2/control` | WebSocket upgrade: status and events | menu bar app, CLI |
| `GET /v2/info` | plain HTTP, JSON | debugging |
| `GET /v2/apps` | plain HTTP, JSON | debugging |
| `GET /v2/apps/<id>/tree` | plain HTTP, JSON | debugging |

Debug from a shell with curl (the host part of the URL is ignored):

```sh
curl --unix-socket /tmp/porthole-mcp-$(id -u)/hub.sock http://hub/v2/apps
curl --unix-socket /tmp/porthole-mcp-$(id -u)/hub.sock http://hub/v2/apps/com.example.Demo-1234/tree
```

## WebSocket messages

All three WebSocket kinds carry JSON-RPC 2.0, one message per text frame.
Requests can flow in both directions on one connection; ids are chosen by
the sender and are only unique per direction. The hub sends a WebSocket
ping every 10 seconds; a peer that misses three is treated as gone.

## The app link (`/v2/app`)

### Connecting

1. The harness connects to `hub.sock` and upgrades `GET /v2/app`. It finds
   the hub at `$PORTHOLE_MCP_HUB` (`unix:/path`, or `ws://host:port` for
   devices, a later phase) when set, otherwise at the default socket path.
   Before connecting to a Unix socket it checks that the socket is owned by
   its own user, so another user can't impersonate the hub.
2. Its first message is the `hello` request. The hub answers with the
   target id it assigned. Until `hello` succeeds the hub sends nothing else.
3. When the connection drops, or the hub isn't running yet, the harness
   reconnects on its own, waiting 0.25 s, then doubling up to 5 s between
   attempts, for as long as the app runs. An app never needs restarting
   because the hub restarted.

`PORTHOLE_MCP_DISABLE=1` in the app's environment stops the harness from
connecting at all.

### `hello` (app → hub)

```json
{"jsonrpc": "2.0", "id": 1, "method": "hello", "params": {
  "protocol": 2,
  "appId": "com.example.Demo",
  "name": "Demo",
  "pid": 1234,
  "platform": "macos",
  "simulator": false,
  "toolkits": ["appkit", "swiftui"],
  "capabilities": ["tree", "screenshot", "press", "pressAt", "fill", "key", "focus", "scroll", "hooks"],
  "hooks": ["reset", "seed"]
}}
```

```json
{"jsonrpc": "2.0", "id": 1, "result": {"protocol": 2, "hub": "porthole-mcp 0.2.0", "target": "com.example.Demo-1234"}}
```

- `appId` is the bundle identifier, or the process name if there is none.
- `platform` is `macos`, `ios`, `tvos`, `visionos` or `watchos`.
- `toolkits` lists what the harness detected in the process (`appkit`,
  `uikit`, `swiftui`, `react-native`, `watchkit`, and `carplay` while CarPlay
  is connected).
- `capabilities` lists the requests and actions this harness implements.
- The target id is `<app-id>-<pid>`. If that id is already connected (the
  same process reconnecting), the new link replaces the old one.
- A hub that doesn't speak the harness's `protocol` answers with an
  `invalid_request` error that says which versions it speaks, and closes.

### Requests (hub → app)

| method | params | result |
| --- | --- | --- |
| `windows` | — | `{"windows": [Window]}` |
| `tree` | `window?`, `a11y?` | `{"window": id, "root": Node}` |
| `screenshot` | `window?`, `node?`, `scale?` | `{"png": "<base64>"}` |
| `act` | `window?`, `action`, action fields | `{"detail": "..."}` |
| `runHook` | `name` | `{}` |

The harness answers requests in the order they arrive. UI work happens on
the app's main thread.

### Notifications (app → hub)

| method | params | meaning |
| --- | --- | --- |
| `hooksChanged` | `{"hooks": [...]}` | The app registered or removed a hook. |
| `uiChanged` | `{}` | Something on screen changed. |
| `log` | `{"stream": "stdout" \| "stderr", "text": "..."}` | One line the app wrote. |
| `bye` | `{"reason": "..."}` | The app is about to quit. Sent when the platform allows. |

`uiChanged` lets the hub react to the screen instead of polling it: a
`wait_for` re-checks its target when one arrives, and still re-checks every
quarter second in case a change went unnoticed. The Swift harness watches the
window's layer tree after each turn of the main run loop and sends at most
ten a second. Layers narrower than 4 points (a blinking text caret) don't
count.

`log` carries the app's own output. The Swift harness copies what the app
writes to stdout and stderr (`print`, `NSLog` in Debug, `FileHandle`
writes) while still passing it through to the console, at most 200 lines a
second; `PORTHOLE_MCP_CAPTURE_LOGS=0` turns this off. The hub keeps each app's
last 2,000 lines, which the `logs` tool returns.

### Errors

A failed request gets a JSON-RPC error whose `data.kind` says what went
wrong, and whose `message` is meant for a human or an agent and says what to
do next where it can:

```json
{"jsonrpc": "2.0", "id": 7, "error": {"code": -32001, "message": "no element with id \"save\"; inspect again", "data": {"kind": "not_found"}}}
```

| `code` | `data.kind` | meaning |
| --- | --- | --- |
| -32001 | `not_found` | Unknown window, node or hook. |
| -32602 | `invalid_request` | Missing or bad parameter, unknown method. |
| -32003 | `unsupported` | The action isn't possible for this node or platform. |
| -32004 | `failed` | The action was attempted and failed. |

## MCP sessions (`/v2/mcp`)

The agent starts `porthole-mcp` (no arguments) as a stdio MCP server. That
process is a relay:

- It connects to `hub.sock` and upgrades `GET /v2/mcp`, starting the hub
  first if needed (see The hub).
- It forwards every line it reads on stdin as one text frame, and writes
  every frame it receives as one line on stdout. It parses nothing except to
  remember the `initialize` request.
- If the hub connection drops, it reconnects, replays the remembered
  `initialize` (discarding the reply), and carries on. Requests that were in
  flight get an error result asking the agent to retry.

The hub runs the MCP session: protocol version negotiation, `tools/list`,
`tools/call`. Each session has its own active target, and its tool calls
run one at a time in arrival order; `ping` and `tools/list` are answered
even while a call runs. The tools and the selector grammar are described in
the README.

## Control (`/v2/control`)

Requests from the menu bar app and the CLI:

| method | result |
| --- | --- |
| `status` | `{"hub": "porthole-mcp 0.2.0", "pid": 1234, "apps": [AppSummary], "sessions": n}` |
| `subscribe` | `{}`, then events as notifications on the same connection |
| `logs` | `{"lines": [LogLine]}` for params `{"target", "limit?"}` |

`AppSummary` is the `hello` params plus `target`, `connectedAt` and `hooks`.
`LogLine` is `{"t": <unix seconds, fractional>, "stream", "text"}`.

After `subscribe`, the hub sends these notifications as they happen:

| method | params |
| --- | --- |
| `appConnected` | `AppSummary` |
| `appDisconnected` | `{"target", "reason"}` |
| `uiChanged` | `{"target"}` |
| `log` | `{"target", "line": LogLine}` |
| `sessionsChanged` | `{"sessions": n}` |

## Types

### Frame

```json
{"x": 12, "y": 40, "w": 120, "h": 32}
```

Numbers in points. Node frames are in **window coordinates**: origin at the
top-left of the window's content, y grows downward, on every platform.
Window frames are in screen coordinates (top-left origin).

### Node

```json
{
  "id": "save",
  "role": "button",
  "name": "Save",
  "value": "…",
  "states": {"enabled": false, "focused": true},
  "covered": true,
  "frame": {"x": 0, "y": 0, "w": 80, "h": 32},
  "children": [ ... ]
}
```

- `id` (string, required): the accessibility identifier when one is set
  (`accessibilityIdentifier`, SwiftUI `.accessibilityIdentifier()`, React
  Native `testID`). Otherwise a synthesized id, stable for the life of the
  underlying object within the session. Synthesized ids start with `_` (for
  example `_a3f`) so they can't collide with real identifiers that don't.
  When several elements share an identifier (rows built from one template,
  say), the first keeps it and later ones get `@2`, `@3`, ... in tree order
  (`row`, `row@2`, `row@3`), so every id in a tree is unique. Clients match a
  selector `#row` against all of them.
- `role` (string, required): one of
  `window`, `group`, `button`, `link`, `text`, `textfield`, `securefield`,
  `textarea`, `checkbox`, `switch`, `slider`, `image`, `list`, `row`, `cell`,
  `tab`, `menu`, `menuitem`, `scrollview`, `other`.
- `name` (string, optional): the accessible label, or the visible text.
- `value` (string, number or bool, optional): a field's text, a slider's
  value, a checkbox's or switch's on state.
- `states` (object, optional): only non-default flags are present:
  `enabled: false`, `focused: true`, `selected: true`, `checked: true`,
  `expanded: true`.
- `covered` (bool, optional): present and `true` when a press at the node's
  center would land on something else (another screen, a sheet, an overlay).
- `frame` (Frame, required).
- `a11y` (object, optional): accessibility facts, only when the tree was
  requested with `a11y` (see `tree` below).
- `children` (array of Node, optional): omitted when empty.

The tree contains only what is on screen: hidden, fully transparent,
zero-size and fully clipped nodes are left out, along with their subtrees.

### Window

```json
{"id": "w1", "title": "Demo", "key": true, "frame": {"x": 0, "y": 0, "w": 800, "h": 600}}
```

`foreground` (bool, optional) is `false` when the window's app is in the
background on a device with one app in front at a time (iOS, tvOS, visionOS,
Android). The server then screenshots the app's own drawing rather than the
screen, which would show something else. Absent means in front.

## Requests in detail

### `windows`

Visible windows, front to back. On iOS, tvOS and visionOS each `UIWindow` of
a foreground scene is a window.

While CarPlay is connected (the app called `Porthole.registerCarPlay`), the
list also has a window with id `carplay`. CarPlay templates are drawn by the
system, outside the app, so this window's tree is built from the template
objects: list items are rows, grid and bar buttons and alert actions are
buttons, tabs are tabs, and the implicit back button is `#carplay-back`.
Templates under the top of the stack, or under an alert, are `covered`.
Frames are a nominal layout (one 44 pt row per item on an 800×480 screen) and
say nothing about where the car draws things. `press` calls the item's
handler and `fill` updates a search template; the other actions and
`screenshot` return `unsupported`. A navigation app's map `CPWindow`, passed
to `registerCarPlay`, is an ordinary window.

### `tree`

`window` defaults to the key window (or the frontmost visible window if none
is key). The root node has role `window` and its frame starts at
`{x: 0, y: 0}`.

With `a11y: true`, nodes also carry an `a11y` object of accessibility facts
for audits, and the tree also lists visible things assistive technology
can't reach. The harness waits for the window to stop animating first, so
measurements describe a settled screen. Every field is optional:

| field | meaning |
| --- | --- |
| `element` | Whether assistive technology sees this node as an element. |
| `label`, `value`, `hint` | What VoiceOver reads. |
| `traits` | iOS accessibility traits by name (`button`, `header`, `toggle`, ...). |
| `role`, `roleDescription`, `title` | macOS accessibility role and description. |
| `class` | The platform class behind the node. |
| `text` | The text drawn on screen, to compare with `label`. |
| `noText` | The node's view draws no text. |
| `font` | `{size, dynamicType?}`: point size, and whether it follows Dynamic Type. |
| `contrast` | `{fg, bg, ratio}`: text and background colors measured from the rendered pixels, and their WCAG 2 contrast ratio. Not measured for covered nodes. |
| `hiddenFromAccessibility` | Visible text that assistive technology skips. |
| `unreachable` | A view that takes touches that assistive technology can't reach. |
| `focusable` | The node can take keyboard focus. |

Target sizes come from `frame`.

### `screenshot`

A PNG, base64-encoded, rendered in-process from the window's views and
layers over the window's background color, as on screen. Screen-capture
APIs are never used, so no Screen Recording permission is involved.

- `window` defaults as in `tree`.
- `node` crops to that node's frame.
- `scale` is pixels per point, default `1` so pixel coordinates equal window
  points. Values up to `3` are allowed.

### `act`

```json
{"window": "w1", "action": "press", "node": "save"}
```

| action | fields | effect |
| --- | --- | --- |
| `press` | `node` | The node's primary action (press a button, toggle a switch, select a row). |
| `pressAt` | `x`, `y` | A press at a point in window coordinates. |
| `fill` | `node`, `text` | Focus the field and replace its content through the platform's real text-input path, so delegates, change handlers, React Native `onChangeText` and SwiftUI bindings all fire. |
| `key` | `key`, `modifiers?` | Send a key to the focused element. |
| `focus` | `node` | Give the node keyboard focus. |
| `scroll` | `node?`, `dx`, `dy` | Scroll by points. Positive `dy` reveals content below, positive `dx` content to the right. With no node, the largest visible scroll view scrolls. |

`key` values: `Enter`, `Tab`, `Escape`, `Backspace`, `Delete`, `Space`,
`ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`, `Home`, `End`, `PageUp`,
`PageDown`, or a single character such as `a`. `modifiers` is an array of
`cmd`, `shift`, `alt`, `ctrl`.

Node ids refer to the tree as it is when the action runs: the harness
rebuilds the tree to resolve them.

Platform differences:

- tvOS has no touch screen. `press` uses the element's accessibility
  activation, a control's primary action, or selects a table or collection
  cell through its delegate. `key` outside a text field is the remote: Enter
  and Space select the focused item, Escape is Menu; arrow keys aren't
  supported yet. The focused item is marked `focused`.
- watchOS supports `press` (accessibility activation) and `scroll` (a page,
  through `accessibilityScroll:`); the other actions return `unsupported`.

### `runHook`

Runs the named hook on the main thread. `not_found` if no hook has that
name.
