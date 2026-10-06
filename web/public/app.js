// =============================================================================
//  画廊搬运台 · 前端
//  只做三件事：渲染服务端下发的任务规格、发请求、把 PowerShell 的日志流画出来。
//  不含任何业务判断（哪些项目该下载、怎么判重全在 .ps1 里），所以引擎改了这里不用跟着改。
// =============================================================================
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];

const GROUPS = ['日常', '补漏', '核对', '维护'];
const ICONS = {
  oneclick: 'i-bolt', dryrun: 'i-eye', netcheck: 'i-wifi', retry: 'i-refresh',
  monthImages: 'i-image', monthVideos: 'i-film', auditAll: 'i-shield', auditMonth: 'i-shield',
  status: 'i-gauge', missingOut: 'i-folder-search', dedupePreview: 'i-layers', dedupeApply: 'i-layers',
  kill: 'i-stop', cleanTs: 'i-broom',
};
const LEVEL_TEXT = { read: '只读', write: '会写盘', danger: '危险' };
const RUN_TEXT = { read: '运行', write: '开始执行', danger: '确认删除' };
const MAX_RENDER = 1500;

const state = {
  cfg: null, jobs: [], specs: {}, months: [], status: null,
  es: null, job: null, lastN: 0, sseFails: 0,
  pendingRun: null, autoScroll: true,
};

// -------------------------------------------------------------------- 基础设施
async function api(path, opts) {
  const res = await fetch(path, opts);
  let data = null;
  try { data = await res.json(); } catch { /* 非 JSON 响应 */ }
  if (!res.ok || (data && data.error)) throw new Error((data && data.error) || `HTTP ${res.status}`);
  return data;
}
function toast(msg, kind = '') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = msg;
  $('#toasts').appendChild(el);
  setTimeout(() => { el.style.opacity = '0'; el.style.transition = 'opacity .3s'; }, kind === 'err' ? 7000 : 4200);
  setTimeout(() => el.remove(), kind === 'err' ? 7600 : 4800);
}
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
function ago(ts) {
  if (!ts) return '';
  const s = Math.max(0, (Date.now() - ts) / 1000);
  if (s < 60) return `${Math.floor(s)}秒前`;
  if (s < 3600) return `${Math.floor(s / 60)}分钟前`;
  if (s < 86400) return `${Math.floor(s / 3600)}小时前`;
  return `${Math.floor(s / 86400)}天前`;
}

// ------------------------------------------------------------------ 渲染：外壳
function renderNav() {
  const nav = $('#nav');
  nav.innerHTML = GROUPS.map((g) => {
    const items = state.jobs.filter((j) => j.group === g);
    return `<div class="nav-group">${g}</div>` + items.map((j) =>
      `<a href="#g-${cssId(g)}" data-nav="${cssId(g)}"><svg class="ic"><use href="#${ICONS[j.key] || 'i-bolt'}"/></svg><span>${j.title}</span><span class="n">${items.length ? j.menu : ''}</span></a>`
    ).join('');
  }).join('') + `<div class="nav-group">本机</div><a href="#g-local" data-nav="local"><svg class="ic"><use href="#i-folder"/></svg><span>目录与文档</span><span class="n">14-16</span></a>`;
  $$('#nav a').forEach((a) => a.addEventListener('click', () => {
    $$('#nav a').forEach((x) => x.classList.remove('active'));
    a.classList.add('active');
  }));
}
const cssId = (s) => ({ '日常': 'daily', '补漏': 'fix', '核对': 'check', '维护': 'maint' })[s] || s;

function renderCards() {
  const host = $('#groups');
  host.innerHTML = GROUPS.map((g) => {
    const items = state.jobs.filter((j) => j.group === g);
    if (!items.length) return '';
    return `<section class="panel" id="g-${cssId(g)}">
      <h3 class="panel-title">${g}操作 <small>${items.length} 项 · 对应旧菜单 ${items.map((i) => i.menu).join(' / ')}</small></h3>
      <div class="grid">${items.map(cardHtml).join('')}</div>
    </section>`;
  }).join('');

  $$('[data-run]').forEach((btn) => {
    const key = btn.dataset.run;
    btn.addEventListener('click', () => requestRun(key));
  });
  $$('[data-local]').forEach((btn) => btn.addEventListener('click', () => localOp(btn.dataset.local, btn)));
}
function cardHtml(j) {
  const need = j.params.length ? '需选年月' : '';
  return `<article class="card level-${j.level}">
    <div class="card-head">
      <span class="card-icon"><svg><use href="#${ICONS[j.key] || 'i-bolt'}"/></svg></span>
      <h4>${j.title}</h4>
      <span class="card-key">菜单 ${j.menu}</span>
    </div>
    <p>${esc(j.desc)}</p>
    <div class="card-foot">
      <span class="badge ${j.level}">${LEVEL_TEXT[j.level]}</span>
      ${need ? `<span class="badge">${need}</span>` : ''}
      ${j.confirm ? `<span class="badge danger">需输入 ${j.confirm}</span>` : ''}
      <button class="btn ${j.level === 'danger' ? 'danger' : ''}" data-run="${j.key}">${RUN_TEXT[j.level]}</button>
    </div>
  </article>`;
}

function renderChips() {
  const s = state.status;
  if (!s) return;
  const items = [
    { k: '基线项目', v: s.baseline },
    { k: '待处理 pending', v: s.pending, alert: s.pending > 0 },
    { k: '产物项目', v: s.outProjects },
    { k: 'manifest', v: `${s.manifestRows} 行` },
    { k: '已知死链', v: s.deadLinks },
    { k: '上游仓库', v: s.repoCloned ? '已 clone' : '未 clone' },
  ];
  if (s.svc) {
    const fresh = s.svc.netCheckAt && (Date.now() - s.svc.netCheckAt < 300000);
    items.push({ k: '网络自检', v: fresh ? '5 分钟内已通' : '未跑/已过期' });
    if (s.svc.externalBusy) items.push({ k: '外部重活脚本', v: `${s.svc.externalBusy} 个在跑`, alert: true });
  }
  $('#chips').innerHTML = items.map((i) =>
    `<span class="chip${i.alert ? ' alert' : ''}">${i.k} <b>${i.v}</b></span>`).join('');
  $('#footPaths').textContent =
    `产物 ${s.paths.outDir}   |   基线 ${s.paths.baselineDir}   |   日志 ${s.paths.logDir}   |   PS ${state.cfg.psVersion}`;
  renderMonths();
  renderRing();
}
function renderMonths() {
  const host = $('#months');
  if (!host) return;
  if (!state.months.length) { host.innerHTML = '<span class="hint">基线目录里还没有可识别的 [yy-mm-dd] 项目</span>'; return; }
  host.innerHTML = state.months.map((m) =>
    `<button class="month" data-month="${m.year}-${m.month}"><b>${m.year}-${m.month}</b><span>${m.count} 个项目</span></button>`).join('');
  $$('#months .month').forEach((b) => b.addEventListener('click', () => {
    const [y, mo] = b.dataset.month.split('-');
    openParams(state.specs.monthImages, { year: y, month: mo });
  }));
}
function renderRing() {
  const s = state.status;
  if (!s || state.job?.status === 'running') return;
  const cover = s.baseline ? Math.min(100, Math.round(s.outProjects / s.baseline * 100)) : 0;
  $('#heroSide').style.display = '';
  $('.ring').style.setProperty('--p', cover);
  $('#ringNum').textContent = s.baseline;
  $('#ringLabel').innerHTML = `基线项目 · 产物覆盖 ${cover}%<br>pending ${s.pending} 项`;
}

// ------------------------------------------------------------------ 发起任务
function requestRun(key) {
  const spec = state.specs[key];
  if (!spec) return toast(`未知任务 ${key}`, 'err');
  if (state.status?.running) return toast(`已有任务在跑：${state.status.running.title}`, 'err');
  if (spec.params.length) return openParams(spec);
  if (spec.confirm) return openConfirm(spec, {});
  fire(spec, {});
}

let paramTarget = null;
function openParams(spec, preset = {}) {
  paramTarget = { spec, preset };
  $('#paramTitle').textContent = spec.title;
  $('#paramDesc').textContent = spec.desc;
  const years = [...new Set(state.months.map((m) => m.year))].sort().reverse();
  const ys = $('#selYear');
  ys.innerHTML = (years.length ? years : ['26', '25']).map((y) => `<option ${y === (preset.year || years[0]) ? 'selected' : ''}>${y}</option>`).join('');
  syncMonths(preset.month);
  $('#probeWrap').hidden = !spec.params.includes('probeDead');
  $('#chkProbe').checked = false;
  showModal('#paramModal');
}
function syncMonths(pick) {
  const y = $('#selYear').value;
  const list = state.months.filter((m) => m.year === y);
  const ms = $('#selMonth');
  ms.innerHTML = list.map((m) => `<option value="${m.month}" ${m.month === pick ? 'selected' : ''}>${m.month}</option>`).join('');
  const total = list.reduce((a, b) => a + b.count, 0);
  $('#monthMeta').textContent = `20${y} 年 · ${list.length} 个月份有基线 · 共 ${total} 个项目`;
}
$('#selYear')?.addEventListener('change', () => syncMonths());

let confirmTarget = null;
function openConfirm(spec, params, extra) {
  confirmTarget = { spec, params };
  $('#confirmTitle').textContent = `${spec.title} · 不可逆操作`;
  $('#confirmDesc').innerHTML = esc(spec.desc) + (extra ? `<br><br>${esc(extra)}` : '');
  $('#confirmWord').textContent = spec.confirm;
  $('#confirmInput').value = '';
  $('#confirmOk').disabled = true;
  showModal('#confirmModal');
  setTimeout(() => $('#confirmInput').focus(), 60);
}

async function fire(spec, params, confirmText) {
  try {
    const job = await api('/api/jobs', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key: spec.key, params, confirm: confirmText }),
    });
    refreshStatus();
    attach(job.id, job);
    toast(`已启动：${spec.title}`, 'ok');
  } catch (e) { toast(e.message, 'err'); }
}

async function localOp(what, btn) {
  const old = btn.disabled;
  btn.disabled = true;
  try {
    const r = await api('/api/local', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ what }) });
    setLocalResult(`已发出：${r.target || ''}${r.hint ? ' · ' + r.hint : ''}`, false);
    toast('本机已执行（若看不到窗口，按 Win+Tab 查全部窗口）', 'ok');
  } catch (e) {
    setLocalResult(`失败：${e.message}`, true);
    toast(e.message, 'err');
  }
  btn.disabled = old;
}
function setLocalResult(text, isErr) {
  const el = $('#localResult');
  if (!el) return;
  el.textContent = `本机操作 · ${new Date().toLocaleTimeString()} · ${text}`;
  el.classList.toggle('bad', !!isErr);
}

// ---------------------------------------------------------------- 日志流（SSE）
function attach(id, summary) {
  if (state.es) { state.es.close(); state.es = null; }
  state.job = summary || { id, title: '任务', level: 'read' };
  state.lastN = 0;
  clearLog();
  $('#dock').classList.remove('collapsed');
  $('#dockName').textContent = state.job.title || '运行日志';
  const badge = $('#dockBadge');
  badge.hidden = false;
  badge.className = `badge ${state.job.level || 'read'}`;
  badge.textContent = LEVEL_TEXT[state.job.level] || '日志';
  $('#logDl').onclick = () => { window.location.href = `/api/jobs/log?job=${encodeURIComponent(id)}`; };
  $('#jobStop').hidden = state.job.status !== 'running';
  setStatus(state.job.status === 'running' ? '执行中…' : '已结束');

  const es = new EventSource(`/api/stream?job=${encodeURIComponent(id)}&since=0`);
  state.es = es;
  es.addEventListener('meta', (e) => {
    const m = JSON.parse(e.data);
    state.job = { ...state.job, ...m };
    $('#dockName').textContent = m.title;
    $('#jobStop').hidden = m.status !== 'running';
    setStatus(m.status === 'running' ? '执行中…' : statusText(m.status));
  });
  es.addEventListener('lines', (e) => { for (const l of JSON.parse(e.data)) appendLine(l); });
  es.addEventListener('line', (e) => appendLine(JSON.parse(e.data)));
  es.addEventListener('end', (e) => {
    const m = JSON.parse(e.data);
    state.job = { ...state.job, ...m };
    $('#jobStop').hidden = true;
    setProgress(null);
    es.close();                       // 只关自己这条流，不碰可能已新建的 state.es
    if (state.es === es) state.es = null;
    setStatus(statusText(m.status));
    refreshStatus(true);
    if (m.status === 'done') toast(`${m.title}：完成`, 'ok');
    else if (m.status === 'killed') toast(`${m.title}：已停止`, 'warn');
    else toast(`${m.title}：异常结束（退出码 ${m.exitCode}）`, 'err');
  });
  es.onerror = () => {
    state.sseFails++;
    if (state.sseFails > 4) { es.close(); state.es = null; setStatus('日志连接中断（任务可能仍在跑）'); }
  };
  es.onopen = () => { state.sseFails = 0; };
}
const statusText = (s) => ({ running: '执行中…', done: '已完成', error: '异常结束', killed: '已停止' }[s] || '空闲');

function clearLog() { $('#log').innerHTML = ''; state.lastN = 0; draw.q = []; }

// 渲染必须攒批：整月下载会推几千~几万行，逐行 createElement + 读 scrollHeight/设 scrollTop
// = 每行强制一次同步布局，页面会越跑越卡（表现成“Web 比命令行慢”）。现在一帧只插一次、只滚一次。
const draw = { q: [], raf: 0 };
function appendLine(l) {
  if (l.n <= state.lastN) return;      // SSE 重连后按行号去重
  state.lastN = l.n;
  draw.q.push(l);
  if (!draw.raf) draw.raf = requestAnimationFrame(flushRender);
}
function flushRender() {
  draw.raf = 0;
  const batch = draw.q; draw.q = [];
  if (!batch.length) return;
  const log = $('#log');
  const frag = document.createDocumentFragment();
  for (const l of batch) {
    const row = document.createElement('span');
    row.className = `row ${classify(l)}`;
    const no = document.createElement('span');
    no.className = 'no';
    no.textContent = l.n;
    const tx = document.createElement('span');
    tx.textContent = l.t;
    row.append(no, tx);
    frag.appendChild(row);
    maybeProgress(l.t);
  }
  log.appendChild(frag);
  let over = log.childElementCount - MAX_RENDER;
  while (over-- > 0) log.removeChild(log.firstElementChild);
  if (state.autoScroll) log.scrollTop = log.scrollHeight;
  else $('#jumpLatest').hidden = false;
}
function maybeProgress(t) {
  if (t.indexOf('/') < 0) return;                       // 进度行一定带斜杠，先廉价筛掉绝大多数
  if (t.indexOf('进行中') < 0 && t.indexOf('project ') < 0 && !/[图视项分]\S*\s*\d+\s*\/\s*\d+/.test(t)) return;
  trackProgress(t);
}
function classify(l) {
  const t = l.t || '';
  if (l.s === 'err') return 'err';
  if (l.s === 'sys') return 'sys';
  const s = t.trim();
  if (/^={6,}$/.test(s)) return 'rule';
  if (/^--\s/.test(s) || /步骤 \d+\/\d+/.test(s)) return 'sect';
  if (/无失败项|全部齐全|齐全且完整/.test(s)) return 'ok';
  if (/FAIL|失败|错误|异常|不存在|拒绝|无法|超时/.test(s)) return 'err';
  if (/警告|冷却|退避|建议|未检测|需注意|Yellow/i.test(s)) return 'warn';
  if (/\bOK\b|成功|完成|已创建|已重建|=>/.test(s)) return 'ok';
  if (/SKIP|跳过|已存在|保持不变|无需处理/.test(s)) return 'dim';
  return '';
}
function trackProgress(text) {
  const m = /进行中\s*(\d+)\s*\/\s*(\d+)/.exec(text) || /project\s+(\d+)\s*\/\s*(\d+)/.exec(text);
  if (m) {
    const done = Number(m[1]), total = Number(m[2]);
    const extra = /在途\s*(\d+).*?窗口\s*(\d+)/.exec(text);
    setProgress({ done, total, meta: extra ? `在途 ${extra[1]} · 窗口 ${extra[2]}` : '' });
    return;
  }
  const v = /(\d+)\s*\/\s*(\d+)\s*个?/.exec(text);
  if (v && /图|视频|项目|分片|seg|img/i.test(text)) setProgress({ done: Number(v[1]), total: Number(v[2]), meta: text.trim().slice(0, 60) });
}
function setProgress(p) {
  const wrap = $('#dockProgressWrap');
  if (!p || !p.total) { wrap.hidden = true; $('#heroSide').style.display = ''; renderRing(); return; }
  wrap.hidden = false;
  const pct = Math.min(100, Math.round(p.done / p.total * 100));
  $('#dockBar').style.width = pct + '%';
  $('#dockMeta').textContent = `${p.done}/${p.total} · ${pct}%${p.meta ? ' · ' + p.meta : ''}`;
  $('.ring').style.setProperty('--p', pct);
  $('#ringNum').textContent = pct + '%';
  $('#ringLabel').textContent = (state.job?.title || '') + ' 进度';
}
function setStatus(text) { $('#dockStatus').textContent = text; }

// ------------------------------------------------------------------ 弹窗控制
function showModal(sel) { $('#scrim').classList.add('on'); $(sel).classList.add('on'); }
function hideModals() {
  $('#scrim').classList.remove('on');
  $$('.modal').forEach((m) => m.classList.remove('on'));
  paramTarget = null; confirmTarget = null;
}
$('#scrim').addEventListener('click', hideModals);
$$('[data-close]').forEach((b) => b.addEventListener('click', hideModals));
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hideModals(); });

$('#paramOk').addEventListener('click', () => {
  if (!paramTarget) return;
  const { spec, preset } = paramTarget;
  const params = {};
  if (spec.params.includes('year')) { params.year = $('#selYear').value; params.month = $('#selMonth').value; }
  if (spec.params.includes('probeDead')) params.probeDead = $('#chkProbe').checked;
  if (!params.year) params.year = preset.year;
  if (!params.month) params.month = preset.month;
  hideModals();
  if (spec.confirm) openConfirm(spec, params); else fire(spec, params);
});
$('#confirmInput').addEventListener('input', (e) => {
  $('#confirmOk').disabled = e.target.value !== (confirmTarget?.spec.confirm || '');
});
$('#confirmInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !$('#confirmOk').disabled) $('#confirmOk').click();
});
$('#confirmOk').addEventListener('click', () => {
  if (!confirmTarget || $('#confirmOk').disabled) return;
  const { spec, params } = confirmTarget;
  hideModals();
  fire(spec, params, spec.confirm);
});

// -------------------------------------------------------------------- 历史栏
function renderHistory(list) {
  const host = $('#history');
  if (!list.length) { host.innerHTML = '<li class="empty">还没有跑过任务</li>'; return; }
  host.innerHTML = list.slice(0, 8).map((j) =>
    `<li data-job="${j.id}" title="${j.title} · ${statusText(j.status)}"><i class="dot ${j.status}"></i><span>${j.title}</span><span class="t">${ago(j.endedAt || j.startedAt)}</span></li>`).join('');
  $$('#history li[data-job]').forEach((li) => li.addEventListener('click', () => {
    const j = list.find((x) => x.id === li.dataset.job);
    attach(li.dataset.job, j || { id: li.dataset.job });
  }));
}

// --------------------------------------------------------------------- 状态轮询
async function refreshStatus(force = false) {
  try {
    const s = await api('/api/status');
    state.status = s;
    state.months = s.months;
    if (!$('#dock').classList.contains('collapsed') && !state.job) { /* 保持提示 */ }
    renderChips();
    $('#svc').innerHTML = `<i class="dot done"></i>服务在线 · :${s.svc ? s.svc.port : '?'} · pid ${s.svc ? s.svc.pid : '?'}`;
    if (!state.job) {
      if (s.running) { attach(s.running.id, { ...s.running, status: 'running' }); }
    }
    return s;
  } catch (e) {
    $('#svc').innerHTML = '<i class="dot error"></i>服务离线';
    return null;
  }
}
async function refreshJobs() {
  try { const r = await api('/api/jobs'); renderHistory(r.jobs); } catch { /* 忽略 */ }
}

// ------------------------------------------------------------------------ 启动
$('#refreshBtn').addEventListener('click', async () => {
  await refreshStatus(true); await refreshJobs(); toast('状态已刷新', 'ok');
});
$('#dockToggle').addEventListener('click', () => $('#dock').classList.toggle('collapsed'));
$('#logClear').addEventListener('click', clearLog);
$('#jobStop').addEventListener('click', async () => {
  if (!state.job) return;
  try { await api('/api/jobs/stop', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ job: state.job.id }) }); }
  catch (e) { toast(e.message, 'err'); }
});
$('#log').addEventListener('scroll', () => {
  const log = $('#log');
  const nearBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
  state.autoScroll = nearBottom;
  $('#jumpLatest').hidden = nearBottom;
});
$('#jumpLatest').addEventListener('click', () => {
  state.autoScroll = true; $('#jumpLatest').hidden = true;
  $('#log').scrollTop = $('#log').scrollHeight;
});
$('#themeBtn').addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  localStorage.setItem('bdw-theme', next);
  $('#themeBtn use').setAttribute('href', next === 'dark' ? '#i-moon' : '#i-sun');
});

async function boot() {
  const saved = localStorage.getItem('bdw-theme');
  if (saved) {
    document.documentElement.dataset.theme = saved;
    $('#themeBtn use').setAttribute('href', saved === 'dark' ? '#i-moon' : '#i-sun');
  }
  try {
    const cfg = await api('/api/config');
    state.cfg = cfg;
    state.jobs = cfg.jobs;
    state.specs = Object.fromEntries(cfg.jobs.map((j) => [j.key, j]));
  } catch (e) {
    $('#svc').innerHTML = '<i class="dot error"></i>服务离线';
    return toast('连不上 Web 服务：' + e.message, 'err');
  }
  // 卡片先渲染（会覆写 #groups），再把月份面板追到后面，否则会被 innerHTML 清掉
  renderNav();
  renderCards();
  const monthsPanel = document.createElement('section');
  monthsPanel.className = 'panel';
  monthsPanel.id = 'g-months';
  monthsPanel.innerHTML = '<h3 class="panel-title">按月份进入 <small>点月份 = 直接打开该月的补图片面板（可切到补视频）</small></h3><div class="months" id="months"></div>';
  $('#groups').appendChild(monthsPanel);

  await refreshStatus(true);
  await refreshJobs();
  setInterval(() => { refreshStatus(); refreshJobs(); }, 6000);
  setInterval(renderHistoryFromCache, 30000);
}
function renderHistoryFromCache() {
  const host = $('#history');
  if (host.childElementCount > 1 && host.firstElementChild?.dataset.job) {
    $$('#history .t').forEach((el) => { /* 只刷新相对时间 */ });
    refreshJobs();
  }
}
boot();
