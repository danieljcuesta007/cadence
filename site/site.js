// Cadence site: staggered words in the hero demo and copy buttons.
// No network, no storage. Without this script the page still reads fully.

function staggerWords(words, stepMs) {
  words.forEach((w, i) => { w.style.animationDelay = (0.6 + i * stepMs / 1000).toFixed(2) + 's'; });
}

// Every click copies the same text, so one success is enough: show "Copied" as soon
// any copy lands, and "Copy failed" only when every copy still pending has failed.
function initCopy(button, clipboard) {
  const label = button.textContent;
  let timer, pending = 0, copied = false;
  const show = text => {
    button.textContent = text;
    clearTimeout(timer);
    timer = setTimeout(() => { button.textContent = label; copied = false; }, 1600);
  };
  button.addEventListener('click', async () => {
    pending++;
    let ok = true;
    try { await clipboard.writeText(button.dataset.copy); } catch { ok = false; }
    pending--;
    if (ok) { copied = true; show('Copied'); }
    else if (!copied && pending === 0) show('Copy failed');
  });
}

if (typeof document !== 'undefined' && document.querySelectorAll) {
  staggerWords([...document.querySelectorAll('.typed .w')], 170);
  const clipboard = typeof navigator !== 'undefined' && navigator.clipboard;
  document.querySelectorAll('[data-copy]').forEach(b => clipboard ? initCopy(b, clipboard) : b.remove());
}
