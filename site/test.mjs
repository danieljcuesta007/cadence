import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, access } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

const pages = { 'index.html': await readFile('index.html', 'utf8'), 'legal.html': await readFile('legal.html', 'utf8') };
const home = pages['index.html'], legal = pages['legal.html'], html = home + legal;
const css = await readFile('style.css', 'utf8');
const js = await readFile('site.js', 'utf8');
const headers = await readFile('_headers', 'utf8');
const cask = await readFile('../Casks/cadence.rb', 'utf8');
const SHIPPED = ['index.html', 'legal.html', 'style.css', 'site.js', 'favicon.png', 'apple-touch-icon.png', 'icon-512.png', '_headers'];
const OUTBOUND = /^https:\/\/(github\.com\/danieljcuesta007\/cadence(\/|$)|danielcuesta007\.com$|addisuna\.com$|skeptic\.pages\.dev$|wisprflow\.ai\/(pricing|privacy)$|superwhisper\.com$|support\.apple\.com\/)/;

test('internal links and fragments resolve, IDs are unique per page', () => {
  for (const [name, page] of Object.entries(pages)) {
    const ids = [...page.matchAll(/\sid="([^"]+)"/g)].map(m => m[1]);
    assert.equal(new Set(ids).size, ids.length, name);
    for (const [, href] of page.matchAll(/<a\b[^>]*href="([^"]+)"/g)) {
      if (/^https?:/.test(href)) continue;
      const [file, fragment] = href.split('#');
      assert.ok(!file || pages[file], href);
      if (fragment) assert.ok(pages[file || name].includes(`id="${fragment}"`), `${name}: ${href}`);
    }
  }
  for (const id of ['features', 'compare', 'download', 'creator', 'faq', 'why-warning']) assert.ok(home.includes(`id="${id}"`), id);
  for (const id of ['privacy', 'license', 'credits', 'trademarks', 'contact']) assert.ok(legal.includes(`id="${id}"`), id);
});

test('local assets exist and nothing loads from another origin', async () => {
  for (const [, ref] of html.matchAll(/(?:src|href)="([^"#:]+\.(?:css|js|png))"/g)) await access(ref);
  assert.doesNotMatch(html, /<(?:script|link|img|iframe)\b[^>]*(?:src|href)="https?:/);
  for (const [, href] of html.matchAll(/<a\b[^>]*href="(https?:[^"]+)"/g)) assert.match(href, OUTBOUND, href);
  assert.doesNotMatch(js, /fetch\s*\(|XMLHttpRequest|sendBeacon|WebSocket|localStorage|sessionStorage|https?:\/\//);
});

test('markup works under the strict content security policy', () => {
  for (const rule of ["default-src 'none'", "script-src 'self'", "style-src 'self'", "connect-src 'none'", "form-action 'none'", "frame-ancestors 'none'"]) assert.ok(headers.includes(rule), rule);
  assert.doesNotMatch(html, /\sstyle="/);
  assert.doesNotMatch(html, /\son[a-z]+="/);
  assert.doesNotMatch(html, /<script\b(?![^>]*\bsrc=)[^>]*>/);
  assert.doesNotMatch(html, /<form\b/);
});

test('each page has one h1, a skip link and labelled navigation', () => {
  for (const page of Object.values(pages)) {
    assert.equal((page.match(/<h1\b/g) || []).length, 1);
    assert.match(page, /class="skip" href="#main"/);
    assert.match(page, /id="main" tabindex="-1"/);
    assert.match(page, /aria-label="Main navigation"/);
    for (const [img] of page.matchAll(/<img\b[^>]*>/g)) assert.match(img, /\salt="/, img);
  }
  assert.match(css, /prefers-reduced-motion:reduce/);
  assert.match(css, /prefers-color-scheme:dark/);
  assert.match(css, /min-height:44px/);
});

test('the notarization choice is explained plainly', () => {
  assert.match(home, /\$99 a year/);
  assert.match(home, /not passing that cost on to you/);
  assert.match(home, /deliberate choice/);
  assert.match(home, /Open Anyway/);
  assert.match(home, /Microphone<\/b>.*Accessibility<\/b>/s);
  assert.doesNotMatch(html, /\bis notarized\b|signed by Apple|Developer ID/i);
});

test('comparison is dated, sourced and fair', () => {
  const section = home.match(/<section class="compare"[\s\S]*?<\/section>/)[0];
  assert.match(section, /as of October 2026/);
  for (const source of ['wisprflow.ai/pricing', 'wisprflow.ai/privacy', 'superwhisper.com', 'support.apple.com']) assert.ok(section.includes(source), source);
  assert.match(section, /Where they win/);
  for (const page of Object.values(pages)) assert.match(page, /not affiliated with/);
  assert.match(legal, /THIRD_PARTY_NOTICES\.md/);
  assert.doesNotMatch(html, /while idle/, 'privacy claims must say the same thing on every page');
  assert.match(home, /og:image" content="https:\/\//);
  assert.match(home + legal, /Whisper/);
});

test('download button, cask and published checksum agree', () => {
  assert.match(home, /href="https:\/\/github\.com\/danieljcuesta007\/cadence\/releases\/latest\/download\/Cadence\.dmg"/);
  const sha = home.match(/<code data-sha>([^<]*)<\/code>/)[1];
  assert.ok(cask.includes(`sha256 "${sha}"`), 'site and cask checksums differ');
  assert.match(cask, /releases\/download\/v#\{version\}\/Cadence\.dmg/);
  assert.match(cask, /depends_on arch: :arm64/);
  assert.doesNotMatch(cask, /\bzap\b/, 'uninstall must never delete ~/.cadence (it holds the encryption key)');
});

test('site.js: words get staggered delays; copy writes the command; no clipboard hides the button', async () => {
  const words = [{ style: {} }, { style: {} }, { style: {} }];
  const copy = { textContent: 'Copy', dataset: { copy: 'brew install --cask cadence' }, listeners: {}, addEventListener(t, f) { this.listeners[t] = f; } };
  const written = [];
  const document = { querySelectorAll: s => s === '.typed .w' ? words : s === '[data-copy]' ? [copy] : [] };
  const timers = new Map(); let next = 0;
  const writes = [];
  runInNewContext(js, { document, navigator: { clipboard: { writeText: t => { written.push(t); return new Promise((ok, fail) => writes.push({ ok, fail })); } } },
    setTimeout: fn => { timers.set(++next, fn); return next; }, clearTimeout: id => timers.delete(id) });
  assert.deepEqual(words.map(w => w.style.animationDelay), ['0.60s', '0.77s', '0.94s']);
  const settle = async (click, i, how) => { how === 'ok' ? writes[i].ok() : writes[i].fail(new Error('denied')); await click; };
  // Older click fails late, after a newer success: the success stands.
  let older = copy.listeners.click(), newer = copy.listeners.click();
  assert.equal(copy.textContent, 'Copy', 'pending clicks show the plain label');
  await settle(newer, 1, 'ok'); await settle(older, 0, 'fail');
  assert.equal(copy.textContent, 'Copied');
  // Older click succeeds late, after a newer failure: the failure stands.
  older = copy.listeners.click(); newer = copy.listeners.click();
  assert.equal(copy.textContent, 'Copy', 'a new click clears the old "Copied" while its write is pending');
  await settle(newer, 3, 'fail'); await settle(older, 2, 'ok');
  assert.equal(copy.textContent, 'Select and copy');
  assert.deepEqual(written, Array(4).fill('brew install --cask cadence'));
  assert.equal(timers.size, 1, 'only the newest reset timer is left running');
  [...timers.values()][0]();
  assert.equal(copy.textContent, 'Copy', 'the reset restores the original label');
  const lone = { dataset: { copy: 'x' }, remove() { this.removed = true; } };
  runInNewContext(js, { document: { querySelectorAll: s => s === '[data-copy]' ? [lone] : [] }, navigator: {}, setTimeout() {}, clearTimeout() {} });
  assert.equal(lone.removed, true);
});

test('build ships exactly the reviewed files, unchanged and free of private data', async () => {
  assert.deepEqual((await readdir('dist')).sort(), [...SHIPPED].sort());
  for (const file of SHIPPED) {
    const built = await readFile(`dist/${file}`), source = await readFile(file);
    assert.ok(built.equals(source), file);
    if (/\.(html|css|js)$|_headers/.test(file)) assert.doesNotMatch(built.toString(), /\/Users\/|\/private\/tmp\/|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|@nd\.edu/);
  }
});
