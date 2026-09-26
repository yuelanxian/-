// Login: Nextcloud Login Flow v2 (primary) + "用户名 + 应用密码" fallback.
import { api } from '../api.js';
import { h, clear, icon } from '../ui.js';

// Inside the HomeVault Android app (User-Agent contains "HomeVaultApp/") every navigation to another
// origin — such as the Nextcloud login page — is opened in the phone's browser while this page stays
// open and keeps polling. In a normal browser the login page opens in a new tab.
const IN_APP = /\bHomeVaultApp\//.test(navigator.userAgent);

export function renderLogin(view, { onSuccess }) {
  let timer = null;
  let stopped = false;
  let mode = '';
  let where = IN_APP ? 'app' : 'tab';

  const card = h('div.card');
  view.appendChild(h('div.login-wrap',
    h('div.login-logo',
      h('img', { src: '/icons/icon-192.png', alt: '' }),
      h('h2', 'HomeVault 管理面板'),
      h('div.muted', '使用 Nextcloud 管理员账户登录')),
    card,
    h('p.muted.small', '提示：只有 Nextcloud「admin」组的成员可以登录。登录会在 Nextcloud 中创建一个名为「HomeVault 管理面板（你的 IP）」的设备密码，退出登录时自动删除。')));

  const schedule = (ms) => {
    clearTimeout(timer);
    if (!stopped) timer = setTimeout(poll, ms);
  };

  function showStart(errMsg) {
    mode = 'start';
    clearTimeout(timer);
    const btn = h('button.btn.primary.block.big', { type: 'button' }, icon('cloud'), '使用 Nextcloud 登录');
    const err = h('div');
    if (errMsg) err.appendChild(h('div.alert.err', icon('alert'), h('div.grow', errMsg)));
    btn.addEventListener('click', async () => {
      btn.disabled = true;
      clear(err);
      // Open the tab synchronously (still inside the click gesture) so popup blockers allow it.
      let win = null;
      if (!IN_APP) {
        try { win = window.open('', '_blank'); } catch { win = null; }
      }
      try {
        const r = await api.post('/api/auth/flow');
        if (win && !win.closed) {
          try { win.opener = null; } catch { /* ignore */ }
          win.location.href = r.login_url;
          where = 'tab';
        } else {
          // App: intercepted and opened in the phone's browser. Browser with blocked popups:
          // same window; the server keeps polling and the back button returns here.
          where = IN_APP ? 'app' : 'same';
          window.location.assign(r.login_url);
        }
        showWaiting(r.login_url);
      } catch (e) {
        if (win) { try { win.close(); } catch { /* ignore */ } }
        btn.disabled = false;
        err.appendChild(h('div.alert.err', icon('alert'), h('div.grow', e.message)));
      }
    });

    const user = h('input.input', { type: 'text', name: 'username', autocomplete: 'username', autocapitalize: 'none', spellcheck: 'false', required: true });
    const pass = h('input.input', { type: 'password', name: 'app-password', autocomplete: 'current-password', required: true });
    const formErr = h('div');
    const submit = h('button.btn.block', { type: 'submit' }, '登录');
    const form = h('form', { novalidate: true },
      h('p.muted.small', '在 Nextcloud 网页中打开：头像 → 个人设置 → 安全 → 创建新应用密码，然后在这里输入。'),
      h('label.field', h('span', 'Nextcloud 用户名'), user),
      h('label.field', h('span', '应用密码'), pass),
      formErr, submit);
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      clear(formErr);
      if (!user.value.trim() || !pass.value.trim()) {
        formErr.appendChild(h('div.alert.warn', icon('alert'), h('div.grow', '请输入用户名和应用密码')));
        return;
      }
      submit.disabled = true;
      try {
        await api.post('/api/auth/password', { user: user.value.trim(), app_password: pass.value.trim() });
        pass.value = '';
        stopped = true;
        onSuccess();
      } catch (ex) {
        formErr.appendChild(h('div.alert.err', icon('alert'), h('div.grow', ex.message)));
      } finally {
        submit.disabled = false;
      }
    });

    clear(card).append(
      btn, err,
      h('div.spacer'),
      h('details.more', h('summary', '使用应用密码登录'), form));
  }

  function showWaiting(loginUrl) {
    if (mode === 'waiting') return;
    mode = 'waiting';
    // A real link: never blocked, and inside the app it is handed to the phone's browser.
    const reopen = h('a.btn.primary.block', { href: loginUrl, target: '_blank', rel: 'noopener noreferrer' }, '重新打开 Nextcloud 登录页');
    const cancel = h('button.btn.block', { type: 'button' }, '取消');
    cancel.addEventListener('click', async () => {
      stopped = false;
      try { await api.post('/api/auth/flow/cancel'); } catch { /* ignore */ }
      showStart();
    });
    clear(card).append(
      h('div.waiting',
        h('div.spinner'),
        h('strong', '正在等待 Nextcloud 登录完成…'),
        h('div.muted.small', {
          app: '已在手机浏览器中打开 Nextcloud 登录页。请在浏览器中登录（包括两步验证）并点击「授予访问权限」，然后切换回本应用，会自动进入管理面板。',
          tab: '已在新标签页打开 Nextcloud 登录页。请在那里登录（包括两步验证）并点击「授予访问权限」，然后回到本页面，会自动进入管理面板。',
          same: '请在 Nextcloud 页面登录（包括两步验证）并点击「授予访问权限」，然后按返回键回到本页面，会自动进入管理面板。',
        }[where]),
        h('div.muted.small', '安全提示：只在自己发起登录时授权；授权页显示的名称应为「HomeVault 管理面板（本设备的 IP）」。')),
      h('div.btn-row', reopen, cancel));
    schedule(2000);
  }

  async function poll() {
    if (stopped) return;
    try {
      const r = await api.post('/api/auth/flow/poll');
      if (stopped) return;
      switch (r.state) {
        case 'ok':
          stopped = true;
          onSuccess();
          return;
        case 'pending':
          showWaiting(r.login_url);
          schedule(2000);
          return;
        case 'failed':
          showStart(r.message || '登录失败');
          return;
        default:
          if (mode !== 'start') showStart();
      }
    } catch (e) {
      if (mode === 'waiting') schedule(4000);
      else showStart(e.message);
    }
  }

  const onPageShow = () => { if (!stopped) poll(); };
  window.addEventListener('pageshow', onPageShow);
  const onVisible = () => { if (document.visibilityState === 'visible' && mode === 'waiting') poll(); };
  document.addEventListener('visibilitychange', onVisible);

  card.appendChild(h('div.loading', h('div.spinner')));
  poll();

  return () => {
    stopped = true;
    clearTimeout(timer);
    window.removeEventListener('pageshow', onPageShow);
    document.removeEventListener('visibilitychange', onVisible);
  };
}
