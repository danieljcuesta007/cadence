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
const ART = (await readdir('art')).filter(f => f.endsWith('.svg')).sort().map(f => `art/${f}`);
const SHIPPED = ['index.html', 'legal.html', 'style.css', 'site.js', 'favicon.png', 'apple-touch-icon.png', 'icon-512.png', '_headers', ...ART];
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
  for (const [, ref] of html.matchAll(/(?:src|href)="([^"#:]+\.(?:css|js|png|svg))"/g)) await access(ref);
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
  const document = { querySelector: s => s === '[data-copy-status]' ? status : null, querySelectorAll: s => s === '.typed .w' ? words : s === '[data-copy]' ? [copy] : [] };
  const timers = new Map(); let next = 0;
  const writes = [];
  const selected = []; const code = { tagName: 'PRE' }; copy.previousElementSibling = code;
  const status = { textContent: '' };
  runInNewContext(js, { getSelection: () => ({ selectAllChildren: el => selected.push(el) }), document, navigator: { clipboard: { writeText: t => { written.push(t); return new Promise((ok, fail) => writes.push({ ok, fail })); } } },
    setTimeout: fn => { timers.set(++next, fn); return next; }, clearTimeout: id => timers.delete(id) });
  assert.deepEqual(words.map(w => w.style.animationDelay), ['0.60s', '0.77s', '0.94s']);
  const click = () => { const done = copy.listeners.click(); const w = writes.at(-1); return { ok: async () => { w.ok(); await done; }, fail: async () => { w.fail(new Error('denied')); await done; } }; };
  const fire = () => { [...timers.values()].at(-1)(); timers.clear(); };
  // A slow failure that settles after a newer success (even after the reset) changes nothing.
  let slow = click(), fast = click();
  await fast.ok(); assert.equal(copy.textContent, 'Copied'); assert.equal(status.textContent, 'Copied to clipboard');
  fire(); await slow.fail(); assert.equal(copy.textContent, 'Copy', 'a stale failure never shows');
  // An early failure stays quiet while another copy is still in flight, and that copy wins.
  slow = click(); fast = click();
  await fast.fail(); assert.equal(copy.textContent, 'Copy'); assert.deepEqual(selected, []);
  await slow.ok(); assert.equal(copy.textContent, 'Copied');
  assert.equal(status.textContent, 'Copied to clipboard', 'our reset cleared our own message, so this one is announced fresh');
  // A lone failure selects the command and says so.
  fire(); await click().fail();
  assert.equal(copy.textContent, 'Copy failed'); assert.deepEqual(selected, [code]); assert.match(status.textContent, /copy it yourself/);
  fire(); await click().ok();
  status.textContent = 'Copy failed. The command is selected so you can copy it yourself.'; // another button just said this
  await click().fail(); assert.match(status.textContent, /\u00a0$/, 'a repeat from any button is re-announced');
  assert.deepEqual(written, Array(7).fill('brew install --cask cadence'));
  assert.equal(timers.size, 1, 'exactly one reset timer is running');
  [...timers.values()][0]();
  assert.equal(copy.textContent, 'Copy', 'the reset restores the original label');
  const lone = { dataset: { copy: 'x' }, remove() { this.removed = true; } };
  runInNewContext(js, { document: { querySelector: () => null, querySelectorAll: s => s === '[data-copy]' ? [lone] : [] }, navigator: {}, setTimeout() {}, clearTimeout() {} });
  assert.equal(lone.removed, true);
});

test('two copy buttons share the status line without wiping each other', async () => {
  const timers = [];
  const mk = () => ({ textContent: 'Copy', dataset: { copy: 'x' }, listeners: {}, addEventListener(t, f) { this.listeners[t] = f; } });
  const a = mk(), b = mk(); const status = { textContent: '' };
  let fail = false;
  runInNewContext(js, { getSelection: () => ({ selectAllChildren() {} }), document: { querySelector: () => status, querySelectorAll: s => s === '[data-copy]' ? [a, b] : [] },
    navigator: { clipboard: { writeText: async () => { if (fail) throw new Error('denied'); } } }, setTimeout: fn => timers.push(fn), clearTimeout() {} });
  await a.listeners.click();
  fail = true; await b.listeners.click();
  const said = status.textContent;
  timers[0]();  // A's reset fires after B spoke
  assert.equal(a.textContent, 'Copy'); assert.equal(status.textContent, said, "B's message survives A's reset");
  timers[1]();  // B's own reset clears B's message
  assert.equal(status.textContent, '', 'no stale result left behind');
  // Same result from two buttons in a row: A's older timer must not clear B's newer message.
  fail = false; timers.length = 0;
  await a.listeners.click(); await b.listeners.click(); await b.listeners.click(); // the text cycles back to A's exact string
  const newest = status.textContent;
  timers[0]();
  assert.equal(status.textContent, newest, "A's timer leaves B's identical, newer message alone");
  timers[2](); assert.equal(status.textContent, '', "B's latest timer clears it");
});

test('the page has the status line copy results are announced in', () => {
  const tags = home.match(/<[^>]*data-copy-status[^>]*>/g) || [];
  assert.equal(tags.length, 1, 'exactly one status line');
  assert.match(tags[0], /role="status"/);
  assert.match(tags[0], /class="visually-hidden"/, 'the status line must stay invisible');
});

test('copy degrades: no selection API gives an honest message; no status line keeps the buttons', async () => {
  const copy = { textContent: 'Copy', dataset: { copy: 'x' }, listeners: {}, previousElementSibling: { tagName: 'PRE' }, addEventListener(t, f) { this.listeners[t] = f; }, remove() { this.removed = true; } };
  const status = { textContent: '' };
  runInNewContext(js, { getSelection: () => { throw new Error('no selection here'); }, document: { querySelector: () => status, querySelectorAll: s => s === '[data-copy]' ? [copy] : [] },
    navigator: { clipboard: { writeText: async () => { throw new Error('denied'); } } }, setTimeout() {}, clearTimeout() {} });
  await copy.listeners.click();
  assert.equal(copy.textContent, 'Copy failed'); assert.match(status.textContent, /copy the command manually/); assert.doesNotMatch(status.textContent, /above|selected/);
  const kept = { textContent: 'Copy', dataset: { copy: 'x' }, listeners: {}, addEventListener(t, f) { this.listeners[t] = f; }, remove() { this.removed = true; } };
  runInNewContext(js, { document: { querySelector: () => null, querySelectorAll: s => s === '[data-copy]' ? [kept] : [] }, navigator: { clipboard: { writeText: async () => {} } }, setTimeout() {}, clearTimeout() {} });
  await kept.listeners.click();
  assert.equal(kept.removed, undefined); assert.equal(kept.textContent, 'Copied');
  const lost = { textContent: 'Copy', dataset: { copy: 'x' }, listeners: {}, addEventListener(t, f) { this.listeners[t] = f; } };
  runInNewContext(js, { document: { querySelector: () => null, querySelectorAll: s => s === '[data-copy]' ? [lost] : [] }, navigator: { clipboard: { writeText: async () => { throw new Error('denied'); } } }, setTimeout() {}, clearTimeout() {} });
  await lost.listeners.click();
  assert.equal(lost.textContent, 'Copy failed', 'a failure without a status line still shows on the button');
});

test('build ships exactly the reviewed files, unchanged and free of private data', async () => {
  const builtFiles = (await readdir('dist', { recursive: true })).filter(f => f !== 'art');
  assert.deepEqual(builtFiles.sort(), [...SHIPPED].sort());
  for (const [, ref] of html.matchAll(/(?:src|href)="([^"#:]+\.(?:css|js|png|svg))"/g)) await access(`dist/${ref}`);
  for (const file of SHIPPED) {
    const built = await readFile(`dist/${file}`), source = await readFile(file);
    assert.ok(built.equals(source), file);
    if (/\.(html|css|js|svg)$|_headers/.test(file)) assert.doesNotMatch(built.toString(), /\/Users\/|\/private\/tmp\/|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|@nd\.edu/);
  }
});

// Wide screens, 14 Oct: "no matter what computer it's loaded in it fixes itself accordingly."
// A fixed 1120px column left dead margins either side of anything wider than ~1250px.
test('the content cap tracks the window instead of stopping at a fixed width', () => {
  assert.match(css, /--gutter:clamp\(16px,5vw,64px\); --max:1120px;/, 'the base cap is unchanged below 1300px');
  for (const [bp, cap] of [['1300', '1400px'], ['1800', '1640px'], ['2400', '1840px']]) {
    assert.ok(css.includes(`@media (min-width:${bp}px) { :root { --max:min(${cap}, calc(100vw - 2 * var(--gutter))); } }`),
      `above ${bp}px the cap becomes ${cap} or the window minus its gutters`);
  }
  assert.match(css, /main > section > \* \{ max-width:var\(--max\)/, 'the column reads the cap, so every section follows');
});

// Riso brand, 29 Oct: the art is self-hosted SVG, so it must obey the same strict CSP as the pages.
test('the riso art is self-contained and works under the strict policy', async () => {
  for (const file of ART) {
    const svg = await readFile(file, 'utf8');
    assert.match(svg, /<title id="t">[^<]{12,}<\/title>/, `${file} describes itself`);
    assert.doesNotMatch(svg, /<script|\sstyle=|<style|\son[a-z]+=|https?:\/\/(?!www\.w3\.org\/2000\/svg)/, `${file} has no script, inline CSS or remote reference`);
    const paints = [...svg.matchAll(/\b(?:fill|stroke|stop-color|flood-color|color)="([^"]+)"/g)].map(m => m[1]);
    assert.ok(paints.length, `${file} paints something`);
    for (const paint of paints) assert.ok(['#2443C4', '#5CB567', '#EC4A32', 'NONE'].includes(paint.toUpperCase()), `${file}: ${paint} is not a Cadence ink`);
    assert.doesNotMatch(svg, /rgba?\(|hsla?\(/, `${file} uses hex inks only`);
    assert.equal((svg.match(/filter="url\(#grain\)"/g) || []).length, 1, `${file} runs the grain once`);
  }
  for (const file of ART.filter(f => !f.endsWith('mark.svg'))) assert.ok(home.includes(`src="${file}"`), `${file} is on the home page`);
  assert.ok(home.includes('src="art/mark.svg"') && legal.includes('src="art/mark.svg"'), 'both pages carry the mark');
  assert.match(css, /--red-text:#b02d18;/, 'small red text uses the AA red');
  assert.match(css, /--blue:#2443c4;/); assert.match(css, /--green:#5cb567;/); assert.match(css, /--red:#ec4a32;/);
});
