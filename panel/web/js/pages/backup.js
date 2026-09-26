// 备份: status, "立即备份" (request file for the host), recent requests, snapshots.
import { api } from '../api.js';
import { h, clear, icon, fmtBytes, fmtNum, fmtTime, relTime, fmtDuration, spinner, errorBox, toast, confirmDialog, kv, pageTitle } from '../ui.js';
import { backupStateText } from './overview.js';

export function requestStateBadge(r) {
  const map = { pending: ['info', '等待主机执行'], running: ['info', '执行中'], ok: ['ok', '成功'], failed: ['err', '失败'], rejected: ['err', '被拒绝'] };
  const [cls, txt] = map[r.state] || ['', r.state];
  return h('span.badge', { class: cls }, txt);
}

export function render(view, ctx) {
  let alive = true;
  let timer = null;
  const body = h('div');
  view.append(pageTitle('备份'), body);
  body.appendChild(spinner());

  async function load() {
    clearTimeout(timer);
    try {
      const d = await api.get('/api/backup');
      if (!alive) return;
      draw(d);
      const busy = d.pending.length > 0 || (d.backup.status && d.backup.status.state === 'running');
      timer = setTimeout(load, busy ? 10000 : 60000);
    } catch (e) {
      if (alive) clear(body).appendChild(errorBox(e.message, load));
    }
  }

  async function runNow(btn) {
    const ok = await confirmDialog({
      title: '立即备份？',
      message: ['主机会在约 2 分钟内开始备份。', '导出数据库时 Nextcloud 会短暂进入维护模式（通常不到 1 分钟），手机上传会稍后自动继续。'],
      ok: '开始备份',
    });
    if (!ok) return;
    btn.disabled = true;
    try {
      const r = await api.post('/api/backup/run');
      toast(r.message, 'ok');
    } catch (e) {
      toast(e.message, 'err');
    } finally {
      btn.disabled = false;
      load();
    }
  }

  function draw(d) {
    clear(body);
    for (const a of d.alerts || []) {
      body.appendChild(h('div.alert', { class: a.level === 'error' ? 'err' : 'warn' }, icon('alert'), h('div.grow', a.message)));
    }
    const b = d.backup;
    const st = b.status || {};
    const card = h('div.card');
    const state = st.state ? String(st.state).toLowerCase() : (b.last_success ? 'ok' : 'never');
    const cls = { ok: 'ok', failed: 'err', error: 'err', partial: 'warn', running: 'info' }[state] || '';
    card.appendChild(h('div.row', h('h3.grow', '备份状态'), h('span.badge', { class: cls }, backupStateText(state))));
    card.appendChild(kv([
      ['上次成功', b.last_success ? `${fmtTime(b.last_success)}（${relTime(b.last_success)}）` : '无记录'],
      ['上次运行', st.last_run ? `${fmtTime(st.last_run)}（${relTime(st.last_run)}）` : ''],
      ['耗时', st.duration_seconds ? fmtDuration(st.duration_seconds) : ''],
      ['备份目标', st.target ? (st.target === 's3' ? '对象存储（S3/OSS/COS）' : '本地硬盘') + (st.repository ? ' · ' + st.repository : '') : ''],
      ['每日计划', st.schedule],
      ['下次运行', st.next_run ? fmtTime(st.next_run) : ''],
      ['新增数据', st.stats ? `${fmtBytes(st.stats.data_added)}（新文件 ${fmtNum(st.stats.files_new)}，修改 ${fmtNum(st.stats.files_changed)}）` : ''],
      ['说明', st.message],
    ]));
    if (!b.configured) {
      card.appendChild(h('p.small.muted', '主机尚未写入备份状态。首次备份请在服务器上运行 hv backup --init（Windows：hv.ps1 backup --init）。'));
    }
    if (b.status_error) card.appendChild(h('div.alert.warn', icon('alert'), h('div.grow', b.status_error)));
    const runBtn = h('button.btn.primary', { type: 'button' }, icon('backup', 'sm'), '立即备份');
    runBtn.addEventListener('click', () => runNow(runBtn));
    const row = h('div.btn-row', runBtn);
    if (st.log_file) {
      row.appendChild(h('a.btn', { href: '#/logs?' + new URLSearchParams({ file: st.log_file }).toString() }, icon('logs', 'sm'), '查看备份日志'));
    }
    card.appendChild(row);
    body.appendChild(card);

    // requests
    const reqs = [...d.pending, ...d.recent];
    if (reqs.length) {
      body.appendChild(h('div.section-title', '备份请求'));
      const ul = h('ul.list');
      for (const r of reqs) {
        ul.appendChild(h('li', h('div.row',
          h('div.grow',
            h('div.title', r.created ? fmtTime(r.created) : r.id),
            h('div.meta', [r.requested_by ? '由 ' + r.requested_by + ' 提交' : '', r.finished ? '完成于 ' + relTime(r.finished) : '', r.message || ''].filter(Boolean).join(' · '))),
          requestStateBadge(r))));
      }
      body.appendChild(h('div.card.flush', ul));
    }

    // snapshots
    body.appendChild(h('div.section-title', h('span.grow', '备份快照'), d.snapshots_total ? h('span.badge', `共 ${d.snapshots_total} 个`) : null));
    if (d.snapshots_error) body.appendChild(h('div.alert.warn', icon('alert'), h('div.grow', d.snapshots_error)));
    if (!d.snapshots.length) {
      body.appendChild(h('div.card.empty-state', '暂无快照列表（每次备份后主机会更新）。'));
    } else {
      const ul = h('ul.list');
      for (const s of d.snapshots) {
        const sum = s.summary;
        ul.appendChild(h('li',
          h('div.row', h('strong.grow', fmtTime(s.time)), h('span.mono.small.muted', s.short_id || (s.id || '').slice(0, 8))),
          h('div.meta', [relTime(s.time),
            sum ? `处理 ${fmtBytes(sum.total_bytes_processed)} · 新增 ${fmtBytes(sum.data_added)}` : '',
            sum ? `新文件 ${fmtNum(sum.files_new)} · 修改 ${fmtNum(sum.files_changed)}` : '',
            (s.tags || []).join(', ')].filter(Boolean).join(' · '))));
      }
      body.appendChild(h('div.card.flush', ul));
      if (d.snapshots_updated) body.appendChild(h('p.small.muted', '快照列表更新于 ' + relTime(d.snapshots_updated)));
    }
    body.appendChild(h('p.small.muted', '恢复文件请在服务器上运行 hv restore（Windows：hv.ps1 restore），详见文档「备份与恢复」。'));
  }

  load();
  return () => { alive = false; clearTimeout(timer); };
}
