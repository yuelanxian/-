// 设置: log retention, Android app download (+QR), root CA, appearance, recent requests, about.
import { api } from '../api.js';
import { h, clear, icon, fmtBytes, fmtTime, relTime, spinner, errorBox, kv, pageTitle, qrCanvas, storageGet, storageSet, applyTheme, toast, confirmDialog } from '../ui.js';
import { retentionCard } from '../retention.js';
import { requestStateBadge } from './backup.js';

const TYPE_LABEL = { backup: '立即备份', 'log-clean': '清理旧日志', 'log-retention': '修改日志保留天数' };

export function render(view) {
  let alive = true;
  const ret = retentionCard();
  const body = h('div');
  view.append(pageTitle('设置'), ret, body);
  body.appendChild(spinner());

  async function load() {
    try {
      const [about, reqs] = await Promise.all([api.get('/api/about'), api.get('/api/requests')]);
      if (alive) draw(about, reqs);
    } catch (e) {
      if (alive) clear(body).appendChild(errorBox(e.message, load));
    }
  }

  function draw(a, reqs) {
    clear(body);

    // Android app
    const app = h('div.card', h('div.row', icon('phone'), h('h3.grow', '安卓应用')));
    if (a.apk && a.apk.available) {
      const url = new URL(a.apk.url, window.location.origin).toString();
      app.append(
        h('p.small.muted', `HomeVault 安卓应用（${fmtBytes(a.apk.size)}，更新于 ${fmtTime(a.apk.mtime)}）。在手机上直接点击下载，或用手机扫描二维码（手机需连接家里的 Wi-Fi 或 VPN）。`),
        h('div.btn-row', h('a.btn.primary', { href: a.apk.url, download: 'HomeVault.apk' }, icon('download', 'sm'), '下载安卓应用')));
      const qr = qrCanvas(url);
      if (qr) app.appendChild(h('div.qr-box', qr, h('div.small.muted.break.mono', url)));
    } else {
      app.appendChild(h('p.small.muted', '服务器上还没有安装包。在服务器上运行 hv android fetch（Windows：hv.ps1 android fetch）下载最新版本后，这里会出现下载按钮和二维码。'));
    }
    body.appendChild(app);

    // CA
    const ca = h('div.card', h('div.row', icon('cert'), h('h3.grow', '根证书（IP 模式）')));
    if (a.ca && a.ca.available) {
      const url = new URL(a.ca.url, window.location.origin).toString();
      ca.append(
        h('p.small.muted', '使用 IP 地址访问时，手机和电脑需要安装 HomeVault 根证书才能信任 HTTPS 连接。安装前请核对指纹。'),
        kv([['名称', a.ca.subject], ['SHA-256 指纹', h('span.mono.small.break', a.ca.sha256)], ['有效期至', fmtTime(a.ca.not_after)]]),
        h('div.btn-row', h('a.btn', { href: a.ca.url, download: 'homevault-ca.crt' }, icon('download', 'sm'), '下载根证书')),
        h('details.more', h('summary', '安卓安装步骤'),
          h('ol.small',
            h('li', '下载证书文件 homevault-ca.crt；'),
            h('li', '打开 设置 → 安全（或"密码与安全"）→ 更多安全设置 → 加密与凭据 → 安装证书 → CA 证书；'),
            h('li', '选择下载的文件并确认（不同品牌菜单名称略有差异，可在设置里搜索"证书"）；'),
            h('li', '安装后重新打开 Nextcloud 应用和本应用。'))));
      const qr = qrCanvas(url);
      if (qr) ca.appendChild(h('details.more', h('summary', '显示二维码'), h('div.qr-box', qr, h('div.small.muted.break.mono', url))));
    } else {
      ca.appendChild(h('p.small.muted', '没有需要安装的根证书（域名模式使用公共受信任证书）。'));
    }
    body.appendChild(ca);

    // appearance
    const cur = storageGet('hv-theme', 'auto');
    const seg = h('div.seg', { role: 'group', 'aria-label': '主题' });
    for (const [v, label] of [['auto', '跟随系统'], ['light', '浅色'], ['dark', '深色']]) {
      const b = h('button', { type: 'button', 'aria-pressed': String(cur === v) }, label);
      b.addEventListener('click', () => {
        storageSet('hv-theme', v);
        applyTheme();
        for (const x of seg.children) x.setAttribute('aria-pressed', String(x === b));
      });
      seg.appendChild(b);
    }
    body.appendChild(h('div.card', h('h3', '外观'), seg));

    // requests
    const all = [...(reqs.pending || []), ...(reqs.done || [])].slice(0, 15);
    body.appendChild(h('div.section-title', '最近提交给主机的请求'));
    if (!all.length) {
      body.appendChild(h('div.card.small.muted', '暂无请求。面板中的"立即备份""清理日志""修改保留天数"会写入请求文件，由主机上的计划任务（约每 2 分钟）执行。'));
    } else {
      const ul = h('ul.list');
      for (const r of all) {
        ul.appendChild(h('li', h('div.row',
          h('div.grow',
            h('div.title', (TYPE_LABEL[r.type] || r.type) + (r.days ? `（${r.days} 天）` : '')),
            h('div.meta', [r.created ? fmtTime(r.created) : '', r.requested_by || '', r.finished ? '完成于 ' + relTime(r.finished) : '', r.message || ''].filter(Boolean).join(' · '))),
          requestStateBadge(r))));
      }
      body.appendChild(h('div.card.flush', ul));
    }

    // about
    body.appendChild(h('div.section-title', '关于'));
    const logout = h('button.btn.danger', { type: 'button' }, icon('logout', 'sm'), '退出登录');
    logout.addEventListener('click', async () => {
      if (!(await confirmDialog({ title: '退出登录', message: '确定要退出管理面板吗？', ok: '退出' }))) return;
      try { await api.post('/api/auth/logout'); } catch { /* ignore */ }
      toast('已退出登录');
      window.location.reload();
    });
    body.appendChild(h('div.card',
      kv([
        ['HomeVault', a.version || '未知'],
        ['管理面板', a.panel_version],
        ['平台', a.platform === 'windows' ? 'Windows' : a.platform === 'linux' ? 'Linux' : a.platform],
        ['Nextcloud', h('a.break', { href: a.nextcloud_url, target: '_blank', rel: 'noopener' }, a.nextcloud_url)],
        ['当前用户', `${a.display_name || a.user}（${a.user}）`],
        ['登录方式', a.login_method === 'flow' ? 'Nextcloud 登录（设备密码，退出时自动删除）' : '应用密码'],
        ['会话到期', `${fmtTime(a.session_expires)}`],
      ]),
      h('div.btn-row', logout)));
    body.appendChild(h('p.small.muted', 'HomeVault 基于 Nextcloud、Caddy、WireGuard、restic 等开源项目构建。'));
  }

  load();
  return () => { alive = false; if (ret.dispose) ret.dispose(); };
}
