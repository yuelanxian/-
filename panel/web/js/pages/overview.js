// 概览: alerts, key numbers, services (with restart), host info.
import { api } from '../api.js';
import { h, clear, icon, bar, fmtBytes, fmtNum, relTime, uptime, spinner, errorBox, toast, confirmDialog,
  badgeForState, stateDot, kv, pageTitle, usageClass } from '../ui.js';

export function render(view, ctx) {
  let timer = null;
  let alive = true;
  const body = h('div');
  view.append(pageTitle('系统概览'), body);
  body.appendChild(spinner());

  async function load() {
    try {
      const d = await api.get('/api/overview');
      if (!alive) return;
      draw(d);
    } catch (e) {
      if (!alive) return;
      clear(body).appendChild(errorBox(e.message, load));
    } finally {
      if (alive) {
        clearTimeout(timer);
        timer = setTimeout(load, 30000);
      }
    }
  }

  function draw(d) {
    clear(body);
    const errs = d.alerts.filter((a) => a.level === 'error').length;
    ctx.setAlertDot(errs > 0);

    // alerts
    if (d.alerts.length === 0) {
      body.appendChild(h('div.alert.ok', icon('check'), h('div.grow', h('strong', '一切正常'), h('div.small.muted', '所有服务运行中，备份与磁盘空间正常。'))));
    } else {
      for (const a of d.alerts) {
        const el = h('a.alert', { class: a.level === 'error' ? 'err' : a.level === 'warn' ? 'warn' : '', href: '#/' + (a.page || 'overview') },
          icon(a.level === 'info' ? 'info' : 'alert'), h('div.grow', a.message), icon('chevron', 'sm'));
        body.appendChild(el);
      }
    }

    // key numbers
    const grid = h('div.grid');
    const data = (d.disks || []).find((x) => x.role === 'data');
    if (data && !data.error) {
      grid.appendChild(h('a.stat', { href: '#/storage', class: usageClass(data.used_pct) === 'ok' ? '' : usageClass(data.used_pct) },
        h('div.k', icon('storage', 'sm'), '主数据盘'),
        h('div.v', `${data.used_pct}%`),
        bar(data.used_pct, 'thin ' + usageClass(data.used_pct)),
        h('div.d', `剩余 ${fmtBytes(data.free)} / 共 ${fmtBytes(data.total)}`)));
    } else {
      grid.appendChild(h('a.stat', { href: '#/storage' }, h('div.k', icon('storage', 'sm'), '主数据盘'), h('div.v', '—'), h('div.d', '未挂载统计目录')));
    }
    const b = d.backup || {};
    let bcls = 'ok';
    if (!b.last_success) bcls = 'warn';
    else if (b.stale) bcls = 'err';
    if (b.status && /fail|error/i.test(b.status.state || '')) bcls = 'err';
    grid.appendChild(h('a.stat', { href: '#/backup', class: bcls },
      h('div.k', icon('backup', 'sm'), '上次成功备份'),
      h('div.v', b.last_success ? relTime(b.last_success) : '无记录'),
      h('div.d', b.status && b.status.state ? '最近一次：' + backupStateText(b.status.state) : '点击查看备份')));
    const v = d.vpn || {};
    grid.appendChild(h('a.stat', { href: '#/vpn' },
      h('div.k', icon('vpn', 'sm'), 'VPN 在线设备'),
      h('div.v', v.available ? `${v.online} / ${v.devices}` : '—'),
      h('div.d', v.available ? '更新于 ' + relTime(v.updated) : '暂无 VPN 状态')));
    const nc = d.nextcloud;
    grid.appendChild(h('a.stat', { href: d.nextcloud_url, target: '_blank', rel: 'noopener' },
      h('div.k', icon('cloud', 'sm'), 'Nextcloud'),
      h('div.v', nc && nc.version ? nc.version : '打开'),
      h('div.d', nc ? `${fmtNum(nc.num_users)} 个用户 · ${fmtNum(nc.num_files)} 个文件` : d.nextcloud_url)));
    body.appendChild(grid);

    // services
    body.appendChild(h('div.section-title', h('span.grow', '服务状态'), d.pending ? h('span.badge.info', `${d.pending} 个请求待主机执行`) : null));
    const card = h('div.card.flush');
    if (!d.docker.ok) {
      card.appendChild(h('div.alert.err', icon('alert'), h('div.grow', d.docker.error || '无法连接 Docker')));
    } else if (!d.services.length) {
      card.appendChild(h('div.empty-state', '没有找到服务容器'));
    } else {
      const ul = h('ul.list');
      for (const s of d.services) {
        const actions = [];
        if (s.can_restart) {
          const btn = h('button.btn.sm', { type: 'button', title: '重启 ' + s.label }, icon('restart', 'sm'), '重启');
          btn.addEventListener('click', () => restart(s, btn));
          actions.push(btn);
        }
        ul.appendChild(h('li', h('div.row',
          stateDot(s.state, s.health),
          h('div.grow',
            h('div.title', s.label),
            h('div.meta', s.service + (s.state === 'running' && s.started_at ? ' · ' + uptime(s.started_at) : '') +
              (s.restart_count ? ` · 自动重启 ${s.restart_count} 次` : ''))),
          badgeForState(s.state, s.health),
          ...actions)));
      }
      card.appendChild(ul);
    }
    body.appendChild(card);

    // host
    body.appendChild(h('div.section-title', '服务器信息'));
    const info = (d.docker && d.docker.info) || {};
    body.appendChild(h('div.card', kv([
      ['HomeVault 版本', d.version || '未知'],
      ['管理面板版本', d.panel_version],
      ['平台', d.platform === 'windows' ? 'Windows（Docker Desktop）' : d.platform === 'linux' ? 'Linux' : d.platform],
      ['服务器地址', d.host],
      ['Nextcloud', d.nextcloud_url],
      ['操作系统', info.operating_system],
      ['Docker', info.server_version],
      ['CPU / 内存', info.ncpu ? `${info.ncpu} 核 / ${fmtBytes(info.mem_total)}` : ''],
      ['状态更新', d.status_updated ? relTime(d.status_updated) : '主机尚未写入状态文件'],
    ])));
  }

  async function restart(s, btn) {
    const warn = s.service === 'caddy' ? '重启网关期间所有连接（包括本面板）会中断几秒钟。' :
      s.service === 'app' ? '重启期间 Nextcloud 暂时不可用，手机上传会稍后自动重试。' :
        s.service === 'db' || s.service === 'redis' ? '重启期间 Nextcloud 暂时不可用。' : '';
    const ok = await confirmDialog({ title: `重启「${s.label}」？`, message: warn || '服务会停止并重新启动。', ok: '重启' });
    if (!ok) return;
    btn.disabled = true;
    try {
      const r = await api.post(`/api/services/${encodeURIComponent(s.service)}/restart`);
      toast(r.message || '已重启', 'ok');
    } catch (e) {
      // The panel itself is served through Caddy: restarting it cuts this very request.
      if (s.service === 'caddy' && e.status === 0) {
        toast('HTTPS 网关正在重启，几秒后自动恢复', 'ok');
      } else {
        toast(e.message, 'err');
      }
    } finally {
      btn.disabled = false;
      // Caddy restarts in the background after answering: reload once the gateway is back.
      if (s.service === 'caddy') {
        clearTimeout(timer);
        timer = setTimeout(load, 6000);
      } else {
        load();
      }
    }
  }

  load();
  return () => { alive = false; clearTimeout(timer); };
}

export function backupStateText(st) {
  return { ok: '成功', failed: '失败', error: '失败', partial: '部分成功', running: '进行中', never: '从未运行' }[String(st).toLowerCase()] || st;
}
