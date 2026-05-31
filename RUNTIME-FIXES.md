# iOS runtime fixes — physical-device console triage

Branch: `fix/runtime-fonts-icon-keyboard`. Fixes the runtime issues surfaced running the
device (not simulator) build on a physical iPhone. **Implemented on Ubuntu; pending Mac
build-verify — no Xcode on the dev box, nothing here is build-tested.**

---

## 1. FiraCode fonts — P1 (terminal font missing from bundle)

**Console lines resolved**
```
FontParser: could not open '…/FiraCode-Regular.ttf': [2: No such file or directory]
FontParser: could not open '…/FiraCode-Medium.ttf':  [2: No such file or directory]
FontParser: could not open '…/FiraCode-Bold.ttf':    [2: No such file or directory]
GSFont: … file doesn't exist  (×3, matching the above)
```

**Root cause** — `Info.plist` declared three `UIAppFonts` entries (`FiraCode-Regular/Medium/Bold.ttf`)
but the TTFs were never in the repo, so iOS' font registration fails at launch. Separately,
`Theme.Typography.terminalFont` was `"SF Mono"`, which `Font.custom("SF Mono")` cannot resolve on
iOS (SF Mono is not registerable by name) — so even the SwiftUI terminal text silently fell back to
the system mono. The bundled-font intent (the `UIAppFonts` entries) was never actually wired.

**Fix**
- Vendored the three static TTFs + SIL OFL license → `ios/VibeTunnel/Resources/Fonts/`
  (`FiraCode-Regular.ttf`, `FiraCode-Medium.ttf`, `FiraCode-Bold.ttf`, `OFL.txt`). FiraCode v6.2.
  The Xcode 16 project uses a `PBXFileSystemSynchronizedRootGroup`, so files placed under
  `ios/VibeTunnel/` are auto-added to the target — **no manual `project.pbxproj` resource wiring**.
- `Info.plist` `UIAppFonts` entries are now satisfied (unchanged — they were already correct).
- `ios/VibeTunnel/Utils/Theme.swift`: `terminalFont = "FiraCode-Regular"` (the verified PostScript
  name, see below) and dropped the `.monospaced()` modifier from `terminal(size:)` — applying it to
  a custom font replaces it with the system mono face, defeating the bundled font.
- `ios/VibeTunnel/Views/Terminal/GhosttyWebView.swift`: the live terminal is a `WKWebView` rendering
  to a canvas, so the SwiftUI font never reached it. Added `makeFontFaceCSS()` which embeds the
  bundled `FiraCode-Regular.ttf` as a base64 `@font-face` (inlined because the webview's base URL is
  the `ghostty/` resource dir), plus a JS `ensureFontLoaded()` that force-loads the family before the
  canvas first draws. Falls back to system monospace if the font is absent.

**PostScript-name verification** (read from the actual TTFs — the usual real bug):

| File | nameID 6 (PostScript) | family | `Font.custom` string |
|---|---|---|---|
| FiraCode-Regular.ttf | `FiraCode-Regular` | Fira Code | `FiraCode-Regular` ✅ matches |
| FiraCode-Medium.ttf | `FiraCode-Medium` | Fira Code Medium | (not referenced by name) |
| FiraCode-Bold.ttf | `FiraCode-Bold` | Fira Code | (not referenced by name) |

**Verify on Mac**: build the device target; confirm the `FontParser`/`GSFont` errors are gone and
the terminal + theme/font-size preview sheets render in FiraCode (ligatures visible).
**Assumption to confirm**: the synchronized group flattens `Resources/Fonts/*.ttf` to the bundle root
so the bare-filename `UIAppFonts` entries and `Bundle.main.url(forResource:"FiraCode-Regular"…)`
resolve. If fonts still don't load after build, the subfolder was preserved as a directory — move the
TTFs to the bundle root (or confirm `Fonts` is a group, not a folder reference).

## 2. AppIcon — P2 (cosmetic)

**Console lines resolved**
```
No image named 'AppIcon' found in asset catalog  (×2)
```

**Root cause** — *not* a missing app icon. `Assets.xcassets/AppIcon.appiconset` exists with a valid
1024×1024 PNG and `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set, so the home-screen icon is
fine. The warning comes from **code** loading the app-icon set as a named image, which an
`*.appiconset` does not expose at runtime: `Image("AppIcon")` in `WelcomeView` (×2 — glow + main
layers, matching the "×2") and `SettingsView` (×1). Those in-app logos were also rendering blank.

**Fix**
- Added a normal image set `Assets.xcassets/AppIconImage.imageset` (universal, reusing the 1024 PNG).
- Repointed the three references: `Image("AppIcon")` → `Image("AppIconImage")` in
  `ios/VibeTunnel/Views/Welcome/WelcomeView.swift` (2) and
  `ios/VibeTunnel/Views/Settings/SettingsView.swift` (1).

**Verify on Mac**: warning gone; the Welcome and Settings screens now show the app logo.
**Note**: the existing `AppIcon.png` is RGBA (has alpha). Irrelevant for personal/dev installs
(only App Store submission rejects alpha). Does not affect the runtime warning above.

## 3. Keyboard input-accessory constraint conflict — P2

**Console lines resolved**
```
Unable to simultaneously satisfy constraints.
  …<NSLayoutConstraint> accessoryView.bottom == _UIKBCompatInputView.top
  …<NSLayoutConstraint> V:|-(17)-[inputView]
  …<NSLayoutConstraint> TUIKeyboardContentView.height == 224
```

**Root cause** — VibeTunnel does not author any of these constraints. They are iOS-internal keyboard
layout constraints. They fire because the `WKWebView` exposes WebKit's **default system
input-accessory bar** (the QuickType/format bar) when the web `textarea` is focused; when the keyboard
animates, UIKit's `_UIKBCompatInputView` / `TUIKeyboardContentView` constraints momentarily conflict
and iOS breaks one to recover. The bar is redundant — the terminal already shows its own SwiftUI
`TerminalToolbar` (`TerminalView.terminalContent`, gated on `keyboardHeight > 0`).

**Fix** — `ios/VibeTunnel/Views/Terminal/GhosttyWebView.swift`: added
`WKWebView.vt_suppressInputAccessoryView()`, called from `webView(_:didFinish:)`. WebKit exposes no
public API to nil-out the bar (the first responder is the private `WKContentView`, not the
`WKWebView`), so it retargets the content view to a generated subclass whose `inputAccessoryView`
returns nil. Idempotent.

**Verify on Mac**: focus the terminal on device; the grey system bar above the keyboard should be
gone and the `Unable to simultaneously satisfy constraints` spam should stop. This is the one fix
most worth eyeballing on-device — it uses the ObjC runtime, which needs a real build to validate.

---

## Triaged benign — confirmed noise, intentionally NOT "fixed"

| Console line | Verdict |
|---|---|
| `Tailscale credentials not configured` | App's Tailscale integration is simply unconfigured on this device. Expected. |
| `AX Lookup … Permission denied` | Accessibility server probe on a dev device. System noise, not app. |
| `LaunchServices … process may not map database` | Sandbox/LaunchServices noise for dev-signed apps. Harmless. |
| RBS `Client not entitled` | Entitlement noise for a dev/ad-hoc signed build; clears with a proper provisioning profile. |
| `com.wispr.flowapp` RBS error | Wispr Flow keyboard (third-party), unrelated to VibeTunnel. |

Chasing any of these would waste effort and risk regressions; left as-is by design.

---

## Files touched

| File | Concern |
|---|---|
| `ios/VibeTunnel/Resources/Fonts/{FiraCode-Regular,Medium,Bold}.ttf`, `OFL.txt` | fonts (new) |
| `ios/VibeTunnel/Utils/Theme.swift` | fonts |
| `ios/VibeTunnel/Views/Terminal/GhosttyWebView.swift` | fonts (webview) + keyboard |
| `ios/VibeTunnel/Resources/Assets.xcassets/AppIconImage.imageset/*` | app icon (new) |
| `ios/VibeTunnel/Views/Welcome/WelcomeView.swift` | app icon |
| `ios/VibeTunnel/Views/Settings/SettingsView.swift` | app icon |
