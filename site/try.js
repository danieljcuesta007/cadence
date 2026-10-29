// Cadence site: the live demo in the hero. A hand-drawn loop around "Nothing leaves your Mac",
// and a voice orb beside the Notes window: while you talk, the orb swells and the note types. The microphone is opt-in (a button), the analyser reads
// loudness only, and nothing is recorded, stored or sent. Stop releases the microphone.
// Without WebGL the orb is a still illustration; without JavaScript the loop is already drawn.

// Loudness 0..1 from analyser bytes: RMS, boosted so ordinary speech moves the orb.
function voiceLevel(bins, sensitivity) {
  if (!bins || !bins.length) return 0;
  let sum = 0;
  for (let i = 0; i < bins.length; i++) { const v = bins[i] / 255; sum += v * v; }
  return Math.min(Math.sqrt(sum / bins.length) * sensitivity * 3, 1);
}

// The demo note: one more word for every WORD_SECONDS of voice, so the note fills as you talk.
// The browser only hears loudness, so it types the sample sentence; the app types your words.
const WORD_SECONDS = 0.18;
const VOICE = 0.12; // loudness that counts as talking
function typeAlong(state, level, dt, total) {
  if (level > VOICE) { state.voiced += dt; state.quiet = 0; } else state.quiet += dt;
  while (state.voiced >= WORD_SECONDS && state.shown < total) { state.shown++; state.voiced -= WORD_SECONDS; }
  if (state.shown >= total && state.quiet > 2) { state.shown = 0; state.voiced = 0; } // finished and quiet: start a fresh note
  return state;
}

// On-screen length of the stretched loop. Its stroke doesn't scale, so the browser dashes it in
// screen pixels: sample the path and scale each step by how much the line box stretches it.
function loopLength(path, box, viewW, viewH) {
  const sx = box.width / viewW, sy = box.height / viewH, total = path.getTotalLength();
  let len = 0, prev = path.getPointAtLength(0);
  for (let i = 1; i <= 120; i++) {
    const p = path.getPointAtLength(total * i / 120);
    len += Math.hypot((p.x - prev.x) * sx, (p.y - prev.y) * sy); prev = p;
  }
  return len;
}

// Spin and wobble for one frame: the orb only turns while it hears you.
function orbMotion(state, level, dt, maxRotationSpeed, maxHoverIntensity) {
  if (level > 0.05) state.rot += dt * (0.3 + level * maxRotationSpeed * 2);
  state.hover = Math.min(level * 2, 1);
  state.hoverIntensity = Math.min(level * maxHoverIntensity * 0.8, maxHoverIntensity);
  return state;
}

const ORB_VERT = `
attribute vec2 position;
varying vec2 vUv;
void main() { vUv = position * 0.5 + 0.5; gl_Position = vec4(position, 0.0, 1.0); }`;

// The orb shader, recoloured into the Cadence inks (pink, cobalt, red) and printed with
// the same speckle as the art, so it reads as ink on paper rather than a glow on glass.
const ORB_FRAG = `
precision highp float;
uniform float iTime; uniform vec3 iResolution; uniform float hover; uniform float rot; uniform float hoverIntensity;
varying vec2 vUv;
vec3 hash33(vec3 p3) {
  p3 = fract(p3 * vec3(0.1031, 0.11369, 0.13787));
  p3 += dot(p3, p3.yxz + 19.19);
  return -1.0 + 2.0 * fract(vec3(p3.x + p3.y, p3.x + p3.z, p3.y + p3.z) * p3.zyx);
}
float snoise3(vec3 p) {
  const float K1 = 0.333333333; const float K2 = 0.166666667;
  vec3 i = floor(p + (p.x + p.y + p.z) * K1);
  vec3 d0 = p - (i - (i.x + i.y + i.z) * K2);
  vec3 e = step(vec3(0.0), d0 - d0.yzx);
  vec3 i1 = e * (1.0 - e.zxy); vec3 i2 = 1.0 - e.zxy * (1.0 - e);
  vec3 d1 = d0 - (i1 - K2); vec3 d2 = d0 - (i2 - K1); vec3 d3 = d0 - 0.5;
  vec4 h = max(0.6 - vec4(dot(d0, d0), dot(d1, d1), dot(d2, d2), dot(d3, d3)), 0.0);
  vec4 n = h * h * h * h * vec4(dot(d0, hash33(i)), dot(d1, hash33(i + i1)), dot(d2, hash33(i + i2)), dot(d3, hash33(i + 1.0)));
  return dot(vec4(31.316), n);
}
const vec3 pink = vec3(0.949, 0.635, 0.749);
const vec3 cobalt = vec3(0.141, 0.263, 0.769);
const vec3 red = vec3(0.925, 0.290, 0.196);
const float innerRadius = 0.6;
const float noiseScale = 0.65;
float light1(float i, float a, float d) { return i / (1.0 + d * a); }
float light2(float i, float a, float d) { return i / (1.0 + d * d * a); }
vec4 draw(vec2 uv) {
  float ang = atan(uv.y, uv.x);
  float len = length(uv);
  float invLen = len > 0.0 ? 1.0 / len : 0.0;
  float n0 = snoise3(vec3(uv * noiseScale, iTime * 0.5)) * 0.5 + 0.5;
  float r0 = mix(mix(innerRadius, 1.0, 0.4), mix(innerRadius, 1.0, 0.6), n0);
  float d0 = distance(uv, (r0 * invLen) * uv);
  float v0 = light1(1.0, 10.0, d0) * smoothstep(r0 * 1.05, r0, len);
  float cl = cos(ang + iTime * 2.0) * 0.5 + 0.5;
  float a = iTime * -1.0;
  vec2 pos = vec2(cos(a), sin(a)) * r0;
  float d = distance(uv, pos);
  float v1 = light2(1.5, 5.0, d) * light1(1.0, 50.0, d0);
  float v2 = smoothstep(1.0, mix(innerRadius, 1.0, n0 * 0.5), len);
  float v3 = smoothstep(innerRadius, mix(innerRadius, 1.0, 0.5), len);
  // Ink amounts instead of light: the ring is pink turning to cobalt, the travelling spark is red.
  float ink = clamp(v0 * v2 * v3 * (1.7 + hover * 1.2), 0.0, 1.0); // your voice darkens the ink
  vec3 col = mix(pink, cobalt, cl);
  float spark = clamp(v1 * v2 * v3, 0.0, 1.0);
  col = mix(col, red, spark * 0.85);
  float alpha = clamp(ink + spark * 0.6, 0.0, 1.0);
  return vec4(col, alpha);
}
float grain(vec2 p) { return fract(sin(dot(floor(p), vec2(12.9898, 78.233))) * 43758.5453); }
void main() {
  vec2 fragCoord = vUv * iResolution.xy;
  vec2 uv = (fragCoord - iResolution.xy * 0.5) / min(iResolution.x, iResolution.y) * 2.0;
  float s = sin(rot); float c = cos(rot);
  uv = vec2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
  uv.x += hover * hoverIntensity * 0.1 * sin(uv.y * 10.0 + iTime);
  uv.y += hover * hoverIntensity * 0.1 * sin(uv.x * 10.0 + iTime);
  vec4 col = draw(uv);
  // Riso speckle: the same curve as the art's #grain filter, fixed to the paper, not the frame.
  float speck = clamp(2.3 - 2.6 * grain(fragCoord / max(iResolution.z, 1.0)), 0.0, 1.0);
  float a = col.a * speck;
  gl_FragColor = vec4(col.rgb * a, a);
}`;

// Returns { frame(time, motion) } or null when WebGL or the shader is unavailable.
function createOrb(canvas, onLost) {
  const gl = canvas.getContext && (canvas.getContext('webgl', { alpha: true, premultipliedAlpha: true, antialias: true }) || canvas.getContext('experimental-webgl'));
  if (!gl) return null;
  if (canvas.addEventListener && onLost) canvas.addEventListener('webglcontextlost', onLost);
  const compile = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null; };
  const vs = compile(gl.VERTEX_SHADER, ORB_VERT), fs = compile(gl.FRAGMENT_SHADER, ORB_FRAG);
  if (!vs || !fs) return null;
  const program = gl.createProgram();
  gl.attachShader(program, vs); gl.attachShader(program, fs); gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
  gl.useProgram(program);
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW); // one triangle covers the view
  const position = gl.getAttribLocation(program, 'position');
  gl.enableVertexAttribArray(position);
  gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
  const u = name => gl.getUniformLocation(program, name);
  const uTime = u('iTime'), uRes = u('iResolution'), uHover = u('hover'), uRot = u('rot'), uIntensity = u('hoverIntensity');
  return {
    frame(time, motion) {
      const dpr = window.devicePixelRatio || 1;
      const w = Math.round(canvas.clientWidth * dpr), h = Math.round(canvas.clientHeight * dpr);
      if (!w || !h) return;
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      gl.viewport(0, 0, w, h);
      gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
      gl.uniform1f(uTime, time); gl.uniform3f(uRes, w, h, dpr);
      gl.uniform1f(uHover, motion.hover); gl.uniform1f(uRot, motion.rot); gl.uniform1f(uIntensity, motion.hoverIntensity);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    },
  };
}

// The microphone, opened only from the button. Loudness only: the stream feeds an analyser and
// is never connected to the speakers, recorded or sent. stop() releases every track.
function createListener(mediaDevices, AudioContextClass) {
  let stream = null, context = null, source = null, analyser = null, bins = null, turn = 0;
  const release = () => {
    if (stream) stream.getTracks().forEach(track => track.stop());
    if (source) source.disconnect();
    if (context && context.state !== 'closed' && context.close) context.close();
    stream = context = source = analyser = bins = null;
  };
  return {
    get listening() { return !!analyser; },
    // Resolves true (listening), false (no microphone) or null (cancelled by stop() while asking).
    // The audio context is made before the first await, inside the click, so Safari lets it run.
    async start() {
      if (!mediaDevices || !mediaDevices.getUserMedia || !AudioContextClass) return false;
      const mine = ++turn;
      try {
        context = new AudioContextClass();
        if (context.state === 'suspended' && context.resume) context.resume().catch(() => {});
        const granted = await mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
        if (mine !== turn) { granted.getTracks().forEach(track => track.stop()); return null; } // hidden or stopped while asking
        stream = granted;
        analyser = context.createAnalyser();
        analyser.fftSize = 512; analyser.smoothingTimeConstant = 0.3; analyser.minDecibels = -90; analyser.maxDecibels = -10;
        source = context.createMediaStreamSource(stream);
        source.connect(analyser);
        bins = new Uint8Array(analyser.frequencyBinCount);
        return true;
      } catch { if (mine === turn) release(); return mine === turn ? false : null; }
    },
    level(sensitivity) {
      if (!analyser) return 0;
      analyser.getByteFrequencyData(bins);
      return voiceLevel(bins, sensitivity);
    },
    stop() { turn++; release(); },
  };
}

const TRY_TEXT = {
  idle: 'Try it with your voice',
  stop: 'Stop listening',
  listening: 'Listening. Say something, and watch the note.',
  hearing: 'Hearing you.',
  denied: 'No microphone was shared, so the orb is just breathing. That is fine too.',
  stopped: 'Microphone off.',
};

function initTry(doc, env) {
  const root = doc.querySelector('[data-orb]');
  const button = doc.querySelector('[data-orb-toggle]');
  const status = doc.querySelector('[data-orb-status]');
  const canvas = root && root.querySelector('canvas');
  const typed = doc.querySelector('.typed');
  const words = typed && typed.querySelectorAll ? [...typed.querySelectorAll('.w')] : [];
  const note = { voiced: 0, quiet: 0, shown: 0 };
  const showWords = n => words.forEach((w, i) => w.classList.toggle('on', i < n));
  const fallBack = () => { orb = null; if (root) root.classList.add('no-webgl'); };
  let orb = canvas ? env.createOrb(canvas, fallBack) : null;
  if (!orb) fallBack();
  const listener = env.createListener(env.mediaDevices, env.AudioContext);
  const motion = { rot: 0, hover: 0, hoverIntensity: 0 };
  const still = env.reducedMotion;
  let last = null, rafId = 0, heard = false, loudAt = -Infinity, onScreen = !env.IntersectionObserver;
  const say = text => { if (status && status.textContent !== text) status.textContent = text; };
  // Frames run only while there is something to show: the orb on screen and moving, or a live mic.
  const wanted = () => listener.listening || (!!orb && onScreen && !still);
  const schedule = () => { if (!rafId && (wanted() || (orb && onScreen))) rafId = env.raf(tick); };
  function tick(t) {
    rafId = 0;
    const dt = last === null ? 0 : Math.min((t - last) / 1000, 0.1); last = t;
    const level = listener.level(1.5);
    orbMotion(motion, level, dt, 1.2, 0.8);
    if (orb) orb.frame(still ? 1.5 : t / 1000, motion);
    // Announce sparingly: "Hearing you" once you get loud, back to "Listening" after 1.5 s of quiet.
    if (listener.listening) {
      const before = note.shown;
      typeAlong(note, level, dt, words.length);
      if (note.shown !== before) showWords(note.shown);
      if (level > VOICE) loudAt = t;
      const now = t - loudAt < 1500;
      if (now !== heard) { heard = now; say(now ? TRY_TEXT.hearing : TRY_TEXT.listening); }
    }
    if (wanted()) rafId = env.raf(tick);
  }
  const setButton = on => { if (!button) return; button.textContent = on ? TRY_TEXT.stop : TRY_TEXT.idle; button.setAttribute('aria-pressed', on ? 'true' : 'false'); };
  // Stop keeps the words you "said"; if you said nothing, the sample sentence comes back.
  const stop = message => { listener.stop(); if (typed && note.shown === 0) typed.classList.remove('live'); heard = false; loudAt = -Infinity; setButton(false); if (button) button.disabled = false; if (message) say(message); };
  // The button only appears where a microphone could actually work.
  if (button && env.mediaDevices && env.mediaDevices.getUserMedia && env.AudioContext) button.hidden = false;
  if (button) button.addEventListener('click', async () => {
    if (listener.listening) return stop(TRY_TEXT.stopped);
    button.disabled = true;
    const ok = await listener.start();
    button.disabled = false;
    if (ok === null) return;           // cancelled while asking (page hidden): stay quiet
    if (!ok) return say(TRY_TEXT.denied);
    setButton(true); say(TRY_TEXT.listening);
    note.voiced = note.quiet = note.shown = 0; showWords(0);
    if (typed) typed.classList.add('live');
    schedule();
  });
  // Leaving or hiding the page always gives the microphone back, even mid-permission-prompt.
  if (env.onHide) env.onHide(() => { const was = listener.listening; stop(was ? TRY_TEXT.stopped : ''); });
  if (root && env.IntersectionObserver) new env.IntersectionObserver(entries => { onScreen = entries.some(e => e.isIntersecting); schedule(); }).observe(root);
  if (canvas && env.ResizeObserver) new env.ResizeObserver(() => schedule()).observe(canvas);
  schedule();
  // The loop draws itself when the line scrolls into view (already drawn without JS).
  doc.querySelectorAll('.circled').forEach(el => {
    const svg = el.querySelector && el.querySelector('svg'), path = svg && svg.querySelector('path');
    const measure = () => {
      if (!path || !path.getTotalLength || !el.style) return;
      const box = svg.getBoundingClientRect();
      if (!box.width || !box.height) return; // not laid out yet: keep the last length (or none: drawn)
      el.style.setProperty('--loop', loopLength(path, box, 1200, 600).toFixed(1) + 'px');
    };
    measure();
    if (svg && env.ResizeObserver) new env.ResizeObserver(measure).observe(svg);
    if (env.fontsReady) env.fontsReady.then(measure, () => {});
    if (env.onResize) env.onResize(measure);
    el.classList.add('armed');
    if (still || !env.IntersectionObserver) return el.classList.add('drawn');
    const io = new env.IntersectionObserver(entries => entries.forEach(e => { if (e.isIntersecting) { el.classList.add('drawn'); io.disconnect(); } }), { threshold: 0.4 });
    io.observe(el);
  });
  return { listener, motion, stop };
}

if (typeof document !== 'undefined' && document.querySelector && document.querySelector('[data-orb]')) {
  initTry(document, {
    createOrb, createListener,
    mediaDevices: typeof navigator !== 'undefined' ? navigator.mediaDevices : null,
    AudioContext: typeof window !== 'undefined' ? (window.AudioContext || window.webkitAudioContext) : null,
    raf: fn => requestAnimationFrame(fn),
    IntersectionObserver: typeof IntersectionObserver !== 'undefined' ? IntersectionObserver : null,
    ResizeObserver: typeof ResizeObserver !== 'undefined' ? ResizeObserver : null,
    fontsReady: document.fonts && document.fonts.ready,
    onResize: fn => addEventListener('resize', fn),
    reducedMotion: typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches,
    onHide: fn => { addEventListener('pagehide', fn); document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') fn(); }); },
  });
}
