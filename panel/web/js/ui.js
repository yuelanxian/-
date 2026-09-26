// DOM + formatting helpers. No innerHTML with dynamic data: everything goes through textContent.

const SVG_NS = 'http://www.w3.org/2000/svg';

const ICONS = {
  overview: 'M3 11.5 12 4l9 7.5M5.5 10v10h13V10M10 20v-5h4v5',
  storage: 'M4 6c0-1.7 3.6-3 8-3s8 1.3 8 3-3.6 3-8 3-8-1.3-8-3zM4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3',
  backup: 'M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5M12 7v5l3 3',
  logs: 'M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9zM14 3v6h6M8 13h8M8 17h6',
  vpn: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4',
  settings: 'M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6',
  refresh: 'M21 4v6h-6M3 20v-6h6M5.5 9A7.5 7.5 0 0 1 18 6.5L21 10M3 14l3 3.5A7.5 7.5 0 0 0 18.5 15',
  back: 'M15 18l-6-6 6-6',
  download: 'M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3',
  restart: 'M21 4v6h-6M20 15a8.5 8.5 0 1 1-2-9L21 10',
  logout: 'M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9',
  search: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM21 21l-4.3-4.3',
  chevron: 'M9 18l6-6-6-6',
  alert: 'M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
  check: 'M20 6 9 17l-5-5',
  info: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 16v-4M12 8h.01',
  phone: 'M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2',
  cert: 'M12 15a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM9 14l-2 7 5-3 5 3-2-7',
  bottom: 'M12 5v14M5 12l7 7 7-7',
  cloud: 'M18 10h-1.3A7 7 0 1 0 9 19h9a4.5 4.5 0 0 0 0-9z',
};

export function icon(name, cls = '') {
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('class', ('icon ' + cls).trim());
  const p = document.createElementNS(SVG_NS, 'path');
  p.setAttribute('d', ICONS[name] || ICONS.info);
  svg.appendChild(p);
  return svg;
}

// h('div.card', {onclick}, child, 'text', [children...])
export function h(tag, attrs, ...children) {
  const [name, ...classes] = tag.split('.');
  const el = document.createElement(name || 'div');
  if (classes.length) el.className = classes.join(' ');
  if (attrs && (typeof attrs !== 'object' || attrs instanceof Node || Array.isArray(attrs))) {
    children.unshift(attrs);
    attrs = null;
  }
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'class') el.className = (el.className ? el.className + ' ' : '') + v;
    else if (k === 'text') el.textContent = v;
    else if (k === 'dataset') Object.assign(el.dataset, v);
    else if (k === 'style') throw new Error('inline style attributes are not allowed (CSP)');
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, String(v));
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    if (Array.isArray(c)) append(el, c);
    else if (c instanceof Node) el.appendChild(c);
    else el.appendChild(document.createTextNode(String(c)));
  }
}

export function clear(el) {
  while (el.firstChild) el.removeChild(el.firstChild);
  return el;
}

export function fmtBytes(n) {
  if (n === null || n === undefined || Number.isNaN(n)) return '—';
  n = Number(n);
  if (n < 0) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i === 0 ? n.toFixed(0) : n >= 100 ? n.toFixed(0) : n.toFixed(1)) + ' ' + u[i];
}

export function fmtNum(n) {
  if (n === null || n === undefined) return '—';
  return Number(n).toLocaleString('zh-CN');
}

function toDate(v) {
  if (!v) return null;
  const d = v instanceof Date ? v : new Date(v);
  return Number.isNaN(d.getTime()) || d.getFullYear() < 2000 ? null : d;
}

export function fmtTime(v) {
  const d = toDate(v);
  if (!d) return '—';
  const p = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

export function relTime(v) {
  const d = toDate(v);
  if (!d) return '从未';
  const s = Math.round((Date.now() - d.getTime()) / 1000);
  const a = Math.abs(s);
  const suffix = s >= 0 ? '前' : '后';
  if (a < 45) return s >= 0 ? '刚刚' : '即将';
  if (a < 3600) return `${Math.round(a / 60)} 分钟${suffix}`;
  if (a < 86400) return `${Math.round(a / 3600)} 小时${suffix}`;
  if (a < 86400 * 60) return `${Math.round(a / 86400)} 天${suffix}`;
  return fmtTime(d);
}

export function fmtDuration(sec) {
  sec = Math.max(0, Math.round(Number(sec) || 0));
  const d = Math.floor(sec / 86400), hh = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  if (d > 0) return `${d} 天 ${hh} 小时`;
  if (hh > 0) return `${hh} 小时 ${m} 分`;
  if (m > 0) return `${m} 分 ${s} 秒`;
  return `${s} 秒`;
}

export function uptime(startedAt) {
  const d = toDate(startedAt);
  if (!d) return '';
  return '已运行 ' + fmtDuration((Date.now() - d.getTime()) / 1000);
}

export function usageClass(pct) {
  if (pct >= 90) return 'err';
  if (pct >= 80) return 'warn';
  return 'ok';
}

export function bar(pct, cls = '') {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  const inner = h('span');
  inner.style.width = p + '%'; // CSSOM: allowed under CSP style-src 'self'
  const el = h('div.bar', { class: cls || usageClass(p), role: 'progressbar', 'aria-valuenow': Math.round(p), 'aria-valuemin': 0, 'aria-valuemax': 100 }, inner);
  return el;
}

export function spinner() {
  return h('div.loading', h('div.spinner'));
}

export function errorBox(msg, onRetry) {
  return h('div.alert.err', icon('alert'), h('div.grow', msg),
    onRetry ? h('button.btn.sm', { type: 'button', onclick: onRetry }, '重试') : null);
}

export function toast(msg, kind = '') {
  const host = document.getElementById('toasts');
  const t = h('div.toast', { class: kind, role: 'status' }, msg);
  host.appendChild(t);
  setTimeout(() => t.remove(), kind === 'err' ? 6000 : 3500);
}

// Promise-based confirm dialog (window.confirm is unreliable inside Android WebView).
export function confirmDialog({ title, message, ok = '确定', cancel = '取消', danger = false }) {
  return new Promise((resolve) => {
    const close = (v) => { back.remove(); document.removeEventListener('keydown', onKey); resolve(v); };
    const onKey = (e) => { if (e.key === 'Escape') close(false); };
    const okBtn = h('button.btn.primary', { type: 'button', class: danger ? 'danger-bg' : '', onclick: () => close(true) }, ok);
    const back = h('div.modal-back', { onclick: (e) => { if (e.target === back) close(false); } },
      h('div.modal', { role: 'dialog', 'aria-modal': 'true' },
        h('h3', title),
        message ? (Array.isArray(message) ? message.map((m) => h('p', m)) : h('p', message)) : null,
        h('div.btn-row', h('button.btn', { type: 'button', onclick: () => close(false) }, cancel), okBtn)));
    document.body.appendChild(back);
    document.addEventListener('keydown', onKey);
    okBtn.focus();
  });
}

export function pageTitle(text, ...actions) {
  return h('div.page-title', h('h2', text), ...actions);
}

export function badgeForState(state, health) {
  if (state !== 'running') {
    const txt = { exited: '已停止', restarting: '重启中', paused: '已暂停', created: '未启动', dead: '已失效' }[state] || state || '未知';
    return h('span.badge.err', txt);
  }
  if (health === 'unhealthy') return h('span.badge.err', '异常');
  if (health === 'starting') return h('span.badge.warn', '启动中');
  if (health === 'healthy') return h('span.badge.ok', '健康');
  return h('span.badge.ok', '运行中');
}

export function stateDot(state, health) {
  let cls = 'ok';
  if (state !== 'running' || health === 'unhealthy') cls = 'err';
  else if (health === 'starting') cls = 'warn';
  return h('span.dot-state', { class: cls });
}

export function kv(pairs) {
  const dl = h('dl.kv');
  for (const [k, v] of pairs) {
    if (v === undefined || v === null || v === '') continue;
    dl.appendChild(h('dt', k));
    dl.appendChild(h('dd', v));
  }
  return dl;
}

export function storageGet(k, def) {
  try { const v = localStorage.getItem(k); return v === null ? def : v; } catch { return def; }
}

export function applyTheme() {
  const t = storageGet('hv-theme', 'auto');
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
  else delete document.documentElement.dataset.theme;
}

export function storageSet(k, v) {
  try { localStorage.setItem(k, v); } catch { /* private mode */ }
}

// Draws a QR code for text on a canvas using the vendored qrcode-generator (MIT).
export function qrCanvas(text) {
  const lib = window.qrcode;
  if (typeof lib !== 'function') return null;
  if (lib.stringToBytesFuncs && lib.stringToBytesFuncs['UTF-8']) lib.stringToBytes = lib.stringToBytesFuncs['UTF-8'];
  const qr = lib(0, 'M');
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  const scale = Math.max(4, Math.floor(360 / (n + 8)));
  const size = (n + 8) * scale;
  const c = document.createElement('canvas');
  c.width = size; c.height = size;
  const ctx = c.getContext('2d');
  ctx.fillStyle = '#ffffff';
  ctx.fillRect(0, 0, size, size);
  ctx.fillStyle = '#000000';
  for (let r = 0; r < n; r++) {
    for (let col = 0; col < n; col++) {
      if (qr.isDark(r, col)) ctx.fillRect((col + 4) * scale, (r + 4) * scale, scale, scale);
    }
  }
  c.setAttribute('role', 'img');
  c.setAttribute('aria-label', '二维码：' + text);
  return c;
}
