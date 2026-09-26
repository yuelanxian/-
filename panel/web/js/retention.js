// Log retention card (used on 日志 and 设置): shows current days, edits 1–365, triggers cleanup.
import { api } from './api.js';
import { h, clear, icon, toast, confirmDialog, relTime } from './ui.js';
import { requestStateBadge } from './pages/backup.js';

export function retentionCard() {
  const card = h('div.card');
  let alive = true;

  async function load() {
    try {
      const d = await api.get('/api/settings/log-retention');
      if (alive) draw(d);
    } catch (e) {
      if (alive) clear(card).appendChild(h('div.alert.err', icon('alert'), h('div.grow', e.message)));
    }
  }

  function draw(d) {
    clear(card);
    const input = h('input.input.num', { type: 'number', inputmode: 'numeric', min: d.min, max: d.max, step: 1, value: d.days, 'aria-label': '保留天数' });
    const save = h('button.btn.primary', { type: 'button' }, '保存');
    const clean = h('button.btn', { type: 'button' }, '立即清理旧日志');
    const msg = h('div');

    save.addEventListener('click', async () => {
      const v = input.value.trim();
      if (!/^\d{1,3}$/.test(v) || Number(v) < 1 || Number(v) > 365) {
        clear(msg).appendChild(h('div.alert.warn', icon('alert'), h('div.grow', '请输入 1 到 365 之间的整数')));
        return;
      }
      save.disabled = true;
      try {
        const r = await api.post('/api/settings/log-retention', { days: Number(v) });
        toast(r.message, 'ok');
        load();
      } catch (e) {
        clear(msg).appendChild(h('div.alert.err', icon('alert'), h('div.grow', e.message)));
      } finally {
        save.disabled = false;
      }
    });

    clean.addEventListener('click', async () => {
      const ok = await confirmDialog({ title: '清理旧日志？', message: `将删除超过 ${d.days} 天的日志文件（仅 .log / .gz / .txt）。`, ok: '清理' });
      if (!ok) return;
      clean.disabled = true;
      try {
        const r = await api.post('/api/logs/clean');
        toast(r.message, 'ok');
      } catch (e) {
        toast(e.message, 'err');
      } finally {
        clean.disabled = false;
      }
    });

    const presets = h('div.row.wrap');
    for (const p of [3, 7, 14, 30, 90]) {
      presets.appendChild(h('button.btn.sm', { type: 'button', onclick: () => { input.value = p; } }, `${p} 天`));
    }

    card.append(
      h('div.row', h('h3.grow', '日志保留天数'), h('span.badge.info', `当前 ${d.days} 天`)),
      h('p.small.muted', `超过保留天数的日志会在每天的维护任务中自动删除（默认 ${d.default} 天，可设 ${d.min}–${d.max} 天）。`),
      h('div.row.wrap', input, h('span', '天'), save),
      h('div.spacer'),
      presets,
      msg);
    const pend = (d.pending || [])[0];
    if (pend) {
      card.appendChild(h('div.alert', icon('info'), h('div.grow', `已提交修改为 ${pend.days} 天，等待主机执行（约 2 分钟内）`)));
    } else if ((d.recent || [])[0]) {
      const r = d.recent[0];
      card.appendChild(h('div.row.small.muted', h('span.grow', `最近一次修改：${r.days || '?'} 天 · ${relTime(r.finished || r.created)}${r.message ? ' · ' + r.message : ''}`), requestStateBadge(r)));
    }
    card.appendChild(h('div.btn-row', clean));
  }

  card.appendChild(h('div.loading', h('div.spinner')));
  load();
  card.dispose = () => { alive = false; };
  return card;
}
