// Cadence site: staggered words in the hero demo and copy buttons.
// No network, no storage. Without this script the page still reads fully.

function staggerWords(words, stepMs) {
  words.forEach((w, i) => { w.style.animationDelay = (0.6 + i * stepMs / 1000).toFixed(2) + 's'; });
}

function initCopy(button, clipboard) {
  const label = button.textContent; // read once, so a double click can't save "Copied" as the label
  button.addEventListener('click', async () => {
    try { await clipboard.writeText(button.dataset.copy); button.textContent = 'Copied'; }
    catch { button.textContent = 'Select and copy'; }
    setTimeout(() => { button.textContent = label; }, 1600);
  });
}

if (typeof document !== 'undefined' && document.querySelectorAll) {
  staggerWords([...document.querySelectorAll('.typed .w')], 170);
  const clipboard = typeof navigator !== 'undefined' && navigator.clipboard;
  document.querySelectorAll('[data-copy]').forEach(b => clipboard ? initCopy(b, clipboard) : b.remove());
}
