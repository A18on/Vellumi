// Molten editing surface.
//
// A Milkdown Crepe editor (ProseMirror under the hood) fills the window and
// gives the Typora-style "melting" feel: markdown syntax fuses into rendered
// typography as you type. The native Swift shell owns the file; this side owns
// the editing session and reports serialized markdown back over the bridge.
//
// Bridge contract (keep in sync with MoltenEditorViewController.swift):
//   JS → Swift  window.webkit.messageHandlers.molten.postMessage(…)
//     {type: "ready"}                       surface booted, safe to setMarkdown
//     {type: "change", markdown: String}    debounced content update
//     {type: "boot-error", message: String} editor failed to construct
//     {type: "image-save", id, name, base64} pasted/dropped image payload;
//                       Swift answers via moltenAPI.resolveImageSave(id, path)
//   Swift → JS  window.moltenAPI.*
//     setMarkdown(md)   load document content (builds/rebuilds the editor)
//     getMarkdown()     current serialization, or null while no editor is
//                       live (booting/rebuilding) — callers must treat null
//                       as "keep what you already have", never as empty
//     undo()/redo()     forward native menu actions to ProseMirror history
//     focus()           re-assert DOM focus once the host window is key
//     getOutline()      [{level, text, pos}] for the native outline sidebar
//     scrollToHeading(pos)  move caret to a heading and scroll it into view
//     find(term, backwards) incremental in-page search; returns whether found
//     replaceNext/replaceAll(term, replacement)  find-bar replacement
//     getContentHTML()  cleaned rendered HTML for export (null before boot)
//
// The editor is constructed lazily on the first setMarkdown — building a
// throwaway empty editor at boot would double every document-open.

import { Crepe } from "@milkdown/crepe";
import { editorViewCtx } from "@milkdown/core";
import mermaid from "mermaid";
import { undoCommand, redoCommand } from "@milkdown/plugin-history";
import {
  insertHrCommand,
  toggleLinkCommand,
  toggleEmphasisCommand,
  toggleInlineCodeCommand,
  toggleStrongCommand,
  turnIntoTextCommand,
  wrapInBlockquoteCommand,
  wrapInBulletListCommand,
  wrapInHeadingCommand,
  wrapInOrderedListCommand,
} from "@milkdown/preset-commonmark";
import { toggleStrikethroughCommand, columnResizingPlugin } from "@milkdown/preset-gfm";
import { diagram, diagramSchema } from "@milkdown/plugin-diagram";
import { TextSelection } from "@milkdown/prose/state";
import { InputRule, inputRules, smartQuotes, ellipsis, emDash } from "@milkdown/prose/inputrules";
import { callCommand, $prose, $view } from "@milkdown/utils";
import { languages as codeLanguages } from "@codemirror/language-data";
import { gemoji } from "gemoji";
import "@milkdown/crepe/theme/common/style.css";
// Frame theme ships as separate light/dark files (each redefines the same
// variables), so they are built as standalone stylesheets and index.html
// swaps them via prefers-color-scheme media queries.

// Trailing debounce for change messages, with a max-latency bound: a fluent
// typist never pausing 150ms must still flush at least once per second, or
// Swift's copy (autosave, crash recovery) goes unboundedly stale.
// ---- Editor-surface localization -----------------------------------------
// Crepe's built-in strings (slash menu, placeholders, image upload buttons)
// are English; mirror the app's zh-Hans localization when the SYSTEM language
// is Chinese (navigator.language follows the host system in WKWebView).
const appLanguage = typeof window.__vellumiLanguage === "string" ? window.__vellumiLanguage : "";
const isChinese = /^zh\b/i.test(appLanguage || navigator.language || "");

const zhBlockEdit = {
  textGroup: {
    label: "文本",
    text: { label: "正文" },
    h1: { label: "标题 1" },
    h2: { label: "标题 2" },
    h3: { label: "标题 3" },
    h4: { label: "标题 4" },
    h5: { label: "标题 5" },
    h6: { label: "标题 6" },
    quote: { label: "引用" },
    divider: { label: "分隔线" },
  },
  listGroup: {
    label: "列表",
    bulletList: { label: "无序列表" },
    orderedList: { label: "有序列表" },
    taskList: { label: "待办列表" },
  },
  advancedGroup: {
    label: "高级",
    image: { label: "图片" },
    codeBlock: { label: "代码块" },
    table: { label: "表格" },
    math: { label: "数学公式" },
  },
};

const zhImageBlock = {
  inlineUploadButton: "上传",
  inlineUploadPlaceholderText: "或粘贴图片链接…",
  inlineConfirmButton: "确认",
  blockUploadButton: "上传图片",
  blockUploadPlaceholderText: "或粘贴图片链接…",
  blockConfirmButton: "确认",
  blockCaptionPlaceholderText: "图片说明",
};

function localizedFeatureConfigs() {
  if (!isChinese) return {};
  return {
    [Crepe.Feature.BlockEdit]: zhBlockEdit,
    [Crepe.Feature.Placeholder]: { text: "输入正文,或按 / 唤起命令…" },
  };
}
// ---------------------------------------------------------------------------

// ---- Mermaid rendering -----------------------------------------------------
// plugin-diagram (7.7) supplies the schema/remark mapping for ```mermaid
// fences, but its NodeView predates Crepe 7.21 and never installs — so we
// provide our own: a plain ProseMirror nodeView that renders the source
// through mermaid and falls back to raw text when the graph doesn't parse.
// Editing the source happens in source mode (⌘/); the node itself is atomic.
const liveMermaidViews = new Set();
let mermaidSeq = 0;

function mermaidTheme() {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default";
}

mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: mermaidTheme() });

window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: mermaidTheme() });
  liveMermaidViews.forEach((entry) => entry.render(entry.code));
});

function mermaidNodeView(node) {
  const dom = document.createElement("div");
  dom.className = "vellumi-mermaid";
  dom.setAttribute("contenteditable", "false");
  const entry = {
    code: "",
    render(code) {
      entry.code = code;
      if (!code.trim()) {
        dom.textContent = "";
        return;
      }
      const id = `vellumi-mermaid-${++mermaidSeq}`;
      mermaid
        .render(id, code)
        .then(({ svg }) => {
          if (entry.code === code) dom.innerHTML = svg;
        })
        .catch(() => {
          // Invalid graph source: show it verbatim (mermaid may leave a
          // scratch element behind on failure — remove it).
          document.getElementById(`d${id}`)?.remove();
          if (entry.code === code) dom.textContent = code;
        });
    },
  };
  liveMermaidViews.add(entry);
  entry.render(node.attrs.value ?? node.textContent ?? "");
  return {
    dom,
    update(updated) {
      if (updated.type.name !== "diagram") return false;
      entry.render(updated.attrs.value ?? updated.textContent ?? "");
      return true;
    },
    ignoreMutation: () => true,
    destroy() {
      liveMermaidViews.delete(entry);
    },
  };
}
// -----------------------------------------------------------------------------

// ---- Smart punctuation & emoji completion ----------------------------------
// Smart punctuation (curly quotes, …, —) uses the stock ProseMirror rules;
// it is baked in at editor construction, so toggling rebuilds the editor
// (rare event, acceptable history reset). Emoji :name: completion is always
// on — it only fires on the exact :shortcode: form.
let smartPunctuationEnabled = false;

const emojiByName = new Map();
for (const entry of gemoji) {
  for (const name of entry.names) emojiByName.set(name, entry.emoji);
}

const emojiRule = new InputRule(/:([a-zA-Z0-9_+-]+):$/, (state, match, start, end) => {
  const emoji = emojiByName.get(match[1]);
  return emoji ? state.tr.insertText(emoji, start, end) : null;
});

function inputRulesPlugin() {
  const rules = [emojiRule];
  if (smartPunctuationEnabled) {
    rules.push(...smartQuotes, ellipsis, emDash);
  }
  return $prose(() => inputRules({ rules }));
}
// -----------------------------------------------------------------------------

// ---- View modes -----------------------------------------------------------
// Typewriter: keep the caret line vertically anchored (~45% of the viewport)
// while typing/navigating. Focus: dim every top-level block except the one
// holding the caret. Both are driven off selectionchange — it fires for
// typing AND caret movement, which is exactly the trigger set we want.
let typewriterEnabled = false;
let focusModeEnabled = false;
let spellcheckEnabled = false;

function editingSurface() {
  return root.querySelector(".ProseMirror");
}

function caretTopBlock() {
  const surface = editingSurface();
  const selection = document.getSelection();
  let node = selection?.anchorNode;
  if (!surface || !node || !surface.contains(node)) return null;
  while (node.parentNode && node.parentNode !== surface) node = node.parentNode;
  return node instanceof Element ? node : null;
}

function updateViewModes() {
  if (focusModeEnabled) {
    const active = caretTopBlock();
    editingSurface()
      ?.querySelectorAll(":scope > .vellumi-focus-active")
      .forEach((el) => {
        if (el !== active) el.classList.remove("vellumi-focus-active");
      });
    active?.classList.add("vellumi-focus-active");
  }
  if (typewriterEnabled) {
    const selection = document.getSelection();
    if (!selection?.rangeCount) return;
    const range = selection.getRangeAt(0).cloneRange();
    range.collapse(false);
    let rect = range.getBoundingClientRect();
    if (!rect || (rect.height === 0 && rect.top === 0)) {
      const container = range.startContainer;
      const el = container instanceof Element ? container : container.parentElement;
      rect = el?.getBoundingClientRect();
    }
    if (!rect) return;
    const delta = rect.top - window.innerHeight * 0.45;
    // Dead zone: without it every keystroke micro-scrolls by sub-pixel
    // amounts and the page shimmers.
    if (Math.abs(delta) > 4) {
      window.scrollBy({ top: delta, behavior: "auto" });
    }
  }
}

document.addEventListener("selectionchange", () => {
  if (isComposing) return; // never scroll under the IME candidate window
  if (typewriterEnabled || focusModeEnabled) {
    requestAnimationFrame(updateViewModes);
  }
});

function applySpellcheck() {
  editingSurface()?.setAttribute("spellcheck", spellcheckEnabled ? "true" : "false");
}
// ---------------------------------------------------------------------------

// ---- IME composition guard --------------------------------------------------
// During pinyin (etc.) composition the DOM holds transient candidate text.
// Serializing then costs main-thread time in the IME's critical path AND can
// capture half-composed garbage; typewriter scrolling mid-composition makes
// the candidate window chase the caret. Both wait for compositionend.
let isComposing = false;
document.addEventListener("compositionstart", () => {
  isComposing = true;
});
document.addEventListener("compositionend", () => {
  isComposing = false;
  scheduleChange();
});
// -----------------------------------------------------------------------------

const CHANGE_DEBOUNCE_MS = 150;
const CHANGE_MAX_LATENCY_MS = 1000;
// Adaptive throttle: large documents serialize slowly; measuring the actual
// cost and scaling the debounce keeps typing latency flat instead of paying
// a fixed 150ms cadence on a 10k-line file.
let changeDebounceMS = CHANGE_DEBOUNCE_MS;
let changeMaxLatencyMS = CHANGE_MAX_LATENCY_MS;

const root = document.getElementById("editor");
let crepe = null;
let changeTimer = null;
let oldestPendingChangeAt = null;
let lastSentMarkdown = null;
// Guards the async rebuild in setMarkdown: a stale create() must not clobber
// a newer document load.
let loadGeneration = 0;
// Scroll restore across editor rebuilds (source-mode round trip): applied
// after the next createEditor completes, or immediately when idle.
let pendingScrollFraction = null;

function applyPendingScroll() {
  if (pendingScrollFraction === null) return;
  const fraction = pendingScrollFraction;
  pendingScrollFraction = null;
  requestAnimationFrame(() => {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    window.scrollTo({ top: fraction * Math.max(0, max), behavior: "auto" });
  });
}

function post(message) {
  try {
    window.webkit?.messageHandlers?.molten?.postMessage(message);
  } catch {
    // Running outside the shell (e.g. opened in a browser for debugging).
  }
}

// Serialization happens HERE, once per flush — not per keystroke. The editor
// listener only marks dirty; a large document is stringified when the timer
// fires, not on every transaction.
function flushChange() {
  clearTimeout(changeTimer);
  changeTimer = null;
  if (isComposing) {
    // Never serialize mid-composition; compositionend reschedules.
    changeTimer = setTimeout(flushChange, changeDebounceMS);
    return;
  }
  oldestPendingChangeAt = null;
  if (!crepe) return;
  const before = performance.now();
  const markdown = crepe.getMarkdown();
  const cost = performance.now() - before;
  // 10x the serialize cost, floored at the base cadence: a 1ms doc keeps the
  // snappy 150ms; a 60ms doc backs off to 600ms and stops eating keystrokes.
  changeDebounceMS = Math.min(2000, Math.max(CHANGE_DEBOUNCE_MS, cost * 10));
  changeMaxLatencyMS = Math.min(3000, Math.max(CHANGE_MAX_LATENCY_MS, cost * 40));
  if (markdown !== lastSentMarkdown) {
    lastSentMarkdown = markdown;
    post({ type: "change", markdown });
  }
}

function scheduleChange() {
  const now = Date.now();
  oldestPendingChangeAt ??= now;
  if (now - oldestPendingChangeAt >= changeMaxLatencyMS) {
    flushChange();
    return;
  }
  clearTimeout(changeTimer);
  changeTimer = setTimeout(flushChange, changeDebounceMS);
}

// ---- Image save pipeline -------------------------------------------------
// Pasted/dropped images go to Swift (which owns sandbox permissions and the
// document's folder) and come back as a document-relative path like
// "assets/pic.png". Display-time, relative srcs are rewritten to the
// molten-asset:// scheme served by the shell.

const IMAGE_SAVE_TIMEOUT_MS = 30_000;
const pendingImageSaves = new Map();
let imageSaveCounter = 0;

function arrayBufferToBase64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  const chunk = 0x8000; // keep String.fromCharCode argument counts sane
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

async function uploadImage(file) {
  const base64 = arrayBufferToBase64(await file.arrayBuffer());
  const id = ++imageSaveCounter;
  return new Promise((resolve, reject) => {
    pendingImageSaves.set(id, { resolve, reject });
    post({ type: "image-save", id, name: file.name || "image.png", base64 });
    setTimeout(() => {
      if (pendingImageSaves.delete(id)) {
        reject(new Error("image save timed out"));
      }
    }, IMAGE_SAVE_TIMEOUT_MS);
  });
}

function rewriteAssetURL(url) {
  if (typeof url !== "string" || !url) return url;
  // Absolute/self-describing URLs pass through untouched.
  if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|\/)/i.test(url)) return url;
  return `molten-asset://asset/${encodeURI(url)}`;
}
// ---------------------------------------------------------------------------

async function createEditor(markdown) {
  const generation = ++loadGeneration;
  // A timer armed against the outgoing editor must not fire into the new one
  // with pre-load content (it would resurrect reverted-away edits).
  clearTimeout(changeTimer);
  changeTimer = null;
  oldestPendingChangeAt = null;

  if (crepe) {
    const old = crepe;
    crepe = null;
    try {
      await old.destroy();
    } catch {
      // A half-initialized editor may throw on teardown; the replaced DOM
      // subtree is cleared below either way.
    }
  }
  if (generation !== loadGeneration) return;
  root.replaceChildren();

  const next = new Crepe({
    root,
    defaultValue: markdown,
    featureConfigs: {
      ...localizedFeatureConfigs(),
      // Full CodeMirror language registry: real syntax highlighting plus a
      // useful searchable language picker (the default set is EMPTY).
      [Crepe.Feature.CodeMirror]: {
        languages: codeLanguages,
      },
      [Crepe.Feature.ImageBlock]: {
        onUpload: uploadImage,
        inlineOnUpload: uploadImage,
        blockOnUpload: uploadImage,
        proxyDomURL: rewriteAssetURL,
        ...(isChinese ? zhImageBlock : {}),
      },
    },
  });
  // Mermaid: plugin-diagram for schema/serialization, our nodeView for the
  // actual rendering (see mermaidNodeView above). Registered as a $view
  // plugin — NEVER via editorViewOptionsCtx.nodeViews, which REPLACES the
  // nodeViews milkdown gathers from components and silently disables the
  // code block / image block / list item / table UIs.
  next.editor.use(diagram);
  next.editor.use($view(diagramSchema.node, () => (node) => mermaidNodeView(node)));
  // Table column-width dragging (prosemirror-tables columnResizing). Exported
  // by preset-gfm but NOT in its composed plugin list — opt in explicitly.
  next.editor.use(columnResizingPlugin);
  next.editor.use(inputRulesPlugin());
  next.on((listener) => {
    // `updated` fires per transaction WITHOUT serializing; markdown is pulled
    // lazily in flushChange.
    listener.updated(() => {
      if (next === crepe) {
        scheduleChange();
      }
    });
  });
  await next.create();
  if (generation !== loadGeneration) {
    try {
      await next.destroy();
    } catch {}
    return;
  }
  crepe = next;
  // Baseline against the SERIALIZED form, not the raw input: the serializer
  // normalizes (list markers, blank lines), and that echo must not count as
  // an edit — otherwise every document opens already dirty.
  lastSentMarkdown = next.getMarkdown();
  // Typora-style normalization is a documented tradeoff — surface it so the
  // shell can show a one-time notice (source mode shows the original).
  // Carries the serialized text so the shell can adopt it as the clean
  // baseline: without it, the first pull always differed from what was read
  // off disk and silently dirtied (then rewrote) untouched files.
  post({ type: "normalized", changed: lastSentMarkdown !== markdown, markdown: lastSentMarkdown });
  applySpellcheck();
  focusEditor();
  applyPendingScroll();
}

function focusEditor() {
  // AppKit gives the WKWebView first-responder status, but typing only lands
  // once the contenteditable itself has DOM focus.
  requestAnimationFrame(() => {
    root.querySelector(".ProseMirror")?.focus();
  });
}

window.moltenAPI = {
  setMarkdown(markdown) {
    createEditor(typeof markdown === "string" ? markdown : "").catch((error) => {
      window.__moltenBootError = String(error?.stack ?? error);
      post({ type: "boot-error", message: String(error) });
    });
  },
  getMarkdown() {
    // No live editor (booting, or mid-rebuild between destroy and create):
    // return null so the shell keeps its current text. Returning "" here
    // once let a save during the window truncate the document to zero bytes.
    if (!crepe) return null;
    const markdown = crepe.getMarkdown();
    lastSentMarkdown = markdown;
    return markdown;
  },
  // Called when the hosting window becomes ready: the editor may finish
  // building BEFORE the window is key, in which case the DOM focus set at
  // construction time doesn't stick and typing goes nowhere.
  focus() {
    focusEditor();
  },
  // Theme selection: swap the light/dark stylesheet pair; prefers-color-scheme
  // still decides which of the two applies.
  setTheme(name) {
    const valid = ["frame", "nord", "classic"];
    const theme = valid.includes(name) ? name : "frame";
    // Swap-on-load: setting href directly unloads the old sheet before the
    // new one has parsed → one unstyled flash frame. Instead insert the new
    // link, let it load, then retire the old one.
    for (const mode of ["light", "dark"]) {
      const id = `theme-${mode}`;
      const old = document.getElementById(id);
      const href = `themes/${theme}-${mode}.css`;
      if (!old || old.getAttribute("href") === href) continue;
      const fresh = old.cloneNode(false);
      fresh.setAttribute("href", href);
      fresh.addEventListener("load", () => old.remove(), { once: true });
      // Safety: if load never fires (missing file), don't leave both active.
      setTimeout(() => old.remove(), 500);
      old.id = "";
      fresh.id = id;
      old.parentNode.insertBefore(fresh, old.nextSibling);
    }
  },
  // Native Edit ▸ Undo/Redo menu items forward here — WKWebView exposes no
  // responder-chain undo, and ProseMirror's history is the real stack.
  undo() {
    crepe?.editor.action(callCommand(undoCommand.key));
  },
  redo() {
    crepe?.editor.action(callCommand(redoCommand.key));
  },
  // Format menu commands (⌘1–6, ⌘0, ⌘B/I/E, ⌘⇧X, ⌘⇧U/O, ⌘⇧Q, ⌥⌘-).
  // Focus first: menu clicks move AppKit focus off the contenteditable, and a
  // ProseMirror command without a live selection silently no-ops.
  setHeading(level) {
    if (!crepe) return;
    focusEditor();
    const clamped = Math.max(0, Math.min(6, Number(level) || 0));
    if (clamped === 0) {
      crepe.editor.action(callCommand(turnIntoTextCommand.key));
    } else {
      crepe.editor.action(callCommand(wrapInHeadingCommand.key, clamped));
    }
  },
  toggleBold() {
    focusEditor();
    crepe?.editor.action(callCommand(toggleStrongCommand.key));
  },
  toggleItalic() {
    focusEditor();
    crepe?.editor.action(callCommand(toggleEmphasisCommand.key));
  },
  toggleInlineCode() {
    focusEditor();
    crepe?.editor.action(callCommand(toggleInlineCodeCommand.key));
  },
  toggleStrikethrough() {
    focusEditor();
    crepe?.editor.action(callCommand(toggleStrikethroughCommand.key));
  },
  toggleBlockquote() {
    focusEditor();
    crepe?.editor.action(callCommand(wrapInBlockquoteCommand.key));
  },
  toggleBulletList() {
    focusEditor();
    crepe?.editor.action(callCommand(wrapInBulletListCommand.key));
  },
  toggleOrderedList() {
    focusEditor();
    crepe?.editor.action(callCommand(wrapInOrderedListCommand.key));
  },
  insertHorizontalRule() {
    focusEditor();
    crepe?.editor.action(callCommand(insertHrCommand.key));
  },
  // ⌘K: wrap the selection in a link (empty href pops Crepe's link tooltip
  // for the URL); on an existing link it unwraps.
  toggleLink() {
    focusEditor();
    crepe?.editor.action(callCommand(toggleLinkCommand.key, { href: "" }));
  },
  // Headings for the native outline sidebar. Walking the ProseMirror tree is
  // cheap relative to serialization; positions are document offsets usable
  // with scrollToHeading below.
  getOutline() {
    if (!crepe) return [];
    const outline = [];
    crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      view.state.doc.descendants((node, pos) => {
        if (node.type.name === "heading") {
          outline.push({
            level: Number(node.attrs.level ?? 1),
            text: node.textContent,
            pos,
          });
        }
      });
    });
    return outline;
  },
  scrollToHeading(pos) {
    if (!crepe || typeof pos !== "number") return;
    crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const clamped = Math.max(0, Math.min(pos + 1, view.state.doc.content.size));
      const selection = TextSelection.near(view.state.doc.resolve(clamped));
      view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
      view.focus();
    });
  },
  // Native find bar drives WebKit's window.find (selection-based, wraps).
  find(term, backwards) {
    if (typeof term !== "string" || !term) return false;
    return window.find(term, false, Boolean(backwards), true, false, true, false);
  },
  // Case-insensitive occurrence count across text nodes, for the "3 处匹配"
  // label. Counting only (window.find owns navigation); cheap even on large
  // docs because it walks the same text the serializer would.
  countMatches(term) {
    if (!crepe || typeof term !== "string" || !term) return 0;
    let count = 0;
    const needle = term.toLowerCase();
    crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      view.state.doc.descendants((node) => {
        if (!node.isText) return;
        const text = (node.text ?? "").toLowerCase();
        let index = 0;
        while ((index = text.indexOf(needle, index)) !== -1) {
          count += 1;
          index += needle.length;
        }
      });
    });
    return count;
  },
  // Closing the find bar: drop the lingering match selection so no stale
  // highlight stays behind the caret.
  clearFindSelection() {
    const selection = window.getSelection();
    if (selection && !selection.isCollapsed) {
      selection.collapseToStart();
    }
  },
  // Clean document HTML for export: the rendered ProseMirror subtree with
  // editing chrome stripped and molten-asset:// srcs restored to the
  // document-relative paths the exported file should reference.
  getContentHTML() {
    const surface = root.querySelector(".ProseMirror");
    if (!crepe || !surface) return null;
    const clone = surface.cloneNode(true);
    clone.removeAttribute("contenteditable");
    clone.removeAttribute("translate");
    clone.querySelectorAll("[contenteditable]").forEach((el) => el.removeAttribute("contenteditable"));
    // Editing-only artifacts: widget decorations, drop cursors, placeholders.
    clone
      .querySelectorAll(".ProseMirror-widget, .milkdown-block-handle, .crepe-placeholder, [data-crepe-placeholder]")
      .forEach((el) => el.remove());
    // ---- Code blocks -------------------------------------------------------
    // Crepe renders code through a CodeMirror nodeView: the container is a Vue
    // app (`div.milkdown-code-block[data-v-app]`) with NO <pre> inside, so the
    // scaffolding sweep at the end used to delete every code block that had
    // been rendered. Rebuild each one as <pre><code>.
    // The text comes from the ProseMirror document, not the DOM: CodeMirror
    // virtualizes its lines, so a long block only has DOM for the lines that
    // scrolled through the viewport.
    const codeBlocks = [];
    crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      view.state.doc.descendants((node) => {
        if (node.type.name === "code_block" || node.type.spec.code) {
          codeBlocks.push({ language: node.attrs?.language ?? "", text: node.textContent });
          return false;
        }
        return true;
      });
    });
    Array.from(clone.querySelectorAll(".milkdown-code-block")).forEach((block, index) => {
      const source = codeBlocks[index];
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      const language = source?.language || block.getAttribute("data-language") || "";
      if (language) code.className = `language-${language}`;
      // Fall back to the rendered lines only if the document lookup missed.
      code.textContent =
        source?.text ??
        Array.from(block.querySelectorAll(".cm-line")).map((line) => line.textContent).join("\n");
      pre.appendChild(code);
      block.replaceWith(pre);
    });

    // ---- Tables ------------------------------------------------------------
    // The table block is a Vue app too; unwrap it to the bare <table> so the
    // column handles and drag affordances don't ship with the export.
    clone.querySelectorAll(".milkdown-table-block").forEach((block) => {
      // The block holds TWO <table> elements: an empty one inside
      // `.drag-preview` (the drag ghost, first in document order) and the real
      // one inside `.table-wrapper`. A bare querySelector("table") grabs the
      // decoy and throws the content away.
      // Discriminate on CONTENT, not position: `.drag-preview` sits inside
      // `.table-wrapper` and comes first in document order, so both a bare
      // querySelector("table") and a `.table-wrapper table` selector return
      // the empty ghost and discard every row.
      const table =
        Array.from(block.querySelectorAll("table")).find(
          (candidate) => candidate.querySelector("tr") && !candidate.closest(".drag-preview")
        ) ?? block.querySelector("table");
      if (table) block.replaceWith(table);
    });

    // ---- Lists -------------------------------------------------------------
    // Crepe wraps every list item in Vue scaffolding (icon svg, label wrapper,
    // children containers) that chokes downstream consumers — the card
    // paginator dies on it and exported HTML drags editor chrome along.
    // Restore standard <li> structure.
    // Deepest-first (reverse document order): replacing an outer <li> before
    // its nested items would freeze the scaffolding into the copied innerHTML.
    Array.from(clone.querySelectorAll("li.list-item")).reverse().forEach((item) => {
      const content = item.querySelector(".children .content-dom, .content-dom");
      const plain = document.createElement("li");
      if (content) {
        // A single wrapping <p> is markdown-normal inside <li>.
        plain.innerHTML = content.innerHTML;
      } else {
        plain.textContent = item.textContent; // never parse text as markup
      }
      // GFM task items: Crepe draws the checkbox as an inline SVG inside
      // `.label-wrapper .label`, carrying the state in a `checked`/`unchecked`
      // class — there is no <input> to find, which is why the state used to be
      // dropped entirely (and the wrapper deleted by the sweep below).
      const label = item.querySelector(".label-wrapper .label");
      if (label?.classList.contains("checked") || label?.classList.contains("unchecked")) {
        const box = document.createElement("input");
        box.type = "checkbox";
        box.disabled = true;
        if (label.classList.contains("checked")) box.setAttribute("checked", "");
        plain.insertBefore(box, plain.firstChild);
      }
      const wrapper = item.closest("div.milkdown-list-item-block") ?? item;
      wrapper.replaceWith(plain);
    });

    // ---- Images ------------------------------------------------------------
    // Image blocks are Vue components too — collapse each to a plain <img>
    // BEFORE the scaffolding sweep below would drop them. Containers that own
    // richer structure are skipped: an unqualified querySelector("img") used
    // to reach into a table cell and replace the ENTIRE table with that image.
    clone.querySelectorAll("[data-v-app]").forEach((component) => {
      if (component.querySelector("table, li, pre, .cm-editor")) return;
      const img = component.querySelector("img");
      if (img) {
        const plain = document.createElement("img");
        plain.setAttribute("src", img.getAttribute("src") ?? "");
        const alt = img.getAttribute("alt");
        if (alt) plain.setAttribute("alt", alt);
        component.replaceWith(plain);
      }
    });
    // Any remaining editor-only iconography/scaffolding without real content.
    clone.querySelectorAll(".label-wrapper, .milkdown-icon, [data-v-app]").forEach((el) => {
      if (el.querySelector("li, img, table, pre, blockquote")) return;
      el.remove();
    });
    clone.querySelectorAll("br.ProseMirror-trailingBreak").forEach((el) => el.remove());
    clone.querySelectorAll("img[src^='molten-asset://asset/']").forEach((img) => {
      const raw = img.getAttribute("src").slice("molten-asset://asset/".length);
      img.setAttribute("src", decodeURI(raw));
    });
    return clone.innerHTML;
  },
  // Replaces every occurrence of `term` (within single text nodes — matches
  // spanning formatting boundaries are out of scope) in one undoable
  // transaction. Returns the replacement count.
  replaceAll(term, replacement) {
    if (!crepe || typeof term !== "string" || !term) return 0;
    const safeReplacement = typeof replacement === "string" ? replacement : "";
    let count = 0;
    crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const { state } = view;
      const ranges = [];
      // Case-INSENSITIVE, matching window.find (navigation) and countMatches
      // (the "N matches" label). They used to disagree: searching "hello" for
      // "Hello" reported 3 matches and navigated through them, while Replace
      // silently did nothing and Replace All returned 0.
      const needle = term.toLowerCase();
      state.doc.descendants((node, pos) => {
        if (!node.isText) return;
        const text = (node.text ?? "").toLowerCase();
        let index = 0;
        while ((index = text.indexOf(needle, index)) !== -1) {
          ranges.push({ from: pos + index, to: pos + index + term.length });
          index += term.length;
        }
      });
      if (!ranges.length) return;
      let tr = state.tr;
      // Back to front so earlier replacements don't shift later ranges.
      for (let i = ranges.length - 1; i >= 0; i -= 1) {
        tr = tr.insertText(safeReplacement, ranges[i].from, ranges[i].to);
      }
      view.dispatch(tr);
      count = ranges.length;
    });
    return count;
  },
  // Replaces the current selection when it equals `term`, then advances to
  // the next match either way. Returns whether a replacement happened.
  replaceNext(term, replacement) {
    if (!crepe || typeof term !== "string" || !term) return false;
    const safeReplacement = typeof replacement === "string" ? replacement : "";
    let replaced = false;
    crepe.editor.action((ctx) => {
      const view = ctx.get(editorViewCtx);
      const { state } = view;
      const { from, to } = state.selection;
      // Same case-insensitivity as above: window.find selects "Hello" when the
      // user searched "hello", and a strict compare here refused to replace it.
      if (from !== to && state.doc.textBetween(from, to).toLowerCase() === term.toLowerCase()) {
        view.dispatch(state.tr.insertText(safeReplacement, from, to));
        replaced = true;
      }
    });
    window.find(term, false, false, true, false, true, false);
    return replaced;
  },
  // Swift answers an image-save request; null/undefined path = failure.
  resolveImageSave(id, path) {
    const pending = pendingImageSaves.get(id);
    if (!pending) return;
    pendingImageSaves.delete(id);
    if (typeof path === "string" && path) {
      pending.resolve(path);
    } else {
      pending.reject(new Error("image save failed"));
    }
  },
  // Typography: preferences-driven CSS variable overrides. `scheme` picks a
  // font stack ("default" keeps the theme's own), the numeric knobs feed CSS
  // variables consumed in index.html. 0/null = theme default for each.
  setTypography(config) {
    const root2 = document.documentElement;
    const scheme = config?.scheme;
    if (scheme === "serif" || scheme === "sans") {
      root2.setAttribute("data-vellumi-font", scheme);
    } else {
      root2.removeAttribute("data-vellumi-font");
    }
    const setVar = (name, value, unit) => {
      if (typeof value === "number" && value > 0) {
        root2.style.setProperty(name, `${value}${unit}`);
      } else {
        root2.style.removeProperty(name);
      }
    };
    setVar("--vellumi-line-height", config?.lineHeight, "");
    setVar("--vellumi-paragraph-spacing", config?.paragraphSpacing, "em");
    setVar("--vellumi-max-width", config?.maxWidth, "px");
  },
  // Curly quotes / … / — while typing. Rebuilds the editor (rules are baked
  // in at construction); content survives via the normal serialize path.
  setSmartPunctuation(on) {
    const next = Boolean(on);
    if (next === smartPunctuationEnabled) return;
    smartPunctuationEnabled = next;
    if (crepe) {
      const markdown = crepe.getMarkdown();
      lastSentMarkdown = markdown;
      window.moltenAPI.setMarkdown(markdown);
    }
  },
  // Scroll position exchange for source-mode round trips.
  getScrollFraction() {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    return max > 1 ? window.scrollY / max : 0;
  },
  setScrollFraction(fraction) {
    if (typeof fraction !== "number") return;
    pendingScrollFraction = Math.max(0, Math.min(1, fraction));
    applyPendingScroll();
  },
  // View-mode toggles driven by the native View menu / Preferences.
  setTypewriter(on) {
    typewriterEnabled = Boolean(on);
    if (typewriterEnabled) updateViewModes();
  },
  setFocusMode(on) {
    focusModeEnabled = Boolean(on);
    document.body.classList.toggle("vellumi-focus-mode", focusModeEnabled);
    if (focusModeEnabled) {
      updateViewModes();
    } else {
      editingSurface()
        ?.querySelectorAll(".vellumi-focus-active")
        .forEach((el) => el.classList.remove("vellumi-focus-active"));
    }
  },
  setSpellcheck(on) {
    spellcheckEnabled = Boolean(on);
    applySpellcheck();
  },
  // Exposed for tests: the display-time rewrite of document-relative srcs.
  rewriteAssetURL,
};

// Boot failures must be loud: reach Swift over the bridge AND stay readable
// for tests/debugging via window.__moltenBootError.
window.addEventListener("error", (event) => {
  window.__moltenBootError ??= String(event.error?.stack ?? event.message);
});

post({ type: "ready" });
