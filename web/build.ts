// Builds the renderer page into the app's resource folder, or into the folder
// given as the first argument:
//
//   bun run build.ts [outdir]
//
// Writes index.html, page.css, page.js (bundled from src/page.ts) and
// mermaid.min.js (mermaid's own browser build, loaded as a global).
import { copyFileSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";

const here = import.meta.dir;
const outdir = resolve(process.argv[2] ?? join(here, "../Sources/Scwrote/Resources/Preview"));

rmSync(outdir, { recursive: true, force: true });
mkdirSync(outdir, { recursive: true });

const result = await Bun.build({
  entrypoints: [join(here, "src/page.ts")],
  target: "browser",
  format: "iife",
  minify: true,
  naming: "page.js",
  outdir,
});
if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}
for (const log of result.logs) console.error(log);

for (const name of ["index.html", "page.css"]) copyFileSync(join(here, name), join(outdir, name));
copyFileSync(join(here, "node_modules/mermaid/dist/mermaid.min.js"), join(outdir, "mermaid.min.js"));
