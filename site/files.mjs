// The one list of files the site ships. build.mjs copies exactly these; test.mjs checks dist/ matches.
import { readdir } from 'node:fs/promises';
const art = (await readdir(new URL('./art/', import.meta.url))).filter(f => f.endsWith('.svg')).sort().map(f => `art/${f}`);
export const files = ['index.html', 'legal.html', 'install.sh', 'style.css', 'site.js', 'try.js', 'paper.svg', 'favicon.png', 'favicon.ico', 'favicon-riso-v2.svg', 'favicon-riso-v2.png', 'apple-touch-icon-riso-v2.png', 'icon-512-riso-v2.png', 'apple-touch-icon.png', 'icon-512.png', '_headers', ...art];
export { art };
