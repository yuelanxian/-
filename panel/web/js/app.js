// HomeVault 管理面板 — app shell, hash router and session handling.
import { api, setCsrf } from './api.js';
import { h, clear, icon, toast, confirmDialog, errorBox, spinner, applyTheme } from './ui.js';
import * as overview from './pages/overview.js';
import * as storage from './pages/storage.js';
import * as backup from './pages/backup.js';
import * as logs from './pages/logs.js';
import * as vpn from './pages/vpn.js';
import * as settings from './pages/settings.js';
import { renderLogin } from './pages/login.js';

const PAGES = [
  { id: 'overview', label: '概览', icon: 'overview', mod: overview },
  { id: 'storage', label: '存储', icon: 'storage', mod: storage },
  { id: 'backup', label: '备份', icon: 'backup', mod: backup },
  { id: 'logs', label: '日志', icon: 'logs', mod: logs },
  { id: 'vpn', label: 'VPN', icon: 'vpn', mod: vpn },
  { id: 'settings', label: '设置', icon: 'settings', mod: settings },
];

const state = { me: null, cleanup: null, page: null };
const $ = (id) => document.getElementById(id);

function parseHash() {
  const raw = location.hash.replace(/^#\/?/, '');
  const qi = raw.indexOf('?');
  const path = qi >= 0 ? raw.slice(0, qi) : raw;
  const query = qi >= 0 ? raw.slice(qi + 1) : '';
  const parts = path.split('/').filter(Boolean).map((p) => {
    try { return decodeURIComponent(p); } catch { return p; }
  });
  return { page: parts[0] || 'overview', rest: parts.slice(1), params: new URLSearchParams(query) };
}

export function navigate(page, params) {
  const q = params ? new URLSearchParams(params).toString() : '';
  const target = '#/' + page + (q ? '?' + q : '');
  if (location.hash === target) route();
  else location.hash = target;
}

function runCleanup() {
  if (typeof state.cleanup === 'function') {
    try { state.cleanup(); } catch { /* ignore */ }
  }
  state.cleanup = null;
}

function buildTabs() {
  const nav = clear($('tabs'));
  for (const p of PAGES) {
    nav.appendChild(h('a', { href: '#/' + p.id, dataset: { page: p.id } },
      h('span.dot', icon(p.icon)), h('span', p.label)));
  }
  nav.hidden = false;
}

export function setAlertDot(on) {
  const a = document.querySelector('#tabs a[data-page="overview"] .dot');
  if (!a) return;
  const existing = a.querySelector('.badge-dot');
  if (on && !existing) a.appendChild(h('span.badge-dot'));
  if (!on && existing) existing.remove();
}

function route() {
  if (!state.me) return;
  const r = parseHash();
  const page = PAGES.find((p) => p.id === r.page) || PAGES[0];
  for (const a of document.querySelectorAll('#tabs a')) {
    if (a.dataset.page === page.id) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  }
  document.title = page.label + ' · HomeVault 管理面板';
  runCleanup();
  const view = clear($('view'));
  if (state.page !== page.id) window.scrollTo(0, 0);
  state.page = page.id;
  try {
    state.cleanup = page.mod.render(view, { route: r, navigate, setAlertDot, me: state.me }) || null;
  } catch (e) {
    view.appendChild(errorBox('页面加载失败：' + e.message));
  }
}

function onLogin(me) {
  state.me = me;
  setCsrf(me.csrf);
  $('app').classList.add('authed');
  $('topbar-sub').textContent = (me.display_name || me.user) + ' · 管理员';
  $('btn-refresh').hidden = false;
  $('btn-logout').hidden = false;
  buildTabs();
  if (!location.hash || location.hash === '#' || location.hash.startsWith('#/login')) {
    history.replaceState(null, '', '#/overview');
  }
  route();
}

function showLogin() {
  runCleanup();
  state.me = null;
  state.page = null;
  setCsrf('');
  $('app').classList.remove('authed');
  $('tabs').hidden = true;
  $('btn-refresh').hidden = true;
  $('btn-logout').hidden = true;
  $('topbar-sub').textContent = '家庭归档服务器';
  $('page-heading').textContent = 'HomeVault';
  document.title = '登录 · HomeVault 管理面板';
  const view = clear($('view'));
  state.cleanup = renderLogin(view, {
    onSuccess: async () => {
      try {
        const me = await api.get('/api/me');
        if (me && me.authenticated) onLogin(me);
        else toast('登录未完成，请重试', 'err');
      } catch (e) {
        toast(e.message, 'err');
      }
    },
  });
}

async function logout() {
  const ok = await confirmDialog({ title: '退出登录', message: '确定要退出管理面板吗？', ok: '退出' });
  if (!ok) return;
  try {
    await api.post('/api/auth/logout');
  } catch { /* session may already be gone */ }
  toast('已退出登录');
  showLogin();
}

async function boot() {
  applyTheme();
  $('btn-refresh').appendChild(icon('refresh'));
  $('btn-logout').appendChild(icon('logout'));
  $('btn-refresh').addEventListener('click', () => {
    const b = $('btn-refresh');
    b.classList.add('spinning');
    setTimeout(() => b.classList.remove('spinning'), 600);
    route();
  });
  $('btn-logout').addEventListener('click', logout);
  window.addEventListener('hashchange', route);
  window.addEventListener('hv:unauthorized', () => {
    if (state.me) {
      toast('登录已失效，请重新登录', 'err');
      showLogin();
    }
  });
  const view = clear($('view'));
  view.appendChild(spinner());
  try {
    const me = await api.get('/api/me');
    if (me && me.authenticated) onLogin(me);
    else showLogin();
  } catch (e) {
    clear(view).appendChild(errorBox(e.message, () => location.reload()));
  }
}

boot();
