// Shared light/dark theme toggle for PC-Logger dashboard pages.
// Persists choice in localStorage under 'pclogger-theme' ('dark' | 'light').
(function () {
  const STORAGE_KEY = 'pclogger-theme';

  function applyTheme(theme) {
    if (theme === 'light') {
      document.documentElement.setAttribute('data-theme', 'light');
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
  }

  function currentTheme() {
    return document.documentElement.getAttribute('data-theme') === 'light' ? 'light' : 'dark';
  }

  // Apply saved theme as early as possible (before paint) to avoid flash.
  const saved = localStorage.getItem(STORAGE_KEY);
  if (saved) applyTheme(saved);

  document.addEventListener('DOMContentLoaded', () => {
    const btn = document.getElementById('themeToggle');
    if (!btn) return;

    function updateLabel() {
      btn.textContent = currentTheme() === 'light' ? 'Light mode' : 'Dark mode';
    }
    updateLabel();

    btn.addEventListener('click', () => {
      const next = currentTheme() === 'light' ? 'dark' : 'light';
      applyTheme(next);
      localStorage.setItem(STORAGE_KEY, next);
      updateLabel();
    });
  });
})();
