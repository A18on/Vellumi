// Bundles the Crepe editor into a fully offline payload under Resources/dist.
// Everything the WKWebView loads — JS, CSS, fonts — must come out of this build;
// the app ships no network access for the editor surface.
import { build, context } from "esbuild";
import { cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, "..", "Resources", "dist");
const watch = process.argv.includes("--watch");

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

/** @type {import("esbuild").BuildOptions} */
const options = {
  entryPoints: [join(here, "src", "main.js")],
  bundle: true,
  format: "iife",
  outfile: join(outDir, "editor.js"),
  minify: true,
  sourcemap: false,
  logLevel: "info",
  // Fonts and images referenced from vendored CSS are copied next to the bundle.
  loader: {
    ".woff": "file",
    ".woff2": "file",
    ".ttf": "file",
    ".otf": "file",
    ".eot": "file",
    ".svg": "dataurl",
    ".png": "dataurl",
  },
  assetNames: "assets/[name]-[hash]",
};

/** Theme variables build as standalone stylesheets, switched in index.html
 *  via prefers-color-scheme (the variables collide if bundled together). */
const themeOptions = {
  entryPoints: ["frame", "nord", "classic"].flatMap((name) => [
    join(here, "src", "themes", `${name}-light.css`),
    join(here, "src", "themes", `${name}-dark.css`),
  ]),
  bundle: true,
  outdir: join(outDir, "themes"),
  minify: true,
  logLevel: "info",
  loader: options.loader,
  assetNames: "assets/[name]-[hash]",
};

// Themes and the page shell are cheap and rarely change — emit them in every
// mode so a watch session never produces a dist with 404ing stylesheets.
await build(themeOptions);
cpSync(join(here, "public", "index.html"), join(outDir, "index.html"));
// The dir is git-ignored except for this marker, which keeps the folder
// present for xcodegen on fresh clones; recreate it after the wipe above.
writeFileSync(join(outDir, ".gitkeep"), "");

if (watch) {
  // Dev loop: skip minification (the slowest phase) and keep readable stacks.
  const ctx = await context({ ...options, minify: false, sourcemap: "inline" });
  await ctx.watch();
  console.log("watching…");
} else {
  await build(options);
}

console.log("dist ready:", outDir);
