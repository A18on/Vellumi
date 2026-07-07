// Molten editing surface.
//
// A Milkdown Crepe editor (ProseMirror under the hood) fills the window and
// gives the Typora-style "melting" feel: markdown syntax fuses into rendered
// typography as you type. The native Swift shell owns the file; this side owns
// the editing session and reports serialized markdown back over the bridge.
//
// Bridge contract (keep in sync with MoltenEditorViewController.swift):
//   JS → Swift  window.webkit.messageHandlers.molten.postMessage(…)
//     {type: "ready"}                       editor booted, safe to setMarkdown
//     {type: "change", markdown: String}    debounced content update
//   Swift → JS  window.moltenAPI.*
//     setMarkdown(md)   load document content (rebuilds the editor)
//     getMarkdown()     synchronous pull of the current serialization
//     setAppearance(a)  "light" | "dark" — mirrors the host window appearance

import { Crepe } from "@milkdown/crepe";
import "@milkdown/crepe/theme/common/style.css";
// Frame theme ships as separate light/dark files (each redefines the same
// variables), so they are built as standalone stylesheets and index.html
// swaps them via prefers-color-scheme media queries.

const CHANGE_DEBOUNCE_MS = 150;

const root = document.getElementById("editor");
let crepe = null;
let changeTimer = null;
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

function scheduleChange(markdown) {
  clearTimeout(changeTimer);
  changeTimer = setTimeout(() => {
    if (markdown !== lastSentMarkdown) {
      lastSentMarkdown = markdown;
      post({ type: "change", markdown });
    }
  }, CHANGE_DEBOUNCE_MS);
}

async function createEditor(markdown) {
  const generation = ++loadGeneration;
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

  const next = new Crepe({ root, defaultValue: markdown });
  next.on((listener) => {
    listener.markdownUpdated((_ctx, md) => {
      if (next === crepe) {
        scheduleChange(md);
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
  // AppKit gives the WKWebView first-responder status, but typing only lands
  // once the contenteditable itself has DOM focus.
  focusEditor();
}

function focusEditor() {
  requestAnimationFrame(() => {
    root.querySelector(".ProseMirror")?.focus();
  });
}

window.moltenAPI = {
  setMarkdown(markdown) {
    createEditor(typeof markdown === "string" ? markdown : "");
  },
  getMarkdown() {
    // Flush the pending debounce so Swift never saves stale content.
    clearTimeout(changeTimer);
    if (!crepe) return lastSentMarkdown ?? "";
    const markdown = crepe.getMarkdown();
    lastSentMarkdown = markdown;
    return markdown;
  },
  setAppearance(appearance) {
    document.documentElement.dataset.appearance =
      appearance === "dark" ? "dark" : "light";
  },
  focus() {
    focusEditor();
  },
};

// Boot failures must be loud: surface them to the shell log and keep the
// stack readable for tests/debugging via window.__moltenBootError.
window.addEventListener("error", (event) => {
  window.__moltenBootError ??= String(event.error?.stack ?? event.message);
});

createEditor("")
  .then(() => post({ type: "ready" }))
  .catch((error) => {
    window.__moltenBootError = String(error?.stack ?? error);
    post({ type: "boot-error", message: String(error) });
  });
