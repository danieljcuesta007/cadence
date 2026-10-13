// Cadence site: staggered words in the hero demo and copy buttons.
// No network, no storage. Without this script the page still reads fully.

function staggerWords(words, stepMs) {
  words.forEach((w, i) => { w.style.animationDelay = (0.6 + i * stepMs / 1000).toFixed(2) + 's'; });
}

// Every click copies the same text, so a failure only matters if no copy has
// succeeded since that click began. On a real failure the command is selected,
// so Command-C still works. Results are announced once through the status line.
function initCopy(button, clipboard, status, select, now = Date.now) {
  const label = button.textContent;
  let timer, lastSuccess = -Infinity;
  const show = (text, said) => {
    button.textContent = text;
    if (status) status.textContent = said;
    clearTimeout(timer);
    timer = setTimeout(() => { button.textContent = label; }, 1600);
  };
  button.addEventListener('click', async () => {
    const started = now();
    try {
      await clipboard.writeText(button.dataset.copy);
      lastSuccess = now();
      show('Copied', 'Copied to clipboard');
    } catch {
      if (lastSuccess >= started) return; // another click already put it on the clipboard
      const code = button.previousElementSibling;
      if (code && select) select(code);
      show('Press \u2318C', 'Copy failed. The command is selected; press Command C.');
    }
  });
}

if (typeof document !== 'undefined' && document.querySelectorAll) {
  staggerWords([...document.querySelectorAll('.typed .w')], 170);
  const clipboard = typeof navigator !== 'undefined' && navigator.clipboard;
  const status = document.querySelector && document.querySelector('[data-copy-status]');
  const select = el => { const sel = typeof getSelection === 'function' && getSelection(); if (sel) sel.selectAllChildren(el); };
  document.querySelectorAll('[data-copy]').forEach(b => clipboard ? initCopy(b, clipboard, status, select) : b.remove());
}
