// Login: Nextcloud Login Flow v2 (primary) + "用户名 + 应用密码" fallback.
import { api } from '../api.js';
import { h, clear, icon } from '../ui.js';

export function renderLogin(view, { onSuccess }) {
  let timer = null;
  let stopped = false;
  let mode = '';

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
      try {
        const r = await api.post('/api/auth/flow');
        showWaiting(r.login_url);
        // Same window: the panel keeps polling server-side; come back with the back button.
        window.location.assign(r.login_url);
      } catch (e) {
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
    const reopen = h('button.btn.primary.block', { type: 'button', onclick: () => window.location.assign(loginUrl) }, '打开 Nextcloud 登录页');
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
        h('div.muted.small', '请在 Nextcloud 页面登录（包括两步验证）并点击「授予访问权限」，然后返回本页面（按返回键）。本页会自动进入管理面板。'),
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
