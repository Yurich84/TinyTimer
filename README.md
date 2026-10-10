# TinyTimer — menu bar time tracker

Hourglass icon + `D 42:17` / `D 1:42:17` (initial of the current activity; hours hidden while 0) in the macOS status bar. Activities: Development, Investigation, Meeting.
Starting an activity stops the previous one. Every interval is a row in SQLite
(`~/Library/Application Support/TinyTimer/tinytimer.sqlite`, table `entries(id, activity, start, end)`).

- **Left click** — stop the running activity, or start the default one (Settings → Default activity)
- **Right click** (or ⌃-click) — menu
- **⌥⌘T** — quick switch popup (↑↓, Enter, 1–3, Esc)
- **Today** — window with History / Statistics tabs and day navigation. In History: double-click or
  right-click a row to edit or delete it, **Add…** for a manual entry. Overlapping entries are rejected.
- **Export CSV** — format chosen in the save panel (`HH:MM:SS` or decimal hours):
  one row per day (`date,<activity…>,total`), one row per day per activity (`date,activity,duration`),
  or one row per entry (`date,activity,start,end,duration`)
- **Settings → Timer shows** — time since the last switch, or today's total for the current activity
- Sleep stops the running entry; it resumes on wake if the sleep was shorter than 15 min.

## Build

Works with Command Line Tools only (no Xcode):

```sh
./bundle.sh --open            # build/TinyTimer.app
./bundle.sh --install --open  # copy to /Applications (needed for Launch at login)
swift run --build-system native TinyTimer --selftest
swift run --build-system native TinyTimer --snapshot /tmp   # render SwiftUI screens to PNG
```

With Xcode (needs [XcodeGen](https://github.com/yonaskolb/XcodeGen); the project is generated from `project.yml`):

```sh
./xcode-export.sh                   # archive + export -> build/export/TinyTimer.app
./xcode-export.sh --install --open
xcodegen generate && open TinyTimer.xcodeproj
```

SwiftUI's `@State` macro plugin is not shipped with Command Line Tools, so views keep state
in `ObservableObject` models instead.
