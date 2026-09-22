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
// Build both hosts from the accepted token source and bundle the font offline.
const designRoot = new URL('../../../design-system/', import.meta.url);
const tokenBlock = (selector, tokens) => selector + '{' + Object.entries(tokens).filter(([key]) => !key.startsWith('$')).flatMap(([group, values]) => Object.entries(values).map(([key, value]) => '--op-' + group + '-' + key + ':' + value + ';')).join('') + '}';
const light = JSON.parse(await readFile(new URL('tokens.json', designRoot), 'utf8'));
const dark = JSON.parse(await readFile(new URL('tokens.dark.json', designRoot), 'utf8'));
const font = (await readFile(new URL('InterVariable.woff2', designRoot))).toString('base64');
const css = tokenBlock(':root', light) + tokenBlock(':root[data-theme=dark]', dark) + '@font-face{font-family:InterVariable;font-style:normal;font-weight:100 900;font-display:swap;src:url(data:font/woff2;base64,' + font + ') format("woff2")}' + await readFile('src/style.css', 'utf8');
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
