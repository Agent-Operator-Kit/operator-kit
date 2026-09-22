import { build } from 'esbuild';
import { mkdir, readFile, writeFile } from 'node:fs/promises';

await mkdir(new URL('./dist/', import.meta.url), { recursive: true });

await build({
  entryPoints: ['src/server.mjs'],
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  outfile: 'dist/server.mjs',
  banner: { js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);" }
});

const ui = await build({
  entryPoints: ['src/ui.js'],
  bundle: true,
  format: 'esm',
  target: 'es2022',
  define: { OPERATOR_WEB_PREVIEW: 'false' },
  minify: true,
  write: false
});
const template = await readFile('src/ui.html', 'utf8');
const css = await readFile('src/style.css', 'utf8');
const html = template
  .replace('<!-- STYLE -->', () => `<style>${css}</style>`)
  .replace('<!-- SCRIPT -->', () => `<script type="module">${ui.outputFiles[0].text.replaceAll('</script', '<\\/script')}</script>`);
await writeFile('dist/console.html', html);

const webUi = await build({ entryPoints: ['src/ui.js'], bundle: true, format: 'esm', target: 'es2022', minify: true, write: false, define: { OPERATOR_WEB_PREVIEW: 'true' } });
const webHtml = template
  .replace('<body>', '<body><!-- WEB_CONFIG -->')
  .replace('<!-- STYLE -->', () => `<style>${css}\n:root[data-preview-mode=inline] #app{max-width:900px;margin:auto}</style>`)
  .replace('<!-- SCRIPT -->', () => `<script type="module">${webUi.outputFiles[0].text.replaceAll('</script', '<\\/script')}</script>`);
await writeFile('dist/web.html', webHtml);

console.log('Built Operator Console MCP server and embedded UI.');

for (const name of ['cli', 'dev-host']) await build({
  entryPoints: [`src/${name}.mjs`], bundle: true, platform: 'node', format: 'esm',
  target: 'node20', outfile: `dist/${name}.mjs`, external: ['./dev-host.mjs'],
  banner: { js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);" }
});
await build({ entryPoints: ['src/host.js'], bundle: true, format: 'esm', target: 'es2022', minify: true, outfile: 'dist/host.js' });
