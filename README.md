# Molten

Typora-style **single-pane WYSIWYG Markdown editor** for macOS — markdown syntax melts into rendered typography as you type. Sibling project of [MarkMac](https://github.com/A18on/MarkMac) (two-pane source editor); Molten is the melt-as-you-type counterpart.

## Architecture

- **Native shell (Swift/AppKit)** — `NSDocument` owns the file: open/save/autosave, sandbox, dirty state. No storyboards.
- **Editing surface (WKWebView)** — [Milkdown Crepe](https://milkdown.dev) (ProseMirror) bundled fully offline via esbuild into `Resources/dist`. The editor owns the session: melting render, in-editor undo.
- **Bridge** — JS reports serialized markdown (debounced) via `webkit.messageHandlers.molten`; Swift injects content via `window.moltenAPI`. Explicit saves pull the live serialization first so Cmd+S never writes stale content.

Files on disk are always plain `.md` (UTF-8, normalized markdown — Typora-style).

## Build

```bash
./scripts/build-editor.sh   # bundle the JS editing surface (needs node ≥ 20)
xcodegen generate
xcodebuild -project Molten.xcodeproj -scheme Molten -configuration Debug -destination 'platform=macOS' build
```

Tests: same command with `test`.

## Status

MVP scaffold: melt editing (headings/bold/lists/quotes/code/tables/KaTeX via Crepe), open/save/autosave. Roadmap in `docs/PLAN.md`.

## License

MIT
