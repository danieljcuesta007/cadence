import { mkdir, copyFile, rm } from 'node:fs/promises';
import { files } from './files.mjs';
await rm('dist', { recursive: true, force: true });
await mkdir('dist/art', { recursive: true });
for (const file of files) await copyFile(file, `dist/${file}`);
console.log(`Production static build: dist/ (${files.length} files). No dependencies or network.`);
