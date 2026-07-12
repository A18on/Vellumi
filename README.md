# Vellumi

Typora-style **single-pane WYSIWYG Markdown editor** for macOS — markdown syntax melts into rendered typography as you type. Sibling project of [MarkMac](https://github.com/A18on/MarkMac) (two-pane source editor); Vellumi is the melt-as-you-type counterpart.

## Architecture

- **Native shell (Swift/AppKit)** — `NSDocument` owns the file: open/save/autosave, sandbox, dirty state. No storyboards.
- **Editing surface (WKWebView)** — [Milkdown Crepe](https://milkdown.dev) (ProseMirror) bundled fully offline via esbuild into `Resources/dist`. The editor owns the session: melting render, in-editor undo.
- **Bridge** — JS reports serialized markdown (debounced) via `webkit.messageHandlers.molten`; Swift injects content via `window.moltenAPI`. Explicit saves pull the live serialization first so Cmd+S never writes stale content.

Files on disk are always plain `.md` (UTF-8, normalized markdown — Typora-style).

## Build

```bash
./scripts/build-editor.sh   # bundle the JS editing surface (needs node ≥ 20)
xcodegen generate
xcodebuild -project Vellumi.xcodeproj -scheme Vellumi -configuration Debug -destination 'platform=macOS' build
```

Tests: same command with `test` (the card-renderer E2E runs in the default
suite; its web views live in an offscreen window so `requestAnimationFrame`
fires headlessly).

Release build (ad-hoc signed DMG + zip into `dist/`): `./scripts/release.sh`.

## Features

- **Melt editing** — headings, bold/italic, lists, quotes, code, tables, KaTeX fuse into typography as you type (Crepe/ProseMirror); slash menu and floating format toolbar included
- **Keyboard-first** — ⌘0–6 headings, ⌘B/I/E, ⌘K link, ⌘⇧X/U/O/Q, ⌥⌘- and more via the Format menu
- **Source mode** — ⌘/ flips to a plain-markdown view of the full file (front matter included) and back
- **Typewriter & focus modes** — caret line stays anchored; non-active blocks dim (View menu / Settings)
- **Mermaid** — ```mermaid fences render as live diagrams, following light/dark
- **Quick Open** — ⇧⌘P fuzzy filename search across all tracked projects
- **Native window tabs** — documents open as tabs; merge/split from the Window menu
- **Settings** — ⌘, panel: appearance, theme, editor zoom (⌘+/⌘-), spellcheck, word-count goal, drafts folder
- **Files stay honest** — plain UTF-8 `.md` on disk; strict encoding (no lossy guessing); 20 MB guard; external changes auto-reload clean documents
- **Workspace** — outline sidebar (⌥⌘1, click/arrow-key navigation), find & replace (⌘F, transaction-level replace-all with single-step undo), mixed CJK/latin word count status bar
- **Images** — paste/drop saves into `assets/` next to the document (one-time folder permission), displayed in-editor via a sandboxed asset scheme
- **Export** — self-contained HTML (⇧⌘E), PDF, print, and **image cards**: themed, paginated share-images (PNG/JPEG, watermark, folder/ZIP output)
- **Themes** — Frame / Nord / Classic editor themes (View ▸ Theme), plus a System/Light/Dark appearance override; front matter is protected byte-for-byte and editable via File ▸ Edit Front Matter
- **Projects** — ⇧⌘0 launcher: track folders, browse/rename files, full-text search across projects, per-project New Note, optional Drafts folder for File ▸ New
- **Bilingual** — English and 简体中文 throughout, including the editor's slash menu

Roadmap in `docs/PLAN.md`.

## License

MIT
