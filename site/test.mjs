import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, access } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { files as SHIPPED, art as ART } from './files.mjs';

const pages = { 'index.html': await readFile('index.html', 'utf8'), 'legal.html': await readFile('legal.html', 'utf8') };
const home = pages['index.html'], legal = pages['legal.html'], html = home + legal;
const css = await readFile('style.css', 'utf8');
const js = await readFile('site.js', 'utf8');
const tryJs = await readFile('try.js', 'utf8');
const headers = await readFile('_headers', 'utf8');
const cask = await readFile('../Casks/cadence.rb', 'utf8');
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
    for (const paint of paints) assert.ok(['#2443C4', '#F2A2BF', '#EC4A32', 'NONE'].includes(paint.toUpperCase()), `${file}: ${paint} is not a Cadence ink`);
    assert.doesNotMatch(svg, /rgba?\(|hsla?\(/, `${file} uses hex inks only`);
    assert.equal((svg.match(/filter="url\(#grain\)"/g) || []).length, 1, `${file} runs the grain once`);
  }
  for (const file of ART.filter(f => !f.endsWith('mark.svg'))) assert.ok(home.includes(`src="${file}"`), `${file} is on the home page`);
  assert.ok(home.includes('src="art/mark.svg"') && legal.includes('src="art/mark.svg"'), 'both pages carry the mark');
  assert.match(css, /--red-text:#b02d18;/, 'small red text uses the AA red');
  // White, not cream (Daniel, 29 Oct): the paper and every print card are pure white.
  assert.match(css, /--paper:#ffffff;/); assert.match(css, /--card:#ffffff;/);
  // Illustration cards may be a breath warmer than the page, never actual cream.
  assert.match(css, /--print:#fdfaf3;/);
  assert.doesNotMatch(css + home + legal, /#f3ecdc|#ebe2cc|#fbf7ee/i, 'no cream left anywhere');
  assert.match(css, /--blue:#2443c4;/); assert.match(css, /--pink:#f2a2bf;/); assert.match(css, /--red:#ec4a32;/);
});

// 29 Oct: "we just want to highlight DC Labs, not necessarily the use of AI."
test('every page credits "Built by DC Labs, a Daniel J. Cuesta company", never "with Claude"', () => {
  assert.doesNotMatch(html, /with(&nbsp;|\s| )Claude/i);
  // 29 Oct: one credit line for every DC Labs product.
  for (const page of [home, legal]) assert.match(page, /Built by DC Labs, a Daniel J\. Cuesta company\./);
});

// 29 Oct: "more textured like papery … the site itself I still want in the textured white paper look."
test('the white is textured paper on every surface', async () => {
  const paper = await readFile('paper.svg', 'utf8');
  assert.match(paper, /feTurbulence[^>]*stitchTiles="stitch"/, 'the texture tiles without seams');
  assert.doesNotMatch(paper, /<script|\sstyle=|https?:\/\/(?!www\.w3\.org\/2000\/svg)/);
  assert.match(css, /--texture:url\(paper\.svg\); --print-texture:url\(paper\.svg\);/);
  const bare = css.replace(/\/\*[\s\S]*?\*\//g, '');
  const lists = [...bare.matchAll(/([^{}]+)\{ background-image:var\(--(?:print-)?texture\); background-size:400px; \}/g)].map(m => m[1].split(',').map(s => s.trim()));
  const textured = new Set(lists.flat());
  assert.ok(textured.has('body') && textured.has('.print'), 'the page and the prints are paper');
  for (const [, sel] of bare.matchAll(/([^{}@]+)\{[^}]*background:var\(--(?:paper|card|paper-2|print)\)/g))
    for (const s of sel.split(',').map(x => x.trim())) assert.ok(textured.has(s), `${s} is a paper surface without the texture`);
});

test('try.js: no network, storage or recording; the microphone is optional', () => {
  assert.doesNotMatch(tryJs, /fetch\s*\(|XMLHttpRequest|sendBeacon|WebSocket|localStorage|sessionStorage|indexedDB|MediaRecorder|https?:\/\/|\.destination/);
  assert.match(headers, /Permissions-Policy: camera=\(\), microphone=\(self\), geolocation=\(\)/, 'microphone for this site only, camera and location still off');
  assert.match(home, /nothing is recorded, saved or sent/i);
  assert.match(home, /data-orb-toggle[^>]*hidden/, 'no button until the script knows a microphone could work');
});

function loadTry() { const ctx = {}; runInNewContext(tryJs, ctx); return ctx; }

test('voice level is boosted RMS, clamped to 1; the orb only turns while it hears you', () => {
  const { voiceLevel, orbMotion } = loadTry();
  assert.equal(voiceLevel(new Uint8Array(8), 1.5), 0);
  assert.equal(voiceLevel(null, 1.5), 0);
  assert.ok(Math.abs(voiceLevel(new Uint8Array(4).fill(51), 1.5) - 0.9) < 1e-9, 'RMS 0.2 x 1.5 x 3');
  assert.equal(voiceLevel(new Uint8Array(4).fill(255), 1.5), 1);
  const s = { rot: 0, hover: 0, hoverIntensity: 0 };
  orbMotion(s, 0.04, 1, 1.2, 0.8); assert.equal(s.rot, 0, 'silence does not spin');
  orbMotion(s, 0.5, 1, 1.2, 0.8); assert.ok(Math.abs(s.rot - 1.5) < 1e-9); assert.equal(s.hover, 1); assert.ok(Math.abs(s.hoverIntensity - 0.32) < 1e-9);
});

function fakeTry({ grant = true, withOrb = false, hold = false, level = 51, words = 0, loopBox = null } = {}) {
  const calls = { getUserMedia: 0, stopped: 0, closed: 0, order: [], frames: 0 };
  let release, lost; const loud = { value: level };
  const el = () => ({ textContent: '', hidden: true, disabled: false, attrs: {}, classes: new Set(), listeners: {},
    setAttribute(k, v) { this.attrs[k] = v; }, addEventListener(t, f) { this.listeners[t] = f; }, classList: null, querySelector: () => null });
  const button = el(), status = el(), root = el(), title = el();
  const classy = () => { const set = new Set(); return { set, add: c => set.add(c), remove: c => set.delete(c), contains: c => set.has(c), toggle: (c, on) => on ? set.add(c) : set.delete(c) }; };
  for (const e of [root, title]) e.classList = { add: c => e.classes.add(c) };
  const wordEls = Array.from({ length: words }, () => ({ classList: classy() }));
  const typed = words ? { classList: classy(), querySelectorAll: () => wordEls } : null;
  const props = {};
  if (loopBox) {
    const path = { getTotalLength: () => 1200, getPointAtLength: l => ({ x: l, y: 0 }) };
    const svg = { querySelector: () => path, getBoundingClientRect: () => loopBox.current };
    title.querySelector = s => s === 'svg' ? svg : null;
    title.style = { setProperty: (k, v) => { props[k] = v; } };
  }
  const doc = { querySelector: s => ({ '[data-orb]': root, '[data-orb-toggle]': button, '[data-orb-status]': status, '.typed': typed })[s] || null,
    querySelectorAll: s => s === '.circled' ? [title] : [] };
  const stream = { getTracks: () => [{ stop: () => calls.stopped++ }] };
  const mediaDevices = { getUserMedia: async () => { calls.getUserMedia++; calls.order.push('getUserMedia'); if (!grant) throw new Error('denied');
    if (hold) await new Promise(r => { release = r; }); return stream; } };
  class AudioContext { constructor() { this.state = 'running'; calls.order.push('AudioContext'); }
    createAnalyser() { return { frequencyBinCount: 4, getByteFrequencyData(b) { b.fill(loud.value); } }; }
    createMediaStreamSource() { return { connect() {}, disconnect() {} }; } close() { calls.closed++; this.state = 'closed'; } }
  let hide; const frames = [];
  const ctx = loadTry();
  const createOrb = withOrb ? (canvas, onLost) => { lost = onLost; return { frame() { calls.frames++; } }; } : () => null;
  root.querySelector = s => s === 'canvas' ? {} : null;
  const api = ctx.initTry(doc, { createOrb, createListener: ctx.createListener, mediaDevices, AudioContext,
    raf: fn => frames.push(fn), IntersectionObserver: null, reducedMotion: false, onHide: fn => { hide = fn; } });
  return { api, calls, button, status, root, title, frames, loud, typed, wordEls, props, hide: () => hide(), grantNow: () => release(), loseContext: () => lost() };
}

test('the microphone opens only from the button, and Stop or leaving gives it back', async () => {
  const t = fakeTry();
  assert.equal(t.calls.getUserMedia, 0, 'nothing asks for the microphone on load');
  assert.equal(t.button.hidden, false, 'the button shows when a microphone could work');
  assert.ok(t.root.classes.has('no-webgl'), 'no WebGL falls back to the still illustration');
  assert.ok(t.title.classes.has('drawn'), 'without IntersectionObserver the loop is simply drawn');
  await t.button.listeners.click();
  assert.equal(t.calls.getUserMedia, 1);
  assert.equal(t.button.attrs['aria-pressed'], 'true'); assert.equal(t.button.textContent, 'Stop listening');
  t.frames.at(-1)(16); assert.equal(t.status.textContent, 'Hearing you.', 'loud input is announced once');
  await t.button.listeners.click();
  assert.equal(t.calls.stopped, 1, 'the track is stopped'); assert.equal(t.calls.closed, 1, 'the audio context is closed');
  assert.equal(t.button.attrs['aria-pressed'], 'false'); assert.equal(t.status.textContent, 'Microphone off.');
  await t.button.listeners.click(); t.hide();
  assert.equal(t.calls.stopped, 2, 'leaving the page releases the microphone too');
});

test('a refused microphone leaves the orb breathing and says so', async () => {
  const t = fakeTry({ grant: false });
  await t.button.listeners.click();
  assert.match(t.status.textContent, /No microphone was shared/);
  assert.equal(t.button.attrs['aria-pressed'], undefined); assert.equal(t.button.disabled, false);
  assert.equal(t.api.listener.listening, false);
});

test('hiding the page while the permission prompt is open cancels the microphone', async () => {
  const t = fakeTry({ hold: true });
  const click = t.button.listeners.click();
  assert.deepEqual(t.calls.order, ['AudioContext', 'getUserMedia'], 'audio is set up inside the click, before the first await (Safari)');
  t.hide(); t.grantNow(); await click;
  assert.equal(t.calls.stopped, 1, 'the late stream is stopped at once');
  assert.equal(t.api.listener.listening, false);
  assert.equal(t.button.attrs['aria-pressed'], 'false'); assert.doesNotMatch(t.status.textContent, /No microphone/);
});

test('frames run only when there is something to show', async () => {
  const none = fakeTry();
  assert.equal(none.frames.length, 0, 'no orb and no microphone: no animation loop at all');
  await none.button.listeners.click();
  assert.equal(none.frames.length, 1, 'a live microphone runs the loop for the status line');
  const orb = fakeTry({ withOrb: true });
  assert.equal(orb.frames.length, 1, 'an orb on screen animates');
  orb.loseContext();
  assert.ok(orb.root.classes.has('no-webgl'), 'a lost WebGL context falls back to the still art');
  orb.frames.at(-1)(16); assert.equal(orb.calls.frames, 0, 'and nothing draws to the dead context');
});

test('the status line does not chatter between syllables', async () => {
  const t = fakeTry();
  await t.button.listeners.click();
  t.frames.at(-1)(100); assert.equal(t.status.textContent, 'Hearing you.');
  t.loud.value = 0;
  t.frames.at(-1)(900); assert.equal(t.status.textContent, 'Hearing you.', 'a short pause keeps the message');
  t.frames.at(-1)(1700); assert.equal(t.status.textContent, 'Listening. Say something, and watch the note.', '1.5 s of quiet goes back');
});

test('the note types one word per stretch of voice, and starts over after a quiet finish', () => {
  const { typeAlong } = loadTry();
  const n = { voiced: 0, quiet: 0, shown: 0 };
  typeAlong(n, 0.5, 0.4, 3); assert.equal(n.shown, 2, '0.4 s of voice is two words');
  typeAlong(n, 0.0, 1.0, 3); assert.equal(n.shown, 2, 'silence types nothing');
  typeAlong(n, 0.5, 0.2, 3); assert.equal(n.shown, 3);
  typeAlong(n, 0.5, 1.0, 3); assert.equal(n.shown, 3, 'never past the last word');
  typeAlong(n, 0.0, 2.5, 3); assert.equal(n.shown, 0, 'a finished note clears after 2 s of quiet');
});

test('the stretched loop is measured on screen, so its draw is a full line, not dots', () => {
  const { loopLength } = loadTry();
  // A straight 1200-unit line across a 600 px wide box is 600 px on screen.
  const path = { getTotalLength: () => 1200, getPointAtLength: l => ({ x: l, y: 0 }) };
  assert.ok(Math.abs(loopLength(path, { width: 600, height: 100 }, 1200, 600) - 600) < 1e-6);
  const tall = { getTotalLength: () => 600, getPointAtLength: l => ({ x: 0, y: l }) };
  assert.ok(Math.abs(loopLength(tall, { width: 600, height: 100 }, 1200, 600) - 100) < 1e-6, 'vertical runs scale by the height');
  assert.match(css, /stroke-dasharray:var\(--loop\)/);
});

test('talking types the note word by word; Stop keeps what was said, or brings the sample back', async () => {
  const t = fakeTry({ words: 4 });
  await t.button.listeners.click();
  assert.ok(t.typed.classList.contains('live'), 'the note goes live: the sample is hidden');
  assert.equal(t.wordEls.filter(w => w.classList.contains('on')).length, 0);
  t.frames.at(-1)(0); t.frames.at(-1)(100); t.frames.at(-1)(200); t.frames.at(-1)(300); t.frames.at(-1)(400);
  assert.equal(t.wordEls.filter(w => w.classList.contains('on')).length, 2, '0.4 s of voice shows two words');
  await t.button.listeners.click();
  assert.ok(t.typed.classList.contains('live'), 'Stop keeps the two words you said');
  const quiet = fakeTry({ words: 4 });
  await quiet.button.listeners.click(); await quiet.button.listeners.click();
  assert.equal(quiet.typed.classList.contains('live'), false, 'nothing said: the sample sentence comes back');
});

test('the loop length is written to --loop, and never as 0 before layout', () => {
  const box = { current: { width: 0, height: 0 } };
  const t = fakeTry({ loopBox: box });
  assert.equal(t.props['--loop'], undefined, 'an unlaid-out box writes nothing, so the loop stays drawn');
  box.current = { width: 600, height: 100 };
  const again = fakeTry({ loopBox: box });
  assert.equal(again.props['--loop'], '600.0px');
  assert.doesNotMatch(html, /pathLength=/, 'one length system: no pathLength on the measured loop');
});
