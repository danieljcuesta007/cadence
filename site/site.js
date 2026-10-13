// Cadence site: staggered words in the hero demo and copy buttons.
// No network, no storage. Without this script the page still reads fully.

function staggerWords(words, stepMs) {
  words.forEach((w, i) => { w.style.animationDelay = (0.6 + i * stepMs / 1000).toFixed(2) + 's'; });
}

function initCopy(button, clipboard) {
  const label = button.textContent; // read once, so a double click can't save "Copied" as the label
  let timer, latest = 0;
  button.addEventListener('click', async () => {
    const mine = ++latest;   // only the newest click may change the button
    clearTimeout(timer);
    button.textContent = label; // never left saying "Copied" for a write that hasn't happened
    let text = 'Copied';
    try { await clipboard.writeText(button.dataset.copy); } catch { text = 'Select and copy'; }
    if (mine !== latest) return; // a newer click took over while this write was pending
    button.textContent = text;
    timer = setTimeout(() => { button.textContent = label; }, 1600);
  });
}

if (typeof document !== 'undefined' && document.querySelectorAll) {
  staggerWords([...document.querySelectorAll('.typed .w')], 170);
  const clipboard = typeof navigator !== 'undefined' && navigator.clipboard;
  document.querySelectorAll('[data-copy]').forEach(b => clipboard ? initCopy(b, clipboard) : b.remove());
}
