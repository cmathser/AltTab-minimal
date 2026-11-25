# OptionTab

This is a minimal macOS window switcher derived from the [AltTab](https://github.com/lwouis/alt-tab-macos) project history. It keeps one shortcut: hold Option and press Tab to cycle through windows, then release Option to focus the selected window. Shift-Tab moves backward; Escape cancels. The switcher lists window titles and app icons, including windows of the same app. It has no settings, trial, licensing, update service, analytics, or window thumbnails.

## Build & Test

On macOS with the Swift command-line tools installed:

```sh
./build.sh
./test.sh
```

The build result is `build/OptionTab.app`. Set `CODE_SIGN_IDENTITY` to a local Apple Development signing identity if you want macOS to preserve Accessibility permission across rebuilds; otherwise the build uses an ad hoc signature. The app has a distinct bundle identifier (`local.optiontab.minimal`), so it cannot reuse AltTab's macOS Accessibility permission.

## Run

Applications are ordered by their most recent confirmed system activation, including mouse clicks and Command-Tab. The first pass shows one entry per app instance and brings that app's windows forward together (restoring a minimized window automatically if all windows of that app are minimized). Additional windows follow at the end and can be selected directly; these entries show both the app and window title and focus only that selected window. Multiple regular instances of the same app (`open -n`) and nested Dock sub-apps (such as `WeChatAppEx`) remain distinct, with duplicate display names automatically disambiguated by window title. Running Dock apps are included even without accessible windows. The list stays fixed while Option is held and refreshes on the next invocation. At startup, visible window stacking order provides the initial order; macOS does not expose the Dock switcher's complete earlier activation history through these APIs.

Quit AltTab before running OptionTab because both use Option-Tab. Open `build/OptionTab.app`, grant Accessibility in System Settings if asked, then open it again. OptionTab needs Accessibility to read and focus windows. It does not ask for Screen Recording because it shows titles and icons rather than screenshots. To stop it, quit the `OptionTab` process in Activity Monitor.

The app uses public AppKit, Core Graphics, and Accessibility APIs. Some apps' protected or unusual windows may not be listed or focused. For startup at login, move or copy `build/OptionTab.app` to `/Applications/OptionTab.app`, grant Accessibility, then copy `LaunchAgent.plist` to `~/Library/LaunchAgents/local.optiontab.minimal.plist` and load it with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.optiontab.minimal.plist`.

This project was derived from [AltTab](https://github.com/lwouis/alt-tab-macos) version 11.10.1 (`c500294`). The upstream source is licensed under GPL-3.0; see [LICENCE.md](LICENCE.md).
