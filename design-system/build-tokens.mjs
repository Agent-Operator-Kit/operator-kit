import {readFileSync, writeFileSync} from 'node:fs';
const read=name=>JSON.parse(readFileSync(new URL(name,import.meta.url),'utf8'));
const lines=['/* Proposed Operator tokens, not official source tokens. */'];
function block(selector,tokens,scheme){lines.push(selector+' {');if(scheme)lines.push('  color-scheme: '+scheme+';');for(const [group,values] of Object.entries(tokens)){if(group.startsWith('$'))continue;for(const [key,value] of Object.entries(values))lines.push(`  --op-${group}-${key}: ${value};`)}lines.push('}');}
block(':root',read('./tokens.json'),'light');
block(':root[data-theme=dark]',read('./tokens.dark.json'),'dark');
lines.push('@media (prefers-reduced-motion: reduce) { :root { --op-motion-fast: 0ms; --op-motion-standard: 0ms; } }','');
writeFileSync(new URL('./tokens.css',import.meta.url),lines.join('\n'));
console.log('Generated light and dark tokens.css');
