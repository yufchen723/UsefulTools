// Mouse handling for the Electron build: drag, double-click, right-click menu, scroll/pinch resize, card clicks.
(() => {
  const M = window.monitor;
  if (!M) return;
  const ORB_H = 178;
  const inOrb = (e) => e.clientY < ORB_H;

  let dragging = false, moved = false, downAt = null, downTarget = null;
  document.addEventListener('mousedown', (e) => {
    if (e.button === 2) return;
    if (e.button !== 0) return;
    downAt = { x: e.clientX, y: e.clientY };
    downTarget = e.target;
    moved = false;
    if (inOrb(e)) {
      dragging = true;
      // Electron positions windows in DIP; page CSS px × zoomFactor = DIP.
      const zoom = (window.outerWidth && document.documentElement.clientWidth) ? window.outerWidth / document.documentElement.clientWidth : 1;
      M.dragStart(e.clientX * zoom, e.clientY * zoom);
      e.preventDefault();
    }
  });
  document.addEventListener('mousemove', (e) => {
    if (downAt && Math.hypot(e.clientX - downAt.x, e.clientY - downAt.y) > 4) moved = true;
  });
  document.addEventListener('mouseup', (e) => {
    if (dragging) { dragging = false; M.dragEnd(); }
    if (e.button === 0 && downAt && !moved && !inOrb(e) && window.orbClickAt) {
      const r = window.orbClickAt(e.clientX, e.clientY);
      if (r) { const o = JSON.parse(r); M.card(o.id, o.action); }
    }
    downAt = null;
  });
  window.addEventListener('blur', () => { if (dragging) { dragging = false; M.dragEnd(); } });
  document.addEventListener('dblclick', (e) => { if (inOrb(e)) M.doubleClick(); });
  document.addEventListener('contextmenu', (e) => { e.preventDefault(); M.menu(); });
  document.addEventListener('wheel', (e) => {
    if (!inOrb(e)) return;
    e.preventDefault();
    let dy = -e.deltaY;                  // wheel up = bigger
    if (e.deltaMode === 1) dy *= 16;
    if (Math.abs(dy) > 60) dy = Math.sign(dy) * 60;
    M.resize(Math.min(1.2, Math.max(0.83, 1 + dy * 0.004)));
  }, { passive: false });
  document.addEventListener('mouseenter', () => window.orbHover && window.orbHover(true));
  document.addEventListener('mouseleave', () => window.orbHover && window.orbHover(false));
  document.addEventListener('selectstart', (e) => e.preventDefault());
})();
