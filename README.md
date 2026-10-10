# TinyTimer — menu bar time tracker

Hourglass icon + `D 01:42:17` (initial of the current activity) in the macOS status bar. Activities: Development, Investigation, Meeting.
Starting an activity stops the previous one. Every interval is a row in SQLite
(`~/Library/Application Support/TinyTimer/tinytimer.sqlite`, table `entries(id, activity, start, end)`).

- **⌥⌘T** — quick switch popup (↑↓, Enter, 1–3, Esc)
- **Today** — window with History / Statistics tabs and day navigation
- **Export CSV** — `date,activity,duration` (one row per day per activity, `HH:MM:SS`)
- Sleep stops the running entry; it resumes on wake if the sleep was shorter than 15 min.

## Build

Works with Command Line Tools only (no Xcode):

```sh
./bundle.sh --open            # build/TinyTimer.app
./bundle.sh --install --open  # copy to /Applications (needed for Launch at login)
swift run --build-system native TinyTimer --selftest
swift run --build-system native TinyTimer --snapshot /tmp   # render SwiftUI screens to PNG
```

SwiftUI's `@State` macro plugin is not shipped with Command Line Tools, so views keep state
in `ObservableObject` models instead.
