// 日志: retention setting, log files under HV_LOG_DIR, container logs, tail viewer.
import { api, qs } from '../api.js';
import { h, clear, icon, fmtBytes, relTime, spinner, errorBox, pageTitle, stateDot, storageGet, storageSet } from '../ui.js';
import { retentionCard } from '../retention.js';

const GROUPS = {
  homevault: 'HomeVault 命令日志',
  backup: '备份日志',
  nextcloud: 'Nextcloud 日志',
  caddy: 'HTTPS 网关访问日志',
  containers: '容器日志（每日导出）',
  panel: '管理面板审计日志',
};
const ERR_RE = /\b(error|errors|fatal|panic|crit|critical|emerg|exception|failed)\b|错误|失败|"level"\s*:\s*[34]\b/i;
const WARN_RE = /\b(warn|warning)\b|警告|"level"\s*:\s*2\b/i;

export function render(view, ctx) {
  const p = ctx.route.params;
  if (p.get('file')) return renderViewer(view, ctx, 'file', p.get('file'));
  if (p.get('service')) return renderViewer(view, ctx, 'service', p.get('service'));
  return renderList(view, ctx);
}

function renderList(view, ctx) {
  let alive = true;
  let tab = storageGet('hv-logs-tab', 'files');
  const ret = retentionCard();
  const body = h('div');
  const seg = h('div.seg', { role: 'group', 'aria-label': '日志类型' });
  const filesBtn = h('button', { type: 'button' }, '日志文件');
  const contBtn = h('button', { type: 'button' }, '容器实时日志');
  seg.append(filesBtn, contBtn);
  view.append(pageTitle('日志'), ret, h('div.spacer'), seg, h('div.spacer'), body);
  body.appendChild(spinner());
  let data = null;

  const setTab = (t) => {
    tab = t;
    storageSet('hv-logs-tab', t);
    filesBtn.setAttribute('aria-pressed', String(t === 'files'));
    contBtn.setAttribute('aria-pressed', String(t === 'containers'));
    if (data) draw();
  };
  filesBtn.addEventListener('click', () => setTab('files'));
  contBtn.addEventListener('click', () => setTab('containers'));
  setTab(tab);

  async function load() {
    try {
      data = await api.get('/api/logs');
      if (alive) draw();
    } catch (e) {
      if (alive) clear(body).appendChild(errorBox(e.message, load));
    }
  }

  function draw() {
    clear(body);
    if (tab === 'containers') {
      if (data.containers_error) body.appendChild(h('div.alert.err', icon('alert'), h('div.grow', data.containers_error)));
      const ul = h('ul.list');
      for (const c of data.containers) {
        ul.appendChild(h('li', h('a.item', { href: '#/logs?' + new URLSearchParams({ service: c.service }) },
          stateDot(c.state, c.health),
          h('div.grow', h('div.title', c.label), h('div.meta', c.service)),
          icon('chevron', 'sm'))));
      }
      if (!data.containers.length && !data.containers_error) ul.appendChild(h('li.empty-state', '没有容器'));
      body.appendChild(h('div.card.flush', ul));
      body.appendChild(h('p.small.muted', '容器日志来自 Docker（最近的输出）；更早的内容见「日志文件 → 容器日志（每日导出）」。'));
      return;
    }
    if (data.files_error) body.appendChild(h('div.alert.err', icon('alert'), h('div.grow', data.files_error)));
    const filter = h('input.input', { type: 'search', placeholder: '筛选文件名…', 'aria-label': '筛选文件名' });
    const list = h('div');
    body.append(filter, h('div.spacer'), list);
    const drawFiles = () => {
      clear(list);
      const f = filter.value.trim().toLowerCase();
      const groups = new Map();
      for (const file of data.files) {
        if (f && !file.path.toLowerCase().includes(f)) continue;
        const top = file.path.includes('/') ? file.path.split('/')[0] : '';
        if (!groups.has(top)) groups.set(top, []);
        groups.get(top).push(file);
      }
      const order = [...Object.keys(GROUPS), ...[...groups.keys()].filter((k) => !(k in GROUPS))];
      let any = false;
      for (const g of order) {
        const files = groups.get(g);
        if (!files || !files.length) continue;
        any = true;
        const ul = h('ul.list');
        for (const file of files.slice(0, 200)) {
          ul.appendChild(h('li', h('a.item', { href: '#/logs?' + new URLSearchParams({ file: file.path }) },
            icon(file.gzip ? 'download' : 'logs', 'sm'),
            h('div.grow', h('div.title.break', file.name), h('div.meta', `${fmtBytes(file.size)} · ${relTime(file.mtime)}` + (file.dir && file.dir !== g ? ' · ' + file.dir : ''))),
            icon('chevron', 'sm'))));
        }
        if (files.length > 200) ul.appendChild(h('li.small.muted', `还有 ${files.length - 200} 个文件未显示，请使用筛选。`));
        list.append(h('div.section-title', GROUPS[g] || (g || '其他')), h('div.card.flush.file-group', ul));
      }
      if (!any) list.appendChild(h('div.card.empty-state', f ? '没有匹配的文件' : '日志目录为空'));
    };
    filter.addEventListener('input', drawFiles);
    drawFiles();
  }

  load();
  return () => { alive = false; if (ret.dispose) ret.dispose(); };
}

function renderViewer(view, ctx, kind, id) {
  let alive = true;
  let timer = null;
  let loading = false;
  const isFile = kind === 'file';
  const back = h('button.icon-btn', { type: 'button', 'aria-label': '返回', onclick: () => ctx.navigate('logs') }, icon('back'));
  const title = h('div.grow', h('strong.break', isFile ? id.split('/').pop() : id), h('div.small.muted.break', isFile ? id : '容器日志'));
  const status = h('div.small.muted');

  const search = h('input.input.search', { type: 'search', placeholder: '搜索（不区分大小写）', 'aria-label': '搜索', enterkeyhint: 'search' });
  const linesSel = h('select.input', { 'aria-label': '行数' });
  const savedLines = storageGet('hv-log-lines', '500');
  for (const n of [200, 500, 1000, 2000, 5000]) {
    const o = h('option', { value: n }, `最后 ${n} 行`);
    if (String(n) === savedLines) o.selected = true;
    linesSel.appendChild(o);
  }
  const auto = h('input', { type: 'checkbox' });
  const wrap = h('input', { type: 'checkbox' });
  wrap.checked = storageGet('hv-log-wrap', '1') === '1';
  const dl = h('a.btn.sm', { download: '', href: '#', title: '下载' }, icon('download', 'sm'), '下载');
  const toBottom = h('button.btn.sm', { type: 'button', title: '到底部' }, icon('bottom', 'sm'), '底部');
  const searchBtn = h('button.btn.sm', { type: 'button' }, icon('search', 'sm'), '搜索');
  const out = h('div.logview', { tabindex: '0', 'aria-label': '日志内容' });
  out.classList.toggle('wrap', wrap.checked);

  view.append(
    h('div.row', back, title),
    h('div.spacer'),
    h('div.log-toolbar', search, searchBtn),
    h('div.log-toolbar', linesSel,
      h('label.switch', auto, '自动刷新'),
      h('label.switch', wrap, '换行'),
      dl, toBottom),
    out, h('div.spacer'), status);
  out.appendChild(spinner());

  function url() {
    const lines = linesSel.value;
    const q = search.value.trim();
    if (isFile) return '/api/logs/file' + qs({ path: id, lines, q });
    return '/api/logs/container/' + encodeURIComponent(id) + qs({ lines, q });
  }
  function updateDownload() {
    dl.href = isFile ? '/api/logs/download' + qs({ path: id }) : '/api/logs/container/' + encodeURIComponent(id) + '/download' + qs({ lines: 20000 });
  }
  updateDownload();

  async function load(keepBottom) {
    if (loading) return;
    loading = true;
    const atBottom = out.scrollHeight - out.scrollTop - out.clientHeight < 40;
    try {
      const d = await api.get(url());
      if (!alive) return;
      drawLines(d.lines, search.value.trim());
      const parts = [`${d.lines.length} 行`];
      if (d.size !== undefined) parts.push(fmtBytes(d.size));
      if (d.mtime) parts.push('修改于 ' + relTime(d.mtime));
      if (d.truncated) parts.push('仅显示最后一部分');
      if (d.state && d.state !== 'running') parts.push('容器未运行');
      parts.push('刷新于 ' + new Date().toLocaleTimeString('zh-CN'));
      status.textContent = parts.join(' · ');
      if (atBottom || keepBottom) out.scrollTop = out.scrollHeight;
    } catch (e) {
      if (alive) {
        clear(out).appendChild(h('div.empty', e.message));
      }
    } finally {
      loading = false;
    }
  }

  function drawLines(lines, q) {
    const frag = document.createDocumentFragment();
    if (!lines.length) {
      frag.appendChild(h('div.empty', q ? '没有匹配的行' : '日志为空'));
    }
    const lq = q.toLowerCase();
    for (const line of lines) {
      const el = document.createElement('div');
      el.className = 'ln' + (ERR_RE.test(line) ? ' e' : WARN_RE.test(line) ? ' w' : '');
      if (lq) {
        const low = line.toLowerCase();
        let i = 0;
        for (;;) {
          const j = low.indexOf(lq, i);
          if (j < 0) break;
          if (j > i) el.appendChild(document.createTextNode(line.slice(i, j)));
          const m = document.createElement('mark');
          m.textContent = line.slice(j, j + lq.length);
          el.appendChild(m);
          i = j + lq.length;
        }
        if (i < line.length) el.appendChild(document.createTextNode(line.slice(i)));
      } else {
        el.textContent = line || ' ';
      }
      frag.appendChild(el);
    }
    clear(out).appendChild(frag);
  }

  function schedule() {
    clearTimeout(timer);
    if (alive && auto.checked) {
      timer = setTimeout(async () => {
        if (document.visibilityState === 'visible') await load(false);
        schedule();
      }, 5000);
    }
  }

  search.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); load(true); } });
  search.addEventListener('search', () => load(true));
  searchBtn.addEventListener('click', () => load(true));
  linesSel.addEventListener('change', () => { storageSet('hv-log-lines', linesSel.value); load(true); });
  auto.addEventListener('change', () => { if (auto.checked) load(false); schedule(); });
  wrap.addEventListener('change', () => { out.classList.toggle('wrap', wrap.checked); storageSet('hv-log-wrap', wrap.checked ? '1' : '0'); });
  toBottom.addEventListener('click', () => { out.scrollTop = out.scrollHeight; });

  load(true);
  return () => { alive = false; clearTimeout(timer); };
}
