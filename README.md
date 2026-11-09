# Porthole

Let a coding agent see and use the app you're building. Porthole puts a
small Debug-only harness inside your app. The harness reports the app's own
UI tree and takes input through the app's real input paths, so agents like
Claude Code, Codex and Cursor can inspect, tap, type and audit it over MCP.
Screenshots show the real screen on Simulators and Android devices, and are
drawn by the app on macOS. No Screen Recording or Accessibility permission
is involved.

This repository holds the harness and its protocol:

- `apple/`: the `Porthole` Swift package, for macOS (AppKit and SwiftUI) and
  for iOS, tvOS, visionOS and watchOS apps in the Simulator, plus CarPlay
  templates.
- `expo/`: `porthole-mcp`, the Expo config plugin for React Native apps.
- `docs/protocol.md`: how the harness talks to the hub. Anything that
  implements it can be driven by Porthole.
- `demos/`: small apps that exercise the harness.

The harness connects to the **Porthole app**, which runs the hub and the MCP
server your agent talks to:

```
agent ──MCP──▶ Porthole (hub) ◀── WebSocket ── Porthole harness in each app
```

Apps dial the hub when they start and stay connected. They report when what's
on screen changes, so agents react right away instead of polling, and pass
along what they print.

## Add the harness

### Swift package (macOS and iOS)

In Xcode, choose File › Add Package Dependencies…, add this repository, and
link the `Porthole` library to your app target. Then start it early:

```swift
#if DEBUG
import Porthole
#endif

// in applicationDidFinishLaunching / didFinishLaunchingWithOptions / App.init
#if DEBUG
Porthole.start()
Porthole.registerHook("reset") { store.reset() }   // optional: hooks the agent can run
#endif
```

All of `Porthole` compiles only under `#if DEBUG`; in Release the calls are
empty inline stubs. `Porthole.start()` connects to the hub in the background
and keeps reconnecting, so it never blocks or fails your launch, and the hub
can start before or after the app. `Porthole.start(Porthole.Options(hub:
"unix:/path/to/hub.sock"))` dials a different hub.

### CarPlay

CarPlay templates are drawn by the system, so register them from your
CarPlay scene delegate:

```swift
func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                              didConnect interfaceController: CPInterfaceController) {
    #if DEBUG
    Porthole.registerCarPlay(interfaceController)   // pass window: for a navigation app's map
    #endif
}
```

The templates then appear as window `carplay`: list items, grid buttons,
alert actions, tabs and a back button you can `inspect` and `click`. Give a
list item or template an id with `userInfo = "my-id"`. In the Simulator,
connect CarPlay from I/O > External Displays > CarPlay.

### Expo

```sh
npm install --save-dev porthole-mcp
```

```json
{ "expo": { "plugins": ["porthole-mcp"] } }
```

`expo prebuild` then adds the harness to the app target as a local Swift
package (shipped inside the npm package, so no network or Git access is
needed) and starts it at the top of `didFinishLaunchingWithOptions`, inside
`#if DEBUG`. Release builds compile the package to empty stubs. Pass
`["porthole-mcp", {"hub": "unix:/path/to/hub.sock"}]` to dial a different
hub. The plugin is idempotent and supports Swift AppDelegates (Expo SDK 51
and later).

React Native apps without Expo add this repository as a Swift package in
Xcode, the same way as any other app.

### No changes to the app

Agents can also load the harness into a Debug build that doesn't include it:
`attach` loads it into a running app with lldb, and `launch {inject: true}`
preloads it. The Porthole app ships the injectable library, built from
`apple/Sources/PortholeInject` by `apple/scripts/build-inject.sh`. Both need a
debuggable build (Xcode's Debug default), developer tools enabled
(`DevToolsSecurity -enable`), and on macOS no Hardened Runtime library
validation. System and App Store apps can't be attached to.

## Tools

| tool | what it does |
| --- | --- |
| `apps` | List targets: id, name, platform, how each is reached, its hooks, and which is active. |
| `launch {path, args?, env?, simulator?, window?, inject?}` | Start a macOS `.app` (in the background), a plain executable, or an iOS, tvOS, watchOS or visionOS `.app` on a matching Simulator. Waits until it answers, then makes it active. |
| `attach {pid?, app?}` | Load the harness into a running app with lldb. |
| `inspect {app?, window?, format?, a11y?}` | The UI tree: `outline` (default, one line per element) or `json`. |
| `screenshot {app?, window?, target?, source?}` | A PNG of the screen or one element: the real screen on Simulators and Android, the app's own drawing on macOS or with `source: "app"`. See [Screenshots](#screenshots). |
| `click {target}` / `click {x, y}` | Press an element (its primary action) or a point. |
| `fill {target, text}` | Replace a field's text through the real input path, so delegates, `onChange`, `onChangeText` and SwiftUI bindings fire. |
| `press_key {key, modifiers?, target?}` | Enter, Tab, Escape, Backspace, Delete, Space, arrows, Home, End, PageUp, PageDown, or one character; `modifiers` of `cmd`, `shift`, `alt`, `ctrl`. |
| `scroll {target?, direction, amount?}` | Scroll a scroll view (or the largest on screen) up, down, left or right, by points (default 300). |
| `wait_for {target, state?, timeout_ms?}` | Wait until an element is `visible` (default) or `gone`. |
| `run_hook {name}` | Run a hook the app registered. |
| `logs {app?, grep?, stream?, limit?}` | What the app recently printed to stdout and stderr (`print`, `NSLog`), newest last. |

An outline looks like this:

```
window "AppKit Demo" #w2850
  textfield "Email" = "me@example.com" #email [focused]
  checkbox "Subscribe" = true #subscribe [checked]
  button "Save" #save
  button "Disabled" #disabled [disabled]
  text "Saved me@example.com" #status
  button "Close" #close (covered)
```

Apps work in the background: the harness never needs the app to be
frontmost. On macOS, `inspect` and `wait_for` read a minimized window as it
is, and screenshots and actions unhide the app and restore the window first;
in the Simulator, the app must be in the foreground on the simulated device.

## Screenshots

`screenshot` returns one of two pictures, and its caption says which:

- **The screen**, as the user sees it, captured by the Simulator
  (`simctl io screenshot`) or Android (`adb screencap`). No permission is
  needed. This is the default on Simulators and Android emulators.
- **The app's drawing**: the app renders its own window in-process. It works
  while the app is covered or in the background, and shows only the app's
  pixels. This is what macOS and Rune apps always use, and what you get
  anywhere with `source: "app"`.

Both are scaled so one pixel is one point, so pixel coordinates match
`click {x, y}`; the caption says when the window is offset on the screen.

The server falls back to the app's drawing, and says why in the caption,
when the app isn't in front (a screen capture would show something else) or
when the screen can't be captured. On a physical Android phone the default
is the app's drawing, since the screen can show notifications and other
apps; pass `source: "screen"` to capture it anyway.

You decide what agents may use in the Porthole app, under Settings ›
Screenshots: Default, App drawing or Device, per platform and per app (an
app's choice overrides its platform's). App drawing gives agents the app's
drawing even when they ask for the screen. Device always captures the screen
and never falls back: when it can't, the agent gets an error saying why. The
choices are saved in `~/Library/Application Support/porthole-mcp/screenshots.json`
and apply to the next screenshot.

What each picture can miss:

| Platform | The screen | The app's drawing |
| --- | --- | --- |
| macOS | Not available: it would need Screen Recording permission. | Other windows on top, menus and the cursor aren't shown. Video or GPU-drawn content can come out blank. Vibrancy is included. |
| iOS Simulator | Everything on screen, the keyboard and system alerts included. | The keyboard, system alerts and status bar are separate windows and aren't shown. Transitions get caught mid-animation, and iOS 26 glass effects can be drawn out of place. |
| tvOS, watchOS Simulators | Everything on screen; watchOS corners are filled black. | Only the app's own window. |
| visionOS Simulator | The whole view, surroundings included. Element frames can't be placed on it, so a screenshot cropped to one element is the app's drawing. | Only the app's window, without depth or the surroundings. |
| CarPlay | The Simulator's CarPlay display. | Not available: templates are drawn by the system. |
| Android | Everything on screen, the keyboard, dialogs and system bars included. | Video, maps and camera views can come out blank. The keyboard and system bars aren't shown, and a dialog or popup is its own window. |

## Selectors

A target is space-separated terms that must all match:

| term | matches |
| --- | --- |
| `#save` | id: the accessibility identifier (SwiftUI `.accessibilityIdentifier`, React Native `testID`), else a synthesized `_xxx` id. Repeated identifiers become `row`, `row@2`, ...; `#row` matches them all. |
| `role:button` | role, case-insensitive: window, group, button, link, text, textfield, securefield, textarea, checkbox, switch, slider, image, list, row, cell, tab, menu, menuitem, scrollview, other |
| `"Save"` | the exact name |
| `~"sav"` | name or value contains the text, case-insensitive |
| `nth:2` | the second remaining match (1-based) |

Examples: `#email`, `role:button "Save"`, `role:row nth:3`, `~"saved"`.

Click list and sidebar rows by selector, not by `click {x, y}`: a selector
selects the row through accessibility, which drives a SwiftUI List's
selection, while a coordinate click is a synthetic mouse event that rows
often ignore.

When one match is nested inside another, the outer one wins (a React Native
Pressable and its Text are one element). When several remain, uncovered ones
are preferred; if still ambiguous, the error lists the candidates and
suggests `nth:` or an id.

## Accessibility audits

`inspect {a11y: true}` adds what assistive technology gets to each line, next
to what the screen shows, so an agent can check an app against WCAG:

```
button "Save" #save a11y[traits=button; font=15pt fixed; contrast=3.66:1 #0083FF on #FEFEFF]
text "Terms apply" #_9 a11y[hidden from assistive tech]
other #_a a11y[unreachable: takes touches but assistive tech can't reach it]
slider #level a11y[no label]
```

That covers labels, hints and traits, the visible text, the font size and
whether it follows Dynamic Type, text contrast measured from the rendered
pixels, visible text that VoiceOver skips, and touch targets it can't reach.
Frames give target sizes. For Dynamic Type and dark mode passes on the
Simulator, change the setting (`xcrun simctl ui booted content_size
accessibility-extra-large`, `xcrun simctl ui booted appearance dark`) and
inspect again. Automated checks find a share of real problems; test with
VoiceOver too.

## App settings

| variable | effect |
| --- | --- |
| `PORTHOLE_MCP_DIR` | the hub's directory (default `/tmp/porthole-mcp-<uid>/`) |
| `PORTHOLE_MCP_HUB` | dial this hub: `unix:/path/to/hub.sock` |
| `PORTHOLE_MCP_DISABLE=1` | don't connect |
| `PORTHOLE_MCP_CAPTURE_LOGS=0` | don't send stdout and stderr to the hub |

The harness only dials a hub socket that belongs to the app's own user.

## Develop

```sh
(cd apple && swift test)                  # harness unit tests
(cd expo && npm install && npm test)      # plugin, against real expo prebuild output
apple/scripts/build-inject.sh             # the injectable library, into apple/.build/inject/
```

The demo projects are generated with XcodeGen from each demo's
`project.yml`.

## Known limitations

- SwiftUI elements that have no identifier get ids that last only as long as
  SwiftUI keeps the element object.
- On iOS, keys go through the text-input path: modifier combinations beyond
  cmd+a/c/x/v/z aren't supported.
- tvOS, visionOS and watchOS are tested end to end on their Simulators. On
  tvOS there are no touches (presses use each element's own action) and
  arrow-key focus movement isn't supported; watchOS supports inspect,
  screenshot, press and scroll only.
- CarPlay support is experimental: typechecked but not yet run end to end.
  CarPlay screenshots come from the Simulator's external display, and
  template frames are nominal.

## License

MIT, see [LICENSE](LICENSE).
