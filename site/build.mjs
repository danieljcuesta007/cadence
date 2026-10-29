import { mkdir, copyFile, rm, readdir } from 'node:fs/promises';
// Every SVG in art/ ships; the tests check each one is used and obeys the brand rules.
export const art = (await readdir('art')).filter(f => f.endsWith('.svg')).sort().map(f => `art/${f}`);
const files = ['index.html','legal.html','style.css','site.js','favicon.png','apple-touch-icon.png','icon-512.png','_headers', ...art];
await rm('dist', { recursive: true, force: true });
await mkdir('dist/art', { recursive: true });
for (const file of files) await copyFile(file, `dist/${file}`);
console.log(`Production static build: dist/ (${files.length} files). No dependencies or network.`);
