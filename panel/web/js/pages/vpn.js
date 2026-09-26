// VPN: devices from state/vpn-status.json (written by the host; never contains keys).
import { api } from '../api.js';
import { h, clear, icon, fmtBytes, fmtTime, relTime, spinner, errorBox, pageTitle } from '../ui.js';

export function render(view) {
  let alive = true;
  let timer = null;
  const body = h('div');
  view.append(pageTitle('VPN 设备'), body);
  body.appendChild(spinner());

  async function load() {
    clearTimeout(timer);
    try {
      const d = await api.get('/api/vpn');
      if (!alive) return;
      draw(d);
      timer = setTimeout(load, 30000);
    } catch (e) {
      if (alive) clear(body).appendChild(errorBox(e.message, load));
    }
  }

  function draw(d) {
    clear(body);
    if (!d.available) {
      if (d.error) body.appendChild(h('div.alert.err', icon('alert'), h('div.grow', d.error)));
      body.appendChild(h('div.card',
        h('h3', '暂无 VPN 状态'),
        h('p.muted', '服务器每隔几分钟把 VPN 设备状态写入 state/vpn-status.json。如果一直没有数据：'),
        h('ul.small.muted',
          h('li', '确认安装时启用了 VPN（Linux：wg-easy；Windows：WireGuard 隧道服务 homevault）；'),
          h('li', '在服务器上运行 hv vpn list（Windows：hv.ps1 vpn list）查看设备；'),
          h('li', '添加手机：hv vpn add <名称>（Windows：hv.ps1 vpn add <名称>），用 WireGuard / WG Tunnel 扫码导入。'))));
      return;
    }
    const online = d.peers.filter((p) => p.online).length;
    body.appendChild(h('div.grid',
      h('div.stat.ok', h('div.k', '在线'), h('div.v', String(online)), h('div.d', '3 分钟内有握手')),
      h('div.stat', h('div.k', '设备总数'), h('div.v', String(d.peers.length)), h('div.d', d.interface ? '接口 ' + d.interface + (d.listen_port ? ' · UDP ' + d.listen_port : '') : ''))));
    if (d.stale) {
      body.appendChild(h('div.alert.warn', icon('alert'), h('div.grow', `VPN 状态已 ${relTime(d.updated)} 未更新，显示的信息可能已过时。`)));
    }
    if (!d.peers.length) {
      body.appendChild(h('div.card.empty-state', '还没有 VPN 设备。在服务器上运行 hv vpn add <名称> 添加手机。'));
    } else {
      const ul = h('ul.list');
      for (const p of d.peers) {
        const hs = p.latest_handshake;
        ul.appendChild(h('li',
          h('div.row',
            h('span.dot-state', { class: p.online ? 'ok' : '' }),
            h('div.grow', h('div.title', p.name || '(未命名)'), h('div.meta.mono', p.address || '')),
            !p.enabled ? h('span.badge.err', '已停用') : p.online ? h('span.badge.ok', '在线') : h('span.badge', hs ? '离线' : '从未连接')),
          h('div.meta', hs ? `最近握手：${relTime(hs)}（${fmtTime(hs)}）` : '最近握手：从未'),
          h('div.meta', `设备上传 ${fmtBytes(p.rx_bytes)} · 设备下载 ${fmtBytes(p.tx_bytes)}` + (p.endpoint ? ` · 来自 ${p.endpoint}` : ''))));
      }
      body.appendChild(h('div.card.flush', ul));
    }
    body.appendChild(h('p.small.muted', `状态更新于 ${relTime(d.updated)}。流量为本次 VPN 服务启动以来的累计值。管理设备请在服务器上使用 hv vpn（Windows：hv.ps1 vpn）。`));
  }

  load();
  return () => { alive = false; clearTimeout(timer); };
}
