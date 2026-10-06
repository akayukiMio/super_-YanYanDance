// =============================================================================
//  画廊搬运台 —— 本地 Web 控制台（零依赖，只用 Node 内置模块）
//
//  设计前提（务必遵守，否则等于把 PROJECT.md §6 的坑重踩一遍）：
//    1) 本文件不含任何下载/判重/体检逻辑。所有真实动作 = 启动 powershell.exe 跑现有 .ps1。
//       引擎（run_all.ps1 的全局并发池、视频子进程串行、源站冷却退避…）一行都不重写。
//    2) 路径/参数唯一真值源仍是 config.ps1 —— 启动时调 web/export_config.ps1 取一次，不在这里复制常量。
//    3) 同一时刻只允许一个任务在跑：请求突发会重新触发源站冷却（坑 12），并发跑两个下载只会更慢。
//    4) 只绑 127.0.0.1。/api/local 会在本机启动 explorer / 建快捷方式，暴露到局域网前必须先加鉴权。
//    5) 传给 PowerShell 的 JSON 走 Base64（坑 9/14 的命令行引号地狱），参数绑定在 PS 侧用哈希表 splatting。
//  =============================================================================
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync, execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dir = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.resolve(__dir, '..');
const PUBLIC_DIR = path.join(__dir, 'public');
const RUN_JOB = path.join(__dir, 'run_job.ps1');
const EXPORT_CFG = path.join(__dir, 'export_config.ps1');
const LOCAL_OP = path.join(__dir, 'local_op.ps1');
const PROBE_BUSY = path.join(__dir, 'probe_busy.ps1');

const HOST = '127.0.0.1';
const PORT0 = Number(process.env.GALLERY_WEB_PORT || 8787);
const PS = 'powershell.exe'; // 必须是系统 5.1，不是 pwsh 7（PROJECT.md §0.5）
const OPEN_BROWSER = process.argv.includes('--open'); // 由 start-web.cmd 传入；手动 node 起服务时不弹浏览器
// 本机 Host 校验（挡 DNS rebinding：恶意域名解析到 127.0.0.1 也算跨站）。真的需要另一个入口时：
// set GALLERY_WEB_HOSTS=some-proxy-name,another  —— 只往白名单里加，不要直接删掉这段校验
const EXTRA_HOSTS = String(process.env.GALLERY_WEB_HOSTS || '').split(',').map((s) => s.trim()).filter(Boolean);

const MAX_LINES_PER_JOB = 40000; // 超出后丢头，防止整月下载把内存吃光
const HISTORY_CAP = 60;
const STATUS_TTL_MS = 5000;
const BOOT_AT = Date.now();
const SSE_FLUSH_MS = 40;              // 日志批量下发间隔：逐行 res.write 会把 4 万行变成 4 万次写入
const SSE_FLUSH_LINES = 400;         // 或攒够这么多行立即下发
const NETCHECK_CACHE_MS = 5 * 60000; // 网络自检结果缓存 5 分钟：预检最坏要等 4×12s，是“点了没动静”的主因之一
const APP_ID = 'gallery-web';

let CFG = null; // 来自 config.ps1，见 loadConfig()
let LISTEN_PORT = PORT0;
let lastNetCheckAt = 0;             // 上次网络自检“全部可达”的时间

// ---------------------------------------------------------------- 任务规格表
// level: read = 只读盘点，write = 会写盘/下载，danger = 会删文件或杀进程（前端红色 + 需输入确认词）
// params: 允许的入参白名单（其它一律 400），year/month 需两位数字
const JOBS = {
  oneclick: {
    title: '一键增量搬运', menu: '1', group: '日常', level: 'write',
    desc: '网络自检 → 拉取上游 → 识别新增 → 下载图片+视频 → 回收 pending',
    canStop: true, preNetCheck: true,
    build: () => [step('sync.ps1', { Run: true, Quiet: true })],
  },
  dryrun: {
    title: '只看上游有无更新', menu: '2', group: '日常', level: 'read',
    desc: 'git pull + 两级比对，全程不写盘、不下载',
    build: () => [step('sync.ps1', { DryRun: true })],
  },
  netcheck: {
    title: '网络连通性自检', menu: '3', group: '日常', level: 'read',
    desc: '分别探测图床 / m3u8 / 分片主机 / 仓库，判断要不要开代理',
    build: () => [netcheck()],
  },
  retry: {
    title: '重试 pending 未完成项', menu: '4', group: '补漏', level: 'write',
    desc: '只跑 state\\pending.txt 里列出的项目（磁盘续传判据，可反复点）',
    canStop: true, preNetCheck: true,
    build: () => [step('run_all.ps1', { ListFile: CFG.pendingFile, Quiet: true })],
  },
  monthImages: {
    title: '补某个月的图片', menu: '5', group: '补漏', level: 'write',
    desc: '按 [yy-mm] 前缀筛选，只跑图片，全局并发池',
    params: ['year', 'month'], canStop: true,
    build: (p) => [step('run_all.ps1', { Year: p.year, Month: p.month, ImagesOnly: true, Quiet: true })],
  },
  monthVideos: {
    title: '补某个月的视频', menu: '6', group: '补漏', level: 'write',
    desc: '只跑视频：每视频一个子进程 + 进程内串行（SegDegree 保持 2）',
    params: ['year', 'month'], canStop: true, preNetCheck: true,
    build: (p) => [step('run_all.ps1', { Year: p.year, Month: p.month, VideosOnly: true, Quiet: true })],
  },
  auditAll: {
    title: '全量体检', menu: '7', group: '核对', level: 'read',
    desc: '逐月校验齐全性 + 完整性（魔数 / ftyp / 零字节 / ts 残留），只读',
    build: () => [step('audit.ps1', { All: true })],
  },
  auditMonth: {
    title: '单月体检', menu: '8', group: '核对', level: 'read',
    desc: '只体检一个月份；勾选“实地探测缺口”可区分死链与可补',
    params: ['year', 'month', 'probeDead'],
    build: (p) => [step('audit.ps1', { Year: p.year, Month: p.month, ProbeDead: !!p.probeDead })],
  },
  status: {
    title: '项目状态速览', menu: '9', group: '核对', level: 'read',
    desc: '基线 / manifest / pending / 产物体积 / 在跑进程 全量统计（会扫全库，稍慢）',
    build: () => [step('tools/maint.ps1', { Action: 'Status' })],
  },
  missingOut: {
    title: '被删产物盘点（只读）', menu: '10', group: '核对', level: 'read',
    desc: '列出“HTML 还在、图库里已被删掉”的项目。只盘点，绝不恢复',
    build: () => [step('tools/maint.ps1', { Action: 'MissingOut' })],
  },
  dedupePreview: {
    title: '清理重复项目 · 预览', menu: '11', group: '维护', level: 'read',
    desc: '按画廊内容签名分组，列出会删谁留谁，不动任何文件',
    build: () => [step('tools/dedupe.ps1', {})],
  },
  dedupeApply: {
    title: '清理重复项目 · 执行删除', menu: '11', group: '维护', level: 'danger',
    desc: '删重复产物文件夹 + 基线 HTML + manifest 行（会先自动备份 manifest.bak.csv）',
    confirm: 'YES',
    build: () => [step('tools/dedupe.ps1', { Apply: true })],
  },
  kill: {
    title: '停止所有下载进程', menu: '12', group: '维护', level: 'danger',
    desc: '按命令行匹配杀掉 run_all / worker / sync / audit 进程（含子进程）',
    confirm: 'STOP',
    build: () => [step('tools/maint.ps1', { Action: 'Kill' })],
  },
  cleanTs: {
    title: '清理 ts 残留', menu: '13', group: '维护', level: 'write',
    desc: '删除中断留下的中间件 .ts（正常流程转 mp4 后即删）',
    build: () => [step('tools/maint.ps1', { Action: 'CleanTs' })],
  },
};

function step(script, params) { return { script, params }; }
function netcheck() { return step('tools/maint.ps1', { Action: 'NetCheck' }); }

// 诊断用（仅设 GALLERY_WEB_BENCH=1 时存在，不进 UI 任务表）：固定行数刷日志，量服务转发开销
if (process.env.GALLERY_WEB_BENCH === '1') {
  JOBS.bench = {
    title: '日志链路压测（诊断）', menu: '-', group: '维护', level: 'read',
    desc: '临时诊断项：跑 tools\\bench_log.ps1，对比命令行基线的 lines_per_sec',
    build: () => [step('tools/bench_log.ps1', { N: '40000', Mark: 'WEB' })],
  };
}

// ------------------------------------------------------------------ 工具函数
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
};

function send(res, code, body, headers = {}) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body);
  res.writeHead(code, { 'Content-Length': buf.length, 'Cache-Control': 'no-store', ...headers });
  res.end(buf);
}
function sendJson(res, code, obj) {
  send(res, code, JSON.stringify(obj), { 'Content-Type': 'application/json; charset=utf-8' });
}
function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('请求体过大')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch (e) { reject(new Error('请求体不是合法 JSON')); }
    });
    req.on('error', reject);
  });
}

function loadConfig() {
  const r = spawnSync(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', EXPORT_CFG], {
    cwd: PROJECT_ROOT, windowsVerbatimArguments: false, encoding: 'utf8', timeout: 60000, maxBuffer: 16 * 1024 * 1024,
  });
  if (r.error) throw r.error;
  const text = String(r.stdout || '').trim();
  const i = text.indexOf('{');
  if (i < 0) throw new Error(`export_config.ps1 退出码 ${r.status}，没有输出 JSON：\n${(text || r.stderr || '').slice(0, 600)}`);
  return JSON.parse(text.slice(i));
}

// ---------------------------------------------------------------- 状态与清单
let statusCache = { at: 0, data: null };

function countEntries(dir, kind, ext = '') {
  let n = 0;
  try {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) { if (kind === 'dir') n++; continue; }
      if (kind === 'file' && (!ext || e.name.toLowerCase().endsWith(ext))) n++;
    }
  } catch { /* 目录不存在当作 0 */ }
  return n;
}
function readNonEmptyLines(file) {
  try {
    return fs.readFileSync(file, 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  } catch { return []; }
}
function monthStats() {
  const map = new Map();
  let names = [];
  try { names = fs.readdirSync(CFG.baselineDir); } catch { return []; }
  for (const n of names) {
    const m = /^\[(\d{2})-(\d{2})-\d{2}\]/.exec(n);
    if (!m) continue;
    const key = `${m[1]}-${m[2]}`;
    map.set(key, (map.get(key) || 0) + 1);
  }
  return [...map.entries()].sort((a, b) => b[0].localeCompare(a[0]))
    .map(([ym, count]) => ({ year: ym.slice(0, 2), month: ym.slice(3), count }));
}
function getStatus(force = false) {
  const now = Date.now();
  if (!force && statusCache.data && now - statusCache.at < STATUS_TTL_MS) return statusCache.data;
  const pending = readNonEmptyLines(CFG.pendingFile);
  let manifestRows = 0;
  try {
    manifestRows = Math.max(0, fs.readFileSync(CFG.manifest, 'utf8').split('\n').filter((l) => l.trim()).length - 1);
  } catch { /* 还没 manifest */ }
  const data = {
    baseline: countEntries(CFG.baselineDir, 'file', '.html'),
    outProjects: countEntries(CFG.outDir, 'dir'),
    manifestRows,
    pending: pending.length,
    pendingList: pending.slice(0, 300),
    deadLinks: readNonEmptyLines(CFG.deadLinks).length,
    repoCloned: fs.existsSync(path.join(CFG.repoDir, '.git')),
    months: monthStats(),
    paths: { outDir: CFG.outDir, baselineDir: CFG.baselineDir, logDir: CFG.logDir, projectDir: CFG.projectDir },
    svc: { app: APP_ID, pid: process.pid, port: LISTEN_PORT, netCheckAt: lastNetCheckAt, externalBusy: busyProbe.data?.busy || 0 },
    running: current ? { id: current.id, key: current.key, title: current.title, level: current.level, canStop: !!JOBS[current.key]?.canStop } : null,
  };
  statusCache = { at: now, data };
  return data;
}

// ------------------------------------------------------------------ 任务执行
let SEQ = 0;
const jobs = new Map();
let current = null;
const sseClients = new Set();

class RingLog {
  constructor(max) { this.max = max; this.lines = []; this.dropped = 0; }
  push(line) {
    this.lines.push(line);
    if (this.lines.length > this.max) { this.lines.shift(); this.dropped++; }
  }
  sliceFrom(n) { return this.lines.slice(Math.max(0, n - this.dropped)); }
}

function buildChain(key, params) {
  const spec = JOBS[key];
  if (!spec) throw httpError(400, `未知任务: ${key}`);
  const allowed = new Set(spec.params || []);
  const clean = {};
  for (const [k, v] of Object.entries(params || {})) {
    if (!allowed.has(k)) throw httpError(400, `任务 ${key} 不接受参数 ${k}`);
    if (k === 'year' || k === 'month') {
      if (!/^\d{2}$/.test(String(v))) throw httpError(400, `${k} 必须是两位数字`);
      clean[k] = String(v);
    } else if (typeof v === 'boolean') clean[k] = v;
    else throw httpError(400, `${k} 参数类型不支持`);
  }
  if ((spec.params || []).includes('year') && (!clean.year || !clean.month)) {
    throw httpError(400, '该任务需要 year 与 month');
  }
  const chain = spec.build(clean);
  // 预检只在缓存过期时插到链首：NetCheck 四个主机串行探测，不可达时每台要等满超时
  let willCheckNet = false;
  if (spec.preNetCheck && Date.now() - lastNetCheckAt > NETCHECK_CACHE_MS) {
    chain.unshift(netcheck());
    willCheckNet = true;
  }
  return { chain, willCheckNet };
}
function httpError(code, msg) { const e = new Error(msg); e.httpCode = code; return e; }

// 跨进程查“系统里是否已有本工具的重活脚本在跑”（靠 web/probe_busy.ps1 按命令行匹配）。
// 结果缓存 3s：powershell 启动本身要几百毫秒，不能每次轮询都探一遍。
let busyProbe = { at: 0, data: null };
function probeBusy() {
  if (Date.now() - busyProbe.at < 3000) return busyProbe.data;
  let data = { busy: 0, procs: [] };
  try {
    const r = spawnSync(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', PROBE_BUSY], {
      cwd: PROJECT_ROOT, windowsVerbatimArguments: false, encoding: 'utf8', timeout: 20000,
    });
    const txt = String(r.stdout || '').trim();
    const i = txt.indexOf('{');
    if (i >= 0) data = JSON.parse(txt.slice(i));
  } catch { /* 探测本身出错不要拦住用户 */ }
  busyProbe = { at: Date.now(), data };
  return data;
}
function assertNoExternalJob() {
  const p = probeBusy();
  if (!p || !p.busy) return;
  const who = (p.procs || []).map((x) => `${x.script} PID=${x.pid}（${x.started}）`).join('；');
  throw httpError(409, `系统里已经有本工具的重活脚本在跑：${who}。两份下载并发会触发源站冷却（越跑越慢），请等它结束，或先用「停止所有下载进程」。`);
}

function startJob(key, params, confirmText) {
  const spec = JOBS[key];
  if (!spec) throw httpError(400, `未知任务: ${key}`);
  if (current && current.status === 'running') {
    throw httpError(409, `已有任务在跑：${current.title}（${current.id}）。源站对并发极敏感，请等它结束或先停止。`);
  }
  if (spec.confirm && String(confirmText || '') !== spec.confirm) {
    throw httpError(400, `该操作需要输入确认词 ${spec.confirm}`);
  }
  // 跳进程互斥：上面那道锁只在本进程内有效。端口顺延曾让同一台机器同时开着几个实例，
  // 或者用户同时在控制台菜单里跑着 run_all —— 两份下载并发 = 触发源站冷却（坑 4/12），越跑越慢。
  if (spec.level !== 'read') assertNoExternalJob();
  const { chain, willCheckNet } = buildChain(key, params);
  const b64 = Buffer.from(JSON.stringify(chain), 'utf8').toString('base64');

  const id = `${new Date().toISOString().slice(2, 19).replace(/[-:T]/g, '')}-${(++SEQ).toString().padStart(3, '0')}`;
  const job = {
    id, key, title: spec.title, level: spec.level, params: params || {},
    status: 'running', startedAt: Date.now(), endedAt: 0, exitCode: null,
    log: new RingLog(MAX_LINES_PER_JOB), clients: new Set(), child: null, killed: false,
    out: [], flushT: null, ranNetCheck: willCheckNet, netCheckFailed: false,
  };
  jobs.set(id, job);
  while (jobs.size > HISTORY_CAP) {
    const oldest = [...jobs.values()].find((j) => j.status !== 'running');
    if (!oldest) break;
    jobs.delete(oldest.id);
  }

  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', RUN_JOB, '-ChainB64', b64];
  const child = spawn(PS, args, {
    cwd: PROJECT_ROOT,
    windowsVerbatimArguments: false,
    stdio: ['ignore', 'pipe', 'pipe'],
    windowsHide: true,
  });
  job.child = child;
  current = job;
  statusCache = { at: 0, data: null };

  pushLine(job, { s: 'sys', t: `[web] 启动：powershell.exe -File web/run_job.ps1（${chain.length} 步）` });
  pumpStream(job, child.stdout, 'out');
  pumpStream(job, child.stderr, 'err');

  child.on('error', (e) => {
    pushLine(job, { s: 'err', t: `[web] 进程启动失败: ${e.message}` });
    finishJob(job, 'error', -1);
  });
  // 用 exit 而不是 close 判完成：Start-Process -NoNewWindow 起的孩子进程（视频 worker）会继承
  // 同一个 stdout 管道，close 要等所有继承句柄释放，表现为“父进程早退出了，任务还在转几分钟”。
  child.on('exit', (code) => finishJob(job, job.killed ? 'killed' : (code === 0 ? 'done' : 'error'), code));
  return job;
}

function pumpStream(job, stream, kind) {
  const decoder = new TextDecoder('utf-8', { fatal: false });
  let rest = '';
  stream.on('data', (chunk) => {
    rest += decoder.decode(chunk, { stream: true });
    const parts = rest.split(/\r?\n/);
    rest = parts.pop();
    for (const p of parts) pushLine(job, { s: kind, t: p });
  });
  stream.on('end', () => {
    rest += decoder.decode();
    if (rest) pushLine(job, { s: kind, t: rest });
  });
}
function pushLine(job, line) {
  const rec = { n: job.log.dropped + job.log.lines.length + 1, s: line.s, t: line.t };
  job.log.push(rec);
  if (job.ranNetCheck && !job.netCheckFailed && /不可达/.test(line.t)) job.netCheckFailed = true;
  if (!job.clients.size) return;
  job.out.push(rec);
  if (job.out.length >= SSE_FLUSH_LINES) flushJob(job);
  else if (!job.flushT) job.flushT = setTimeout(() => flushJob(job), SSE_FLUSH_MS);
}
// 一批一次 write：不批量就是每行一次 JSON.stringify + 一次 socket 写入，日志会把服务本身拖成瓶颈
function flushJob(job) {
  if (job.flushT) { clearTimeout(job.flushT); job.flushT = null; }
  if (!job.out.length) return;
  const batch = job.out.splice(0, job.out.length);
  const payload = JSON.stringify(batch);
  for (const res of job.clients) {
    try { res.write(`event: lines\ndata: ${payload}\n\n`); } catch { /* 客户端已断，交给 req.close 清理 */ }
  }
}
function finishJob(job, status, exitCode) {
  if (job.status !== 'running') return;
  job.status = status;
  job.endedAt = Date.now();
  job.exitCode = exitCode;
  if (job.ranNetCheck && status === 'done' && !job.netCheckFailed) lastNetCheckAt = Date.now();
  pushLine(job, { s: 'sys', t: `[web] 任务${status === 'done' ? '完成' : status === 'killed' ? '已停止' : '结束（异常）'}，退出码 ${exitCode}，用时 ${((job.endedAt - job.startedAt) / 1000).toFixed(1)}s` });
  if (current === job) current = null;
  statusCache = { at: 0, data: null };
  busyProbe.at = 0; // 任务收尾后重新探测，不要拿旧结果拦住下一个
  flushJob(job);
  for (const res of job.clients) writeSse(res, 'end', jobSummary(job));
  job.clients.clear();
}
function stopJob(job) {
  if (!job || job.status !== 'running' || !job.child) return false;
  job.killed = true;
  pushLine(job, { s: 'sys', t: '[web] 正在按进程树终止（含视频子进程）…' });
  // 必须杀整棵树：run_all 会另起 download_video_worker 子进程
  execFile('taskkill.exe', ['/PID', String(job.child.pid), '/T', '/F'], { windowsHide: true }, () => {});
  return true;
}
function jobSummary(job) {
  return {
    id: job.id, key: job.key, title: job.title, level: job.level, status: job.status,
    startedAt: job.startedAt, endedAt: job.endedAt, exitCode: job.exitCode,
    params: job.params, lines: job.log.lines.length + job.log.dropped, dropped: job.log.dropped,
  };
}

// --------------------------------------------------------------------- SSE
function writeSse(res, event, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}
function handleStream(req, res, job, since) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.write(': stream open\n\n');
  writeSse(res, 'meta', jobSummary(job));
  const from = Number.isFinite(since) ? since : 0;
  const backlog = job.log.sliceFrom(from);
  for (let i = 0; i < backlog.length; i += 200) {
    writeSse(res, 'lines', backlog.slice(i, i + 200));
  }
  if (job.status === 'running') {
    job.clients.add(res);
    sseClients.add(res);
    const close = () => { job.clients.delete(res); sseClients.delete(res); };
    req.on('close', close);
    res.on('error', close);
  } else {
    writeSse(res, 'end', jobSummary(job));
    res.end();
  }
}
setInterval(() => { for (const res of sseClients) { try { res.write(': ping\n\n'); } catch { /* 已断开 */ } } }, 15000).unref();

// ------------------------------------------------------------- 本机操作（14/15/16）
// 目录/文件直接交给 explorer.exe（它同时负责“用默认程序打开文件”）：
// 之先绕一层 PowerShell + Start-Process，错误全被 stdio:'ignore' 吞了，按了像“没反应”。
function localOp(what) {
  const docPath = fs.existsSync(path.join(CFG.projectDir, 'PROJECT.md'))
    ? path.join(CFG.projectDir, 'PROJECT.md')      // 本地开发环境：开真值源文档
    : path.join(CFG.projectDir, 'README.md');      // 只有仓库内容时退回 README
  const targets = {
    outdir: { path: CFG.outDir, kind: 'folder' },
    logdir: { path: CFG.logDir, kind: 'folder' },
    doc: { path: docPath, kind: 'file' },
    shortcut: { path: path.join(CFG.projectDir, 'start-web.cmd'), kind: 'lnk' },
  };
  const t = targets[what];
  if (!t) throw httpError(400, `未知的本机操作: ${what}`);
  if (!fs.existsSync(t.path)) throw httpError(404, `路径不存在: ${t.path}`);

  if (what === 'shortcut') {
    // 建 .lnk 需要 WScript.Shell COM，只能走 PowerShell；这里同步拿输出，失败就能回传给页面
    const r = spawnSync(PS, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', LOCAL_OP, '-What', 'shortcut', '-Path', t.path], {
      cwd: PROJECT_ROOT, windowsVerbatimArguments: false, encoding: 'utf8', timeout: 30000,
    });
    const detail = [String(r.stdout || '').trim(), String(r.stderr || '').trim()].filter(Boolean).join('\n');
    if (r.error) throw httpError(500, 'PowerShell 启动失败：' + r.error.message);
    if (r.status !== 0) throw httpError(500, detail || `创建快捷方式失败（退出码 ${r.status}）`);
    return { target: detail || t.path, hint: '到桌面看“画廊搬运台 Web”' };
  }

  // explorer.exe 成功时也常常返回非 0（Windows 的老脾气），只看 r.error 这种真起不来的情况
  const r = spawnSync('explorer.exe', [t.path], { windowsVerbatimArguments: false, timeout: 8000 });
  if (r.error) throw httpError(500, '无法调用 explorer.exe：' + r.error.message);
  return { target: t.path, hint: what === 'doc' ? '已交给默认程序' : '窗口可能被挡住，按 Win+Tab 看全部窗口' };
}

// ------------------------------------------------------------------ 静态资源
function serveStatic(res, urlPath) {
  const rel = urlPath === '/' ? 'index.html' : decodeURIComponent(urlPath.replace(/^\/+/, ''));
  const file = path.resolve(PUBLIC_DIR, rel);
  if (!file.startsWith(PUBLIC_DIR + path.sep) && file !== PUBLIC_DIR) return send(res, 403, 'forbidden');
  let buf;
  try { buf = fs.readFileSync(file); } catch { return send(res, 404, 'not found'); }
  send(res, 200, buf, { 'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream' });
}

// --------------------------------------------------------------------- 路由
const server = http.createServer(async (req, res) => {
  const host = String(req.headers.host || '');
  const hostname = host.replace(/:\d+$/, '');
  // 绑 127.0.0.1 已保证只有本机能连上；这层再挡 DNS rebinding（/api/local 会在本机开程序）
  const okHost = /^(127\.0\.0\.1|localhost|\[::1\])$/i.test(hostname) || EXTRA_HOSTS.includes(hostname);
  if (!okHost) {
    return sendJson(res, 403, { error: `只接受本机访问（Host: ${host} 不在白名单）。请直接访问 http://127.0.0.1:${LISTEN_PORT}/，或设 GALLERY_WEB_HOSTS 加白名单` });
  }
  const u = new URL(req.url, 'http://x');
  const p = u.pathname;
  try {
    if (p.startsWith('/api/')) {
      if (req.method === 'GET' && p === '/api/whoami') {
        // 单实例判定用：另一个进程靠它确认“占端口的确实是本工具的实例”
        return sendJson(res, 200, { app: APP_ID, pid: process.pid, port: LISTEN_PORT, startedAt: BOOT_AT, ps: CFG.psVersion });
      }
      if (req.method === 'GET' && p === '/api/status') return sendJson(res, 200, getStatus());
      if (req.method === 'GET' && p === '/api/config') {
        return sendJson(res, 200, { ...CFG, jobs: jobCatalog() });
      }
      if (req.method === 'GET' && p === '/api/jobs') {
        return sendJson(res, 200, { running: current ? current.id : null, jobs: [...jobs.values()].reverse().map(jobSummary) });
      }
      if (req.method === 'GET' && p === '/api/stream') {
        const job = jobs.get(u.searchParams.get('job') || '');
        if (!job) return sendJson(res, 404, { error: '没有这个任务' });
        return handleStream(req, res, job, Number(u.searchParams.get('since')));
      }
      if (req.method === 'GET' && p === '/api/jobs/log') {
        const job = jobs.get(u.searchParams.get('job') || '');
        if (!job) return send(res, 404, 'not found');
        const text = job.log.lines.map((l) => l.t).join('\r\n');
        return send(res, 200, Buffer.from('\ufeff' + text, 'utf8'), {
          'Content-Type': 'text/plain; charset=utf-8',
          'Content-Disposition': `attachment; filename="gallery_${job.id}.txt"`,
        });
      }
      if (req.method === 'POST' && p === '/api/jobs') {
        const body = await readBody(req);
        const job = startJob(String(body.key || ''), body.params, body.confirm);
        return sendJson(res, 202, jobSummary(job));
      }
      if (req.method === 'POST' && p === '/api/jobs/stop') {
        const body = await readBody(req);
        const job = jobs.get(String(body.job || ''));
        if (!job) return sendJson(res, 404, { error: '没有这个任务' });
        return sendJson(res, 200, { stopped: stopJob(job) });
      }
      if (req.method === 'POST' && p === '/api/local') {
        const body = await readBody(req);
        return sendJson(res, 200, { op: String(body.what || ''), ...localOp(String(body.what || '')) });
      }
      return sendJson(res, 404, { error: `未知接口 ${req.method} ${p}` });
    }
    if (req.method === 'GET') return serveStatic(res, p);
    return send(res, 405, 'method not allowed');
  } catch (e) {
    const code = e.httpCode || 500;
    if (code >= 500) console.error('[web] 处理失败:', e);
    return sendJson(res, code, { error: e.message || String(e) });
  }
});

function jobCatalog() {
  const bench = process.env.GALLERY_WEB_BENCH === '1';
  return Object.entries(JOBS)
    .filter(([key]) => key !== 'bench' || bench)
    .map(([key, s]) => ({
      key, title: s.title, menu: s.menu, group: s.group, level: s.level, desc: s.desc,
      params: s.params || [], confirm: s.confirm || null, canStop: !!s.canStop,
    }));
}

// --------------------------------------------------------------------- 启动
// 单实例：旧版本端口被占就递延顺延，结果同一台机器能同时开出好几个服务，
// 而“同时只跑一个任务”的锁是进程内的 —— 它们真会并发下载（源站一并发就冷却，越跑越慢）。
// 现在固定 PORT0：先查锁文件 + /api/whoami，已有实例就直接把浏览器指向它，自己退出。
function lockPath(port = PORT0) { return path.join(CFG.stateDir, `web_${port}.lock`); }   // 按端口分文件，否则换端口跑的诊断实例会踩掉真锁
function readLock(port = PORT0) { try { return JSON.parse(fs.readFileSync(lockPath(port), 'utf8')); } catch { return null; } }
function pidAlive(pid) { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } }
function writeLock(port) {
  try { fs.writeFileSync(lockPath(port), JSON.stringify({ app: APP_ID, pid: process.pid, port, at: Date.now() }), 'utf8'); }
  catch { /* 只影响“重复启动”检测，不影响服务本身 */ }
}
function sweepLocks() {
  // 扫掉死进程留下的锁文件（端口递延时代残留的 web_8888.lock 之类）
  let names = [];
  try { names = fs.readdirSync(CFG.stateDir).filter((n) => /^web_\d+\.lock$/.test(n)); } catch { return; }
  for (const n of names) {
    const port = Number(/\d+/.exec(n)[0]);
    const l = readLock(port);
    if (l && !pidAlive(l.pid)) { try { fs.rmSync(path.join(CFG.stateDir, n), { force: true }); } catch { /* 忽略 */ } }
  }
}
function openBrowser(port) {
  // explorer.exe 传 URL = 用默认浏览器打开，避开 cmd 的 start 引号坑（坑 9）
  spawn('explorer.exe', [`http://${HOST}:${port}/`], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
}
function httpJson(url, ms = 1500) {
  return new Promise((resolve) => {
    const req = http.get(url, { timeout: ms }, (res) => {
      let t = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { t += c; });
      res.on('end', () => { try { resolve(JSON.parse(t)); } catch { resolve(null); } });
    });
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
  });
}
async function findLiveInstance(port) {
  const l = readLock(port);
  if (l && l.app === APP_ID && l.port) {
    const w = await httpJson(`http://${HOST}:${l.port}/api/whoami`);
    if (w && w.app === APP_ID) return { port: l.port, pid: w.pid };
  }
  const w = await httpJson(`http://${HOST}:${port}/api/whoami`);
  if (w && w.app === APP_ID) return { port, pid: w.pid };
  return null;
}

async function main() {
  CFG = loadConfig();
  sweepLocks();
  if (process.env.GALLERY_WEB_FORCE !== '1') {
    const other = await findLiveInstance(PORT0);
    if (other) {
      console.log(`[web] 已有实例在跑：http://${HOST}:${other.port}/  (pid ${other.pid})`);
      console.log('[web] 本次不再开第二份（多个实例各有一套任务锁，会并发下载把源站打进冷却）。');
      console.log('[web] 确实要重启：先关掉旧窗口；或 set GALLERY_WEB_FORCE=1 再跑。');
      if (OPEN_BROWSER) openBrowser(other.port);
      process.exit(0);
    }
  }
  server.on('error', (err) => {
    if (err.code === 'EADDRINUSE') console.error(`[web] 端口 ${PORT0} 被其它程序占用（不是本工具的实例）。换端口：set GALLERY_WEB_PORT=8899`);
    else console.error('[web] 启动失败:', err.message);
    process.exit(1);
  });
  server.listen(PORT0, HOST, () => {
    LISTEN_PORT = PORT0;
    writeLock(PORT0);
    setInterval(() => writeLock(LISTEN_PORT), 20000).unref();
    const st = getStatus(true);
    console.log('');
    console.log('  画廊搬运台 · Web 控制台已启动');
    console.log(`  地址      http://${HOST}:${PORT0}/   (pid ${process.pid})`);
    if (EXTRA_HOSTS.length) console.log(`  Host 白名单附加 ${EXTRA_HOSTS.join(', ')}`);
    console.log(`  引擎      ${PS}（仅编排，逻辑仍在 sync/run_all/audit/maint/dedupe 内）`);
    console.log(`  产物目录  ${CFG.outDir}`);
    console.log(`  基线      ${st.baseline} 个 HTML | pending ${st.pending} 项 | manifest ${st.manifestRows} 行`);
    console.log('  提示      关掉本窗口即停止服务；控制台菜单 start.cmd 仍然可用');
    console.log('');
    if (OPEN_BROWSER) openBrowser(PORT0);
  });
  process.on('exit', () => {
    try { const l = readLock(LISTEN_PORT); if (l && l.pid === process.pid) fs.rmSync(lockPath(LISTEN_PORT), { force: true }); } catch { /* 忽略 */ }
  });
  process.on('SIGINT', () => process.exit(0));
}

main().catch((e) => {
  console.error('[web] 启动失败：' + (e.message || String(e)));
  process.exit(1);
});
