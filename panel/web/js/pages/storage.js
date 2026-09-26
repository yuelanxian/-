// 存储: disks by role, per-user usage, Nextcloud statistics, storage.conf.
import { api } from '../api.js';
import { h, clear, icon, bar, fmtBytes, fmtNum, relTime, spinner, errorBox, kv, pageTitle, usageClass } from '../ui.js';

const ROLE_BADGE = { data: 'info', storage: 'purple', backup: 'ok', system: '', other: '' };

export function render(view) {
  let alive = true;
  const body = h('div');
  view.append(pageTitle('存储空间'), body);
  body.appendChild(spinner());

  async function load() {
    try {
      const d = await api.get('/api/storage');
      if (alive) draw(d);
    } catch (e) {
      if (alive) clear(body).appendChild(errorBox(e.message, load));
    }
  }

  function draw(d) {
    clear(body);
    for (const a of d.alerts || []) {
      body.appendChild(h('div.alert', { class: a.level === 'error' ? 'err' : 'warn' }, icon('alert'), h('div.grow', a.message)));
    }

    body.appendChild(h('div.section-title', '硬盘'));
    if (!d.disks.length) {
      body.appendChild(h('div.card.empty-state', '没有可统计的磁盘（面板容器未挂载 /stat 目录，主机也未写入磁盘信息）。'));
    } else if (d.disks_source === 'host') {
      body.appendChild(h('p.small.muted', '以下数据来自主机每日写入的状态文件（面板容器未挂载 /stat 目录）。'));
    }
    for (const disk of d.disks) {
      const card = h('div.card',
        h('div.row',
          h('span.badge', { class: ROLE_BADGE[disk.role] || '' }, disk.role_label),
          h('strong.grow', disk.name),
          disk.access ? h('span.badge', disk.access === 'ro' ? '只读' : '读写') : null,
          disk.role === 'storage' && disk.backup ? h('span.badge.ok', '已纳入备份') : null));
      if (disk.host_path) card.appendChild(h('div.small.muted.break.mono', disk.host_path));
      if (disk.error) {
        card.appendChild(h('div.alert.warn', icon('alert'), h('div.grow', disk.error)));
      } else {
        card.appendChild(bar(disk.used_pct, usageClass(disk.used_pct)));
        card.appendChild(h('div.row.wrap.small',
          h('span.grow', `已用 ${fmtBytes(disk.used)}（${disk.used_pct}%）`),
          h('span.muted', `剩余 ${fmtBytes(disk.free)} / 共 ${fmtBytes(disk.total)}`)));
      }
      if (disk.same_disk && disk.same_disk.length) {
        card.appendChild(h('div.small.muted', '与「' + disk.same_disk.join('」「') + '」位于同一块磁盘'));
      }
      body.appendChild(card);
    }

    // users
    body.appendChild(h('div.section-title', 'Nextcloud 用户用量'));
    if (d.users_error) body.appendChild(h('div.alert.warn', icon('alert'), h('div.grow', d.users_error)));
    const users = d.users || [];
    if (users.length) {
      const maxUsed = Math.max(1, ...users.map((u) => u.used || 0));
      const ul = h('ul.list');
      for (const u of users) {
        const limited = u.quota > 0;
        const pct = limited ? Math.min(100, (u.used / u.quota) * 100) : (u.used / maxUsed) * 100;
        ul.appendChild(h('li',
          h('div.row',
            h('div.grow', h('span.title', u.display_name || u.id), u.display_name && u.display_name !== u.id ? h('span.muted.small', '  ' + u.id) : null),
            u.admin ? h('span.badge.info', '管理员') : null,
            u.enabled ? null : h('span.badge.err', '已禁用')),
          bar(pct, 'thin ' + (limited ? usageClass(pct) : '')),
          h('div.row.small.muted',
            h('span.grow', limited ? `已用 ${fmtBytes(u.used)} / 配额 ${fmtBytes(u.quota)}` : `已用 ${fmtBytes(u.used)} · 不限额`),
            h('span', '最近登录 ' + relTime(u.last_login)))));
      }
      body.appendChild(h('div.card.flush', ul));
    } else if (!d.users_error) {
      body.appendChild(h('div.card.empty-state', '没有用户数据'));
    }

    const nc = d.nextcloud;
    if (nc) {
      body.appendChild(h('div.section-title', 'Nextcloud 统计'));
      body.appendChild(h('div.card', kv([
        ['版本', nc.version],
        ['用户数', fmtNum(nc.num_users)],
        ['文件数', fmtNum(nc.num_files)],
        ['存储数', fmtNum(nc.num_storages)],
        ['数据库', nc.db_type ? `${nc.db_type}（${fmtBytes(nc.db_size)}）` : ''],
        ['活跃用户', `5 分钟内 ${fmtNum(nc.active_5min)} · 24 小时内 ${fmtNum(nc.active_24h)}`],
        ['PHP', nc.php_version],
      ])));
    }

    const conf = d.storage_conf || [];
    body.appendChild(h('div.section-title', '扩展存储配置（storage.conf）'));
    if (!conf.length) {
      body.appendChild(h('div.card.small.muted', '没有配置扩展存储。在服务器上运行 hv storage add（Windows：hv.ps1 storage add）添加其他硬盘上的文件夹。'));
    } else {
      const ul = h('ul.list');
      for (const c of conf) {
        ul.appendChild(h('li',
          h('div.row', h('strong.grow', c.name), h('span.badge', c.access === 'ro' ? '只读' : '读写'), c.backup ? h('span.badge.ok', '备份') : null),
          h('div.small.muted.mono.break', c.host_path),
          c.users ? h('div.small.muted', '可见：' + c.users) : h('div.small.muted', '可见：所有用户')));
      }
      body.appendChild(h('div.card.flush', ul));
    }
  }

  load();
  return () => { alive = false; };
}
