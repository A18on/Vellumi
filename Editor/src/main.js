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
import { undoCommand, redoCommand } from "@milkdown/plugin-history";
import { TextSelection } from "@milkdown/prose/state";
import { callCommand } from "@milkdown/utils";
import "@milkdown/crepe/theme/common/style.css";
// Frame theme ships as separate light/dark files (each redefines the same
// variables), so they are built as standalone stylesheets and index.html
// swaps them via prefers-color-scheme media queries.

// Trailing debounce for change messages, with a max-latency bound: a fluent
// typist never pausing 150ms must still flush at least once per second, or
// Swift's copy (autosave, crash recovery) goes unboundedly stale.
const CHANGE_DEBOUNCE_MS = 150;
const CHANGE_MAX_LATENCY_MS = 1000;

const root = document.getElementById("editor");
let crepe = null;
let changeTimer = null;
let oldestPendingChangeAt = null;
let lastSentMarkdown = null;
// Guards the async rebuild in setMarkdown: a stale create() must not clobber
// a newer document load.
let loadGeneration = 0;

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
  oldestPendingChangeAt = null;
  if (!crepe) return;
  const markdown = crepe.getMarkdown();
  if (markdown !== lastSentMarkdown) {
    lastSentMarkdown = markdown;
    post({ type: "change", markdown });
  }
}

function scheduleChange() {
  const now = Date.now();
  oldestPendingChangeAt ??= now;
  if (now - oldestPendingChangeAt >= CHANGE_MAX_LATENCY_MS) {
    flushChange();
    return;
  }
  clearTimeout(changeTimer);
  changeTimer = setTimeout(flushChange, CHANGE_DEBOUNCE_MS);
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
      [Crepe.Feature.ImageBlock]: {
        onUpload: uploadImage,
        inlineOnUpload: uploadImage,
        blockOnUpload: uploadImage,
        proxyDomURL: rewriteAssetURL,
      },
    },
  });
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
  focusEditor();
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
  // Native Edit ▸ Undo/Redo menu items forward here — WKWebView exposes no
  // responder-chain undo, and ProseMirror's history is the real stack.
  undo() {
    crepe?.editor.action(callCommand(undoCommand.key));
  },
  redo() {
    crepe?.editor.action(callCommand(redoCommand.key));
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
      state.doc.descendants((node, pos) => {
        if (!node.isText) return;
        const text = node.text ?? "";
        let index = 0;
        while ((index = text.indexOf(term, index)) !== -1) {
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
      if (from !== to && state.doc.textBetween(from, to) === term) {
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
  // Exposed for tests: the display-time rewrite of document-relative srcs.
  rewriteAssetURL,
};

// Boot failures must be loud: reach Swift over the bridge AND stay readable
// for tests/debugging via window.__moltenBootError.
window.addEventListener("error", (event) => {
  window.__moltenBootError ??= String(event.error?.stack ?? event.message);
});

post({ type: "ready" });
