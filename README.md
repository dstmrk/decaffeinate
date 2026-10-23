# Decaffeinate

A tiny macOS menu bar app that keeps a MacBook awake with the lid closed, so long-running jobs (AI coding agents, builds) keep working on a fraction of the power.

Decaffeinate is a fork of [Pilot Light](https://github.com/CyrisXD/pilot-light) by [sudolabs](https://pilotlight.sudolabs.nz). The design, the measurements below and nearly all of the code are theirs. This fork has its own minimal page ([decaffeinate-app.pages.dev](https://decaffeinate-app.pages.dev), source in [`site/`](site)), and its update check looks for this fork's releases.

## What it does

When the lid closes while you're logged in, Decaffeinate:

- keeps the Mac awake (power assertions like `caffeinate` can't survive a lid close; this uses the system sleep setting that can),
- switches to Low Power Mode, then restores your exact battery and charger settings when the lid opens,
- turns the display off,
- lets the Mac sleep anyway on serious heat or when the battery drops below your limit.

It keeps working behind the lock screen. Log out or switch users, and closing the lid sleeps the Mac as normal. Turn off **Keep awake when screen locked** and it also sleeps once the screen locks. With an external display connected, a closed lid is treated as a normal desk setup and left alone. The menu shows your Mac's own measured power draw with the lid open and closed.

It makes no network requests unless you ask for an update check: **Check for updates…** checks once, **Check for updates daily** (off by default) checks once a day. Each is one anonymous request for this repository's latest GitHub release; nothing about your Mac is sent. A newer version appears at the top of the menu and opens the release page; Decaffeinate never downloads or installs anything by itself.

| | Measured upstream¹ |
|---|---|
| Lid open | 16.7 W · ~6 h battery |
| Lid closed, app on | 4.8 W · 20+ h battery |
| App memory | ~25 MB |
| App CPU while waiting | ~0% |

¹ Pilot Light's figures: MacBook Pro with M5 Max (macOS 26.6), on battery. With Claude Code building and testing a website, lid closed: 2.3 W. Heavy local builds draw more, and battery hours are estimates.

## Install

Download `Decaffeinate-<version>.dmg` from the [latest release](https://github.com/dstmrk/decaffeinate/releases/latest) and drag the app to Applications.

### Opening Decaffeinate for the first time

macOS will block Decaffeinate the first time, saying *"Apple cannot check it for malicious software"*. This is expected: Decaffeinate is free and open source, and isn't signed with a paid Apple developer account (it is ad-hoc signed, not notarized). It's safe to open:

1. Double-click Decaffeinate. When macOS blocks it, click **Done** (not *Move to Bin*).
2. Open **System Settings › Privacy & Security** and scroll down to the **Security** section.
3. Click **Open Anyway** next to "Decaffeinate was blocked", then enter your password.
4. You only need to do this once.

If you prefer the Terminal: `xattr -dr com.apple.quarantine /Applications/Decaffeinate.app`.

## Build from source

```bash
git clone https://github.com/dstmrk/decaffeinate
cd decaffeinate
./build.sh
open ~/Applications/Decaffeinate.app
```

Needs the Xcode command line tools. Builds a universal app (Apple silicon and Intel) for macOS 13 and later, ad-hoc signed. The whole app is in [`Sources/`](Sources), one file per domain; `Sources/Selftest.swift` holds the self-test.

## First launch

1. On first launch, click **Continue…**. The admin prompt that follows adds a sudoers rule that allows only `pmset` sleep and Low Power changes. Decaffeinate can't work without it, so declining quits the app.
2. Close the lid.

While the app is on, the Mac also won't idle-sleep with the lid open (the display still turns off).

If the app crashes or is force-quit, a small background check (installed with the helper) turns lid-close sleep back on within a minute, and puts back your Low Power Mode settings.
If macOS has that check switched off (System Settings › General › Login Items), Decaffeinate warns at launch and adds **Crash protection is off, fix…** to the menu.

If you previously installed Pilot Light, remove its helper first (**Remove helper…** in its menu, or `sudo rm /etc/sudoers.d/pilotlight`): the two apps use separate helpers and would fight over the same `pmset` setting.

## Uninstall

Choose **Uninstall…** from the menu. Decaffeinate turns lid-close sleep back on, removes the helper, the background check, the login item and its settings, moves itself to the Bin and quits. Dragging the app to the Bin instead leaves the helper behind; remove it by hand with `sudo pmset -a disablesleep 0 && sudo rm /etc/sudoers.d/decaffeinate`. Turn sleep back on first: once the rule is gone, neither the app nor the watchdog can.

## Development

- `Decaffeinate --selftest` (the binary inside the app bundle) checks the core logic; CI runs it on a macOS runner with the universal build on every pull request that touches the app.
- Releases: `git tag v1.0.0 && git push origin v1.0.0`, or publish a release with a new `v1.0.0` tag on GitHub. CI runs every check, then attaches `Decaffeinate-1.0.0.dmg` to the release, creating it if the tag came from git.
- `./measure.sh closed-batt 10` logs whole-Mac power from battery telemetry, to reproduce the numbers above.
- The app icon is `assets/AppIcon.svg`; `build.sh` renders it into the bundle's `.icns` on every build. The release `.dmg` window (icons, arrow, volume icon) is laid out by `assets/dmg-settings.py` with [dmgbuild](https://github.com/dmgbuild/dmgbuild) in CI.

## Credits and license

MIT. Original work © 2026 sudolabs ([Pilot Light](https://github.com/CyrisXD/pilot-light)); see [LICENSE](LICENSE), which the app bundle also carries in `Contents/Resources/`. The cup icon is [Lucide](https://lucide.dev)'s "coffee" (ISC). If the app is useful to you, consider [sponsoring the original author](https://github.com/sponsors/CyrisXD).
