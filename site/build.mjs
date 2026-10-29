import { mkdir, copyFile, rm } from 'node:fs/promises';
const art = ['announcer','hold','speak','release','jar','bubbles','mark'].map(name => `art/${name}.svg`);
const files = ['index.html','legal.html','style.css','site.js','favicon.png','apple-touch-icon.png','icon-512.png','_headers', ...art];
await rm('dist', { recursive: true, force: true });
await mkdir('dist/art', { recursive: true });
for (const file of files) await copyFile(file, `dist/${file}`);
console.log(`Production static build: dist/ (${files.length} files). No dependencies or network.`);
