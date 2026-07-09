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

Tests: same command with `test`. The resource-heavy card-renderer E2E test is
opt-in: `TEST_RUNNER_MOLTEN_E2E=1 xcodebuild … -only-testing:MoltenTests/MoltenImageCardRenderTests test`.

Release build (ad-hoc signed DMG + zip into `dist/`): `./scripts/release.sh`.

## Features

- **Melt editing** — headings, bold/italic, lists, quotes, code, tables, KaTeX fuse into typography as you type (Crepe/ProseMirror)
- **Files stay honest** — plain UTF-8 `.md` on disk; strict encoding (no lossy guessing); 20 MB guard; external changes auto-reload clean documents
- **Workspace** — outline sidebar (⌥⌘1, click/arrow-key navigation), find & replace (⌘F, transaction-level replace-all with single-step undo), mixed CJK/latin word count status bar
- **Images** — paste/drop saves into `assets/` next to the document (one-time folder permission), displayed in-editor via a sandboxed asset scheme
- **Export** — self-contained HTML (⇧⌘E), PDF, print, and **image cards**: themed, paginated share-images (PNG/JPEG, watermark, folder/ZIP output)
- **Bilingual** — English and 简体中文 throughout

Roadmap in `docs/PLAN.md`.

## License

MIT
