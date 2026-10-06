# 画廊搬运工具链

把上游仓库里的 QQ 收藏画廊页面批量搬成本地归档：**拉取仓库 → 识别新增 → 重命名为可读名 → 下载图片与 HLS 视频 → 校验齐全性**。

提供两个功能完全等价的入口：一个**本地浏览器控制台**（零依赖 Node + 实时日志），一个 **Windows 控制台菜单**（PowerShell）。

> **数据边界**：本仓库只包含工具链代码，**不含**任何抓取到的页面、图片或视频。
> 上游镜像 `repo/`、基线页面 `repo_html/`、运行期产物 `logs/`、状态台账 `state/` 全部 `.gitignore` 排除。
> 另外，`PROJECT.md` / `AGENTS.md` 等开发维护文档含本机路径与上游站点信息，**仅本地维护、不对外发布**。
> 画廊内容的版权归原作者与上游站点所有，本项目只是本地归档工具。

---

## 快速开始

```powershell
# 0) 依赖自检（需要 Windows PowerShell 5.1、git、ffmpeg；Web 控制台另需 node）
git --version ; ffmpeg -version ; node --version

# 1) 二选一启动
.\start-web.cmd        # 浏览器控制台：http://127.0.0.1:8787/
.\start.cmd            # 控制台交互菜单（按数字操作）

# 2) 纯命令行等价写法
.\tools\maint.ps1 -Action NetCheck    # 网络自检：判断要不要开代理
.\sync.ps1 -DryRun                    # 只看上游新增了什么（不写盘）
.\sync.ps1 -Run -Quiet                # 入库 + 下载新增项目（可反复执行，自动续跑）
.\audit.ps1 -All                      # 全量体检
```

首次使用若报执行策略错误：`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`。

## 功能一览

| 菜单 | 作用 | 菜单 | 作用 |
|---|---|---|---|
| 1 | 一键增量搬运（先自动网络自检） | 10 | 盘点「已被我删掉」的产物（只读，不恢复） |
| 2 | 只看上游有无更新（不写盘） | 11 | 清理库内重复项目（先预览，输入 YES 才真删） |
| 3 | 网络连通性自检 | 12 | 停止运行中的任务（含视频子进程） |
| 4 | 重试 pending 未完成项 | 13 | 清理 ts 残留 |
| 5 / 6 | 补某个月的图片 / 视频 | 14 / 15 / 16 | 打开产物目录 / 建桌面快捷方式 / 打开文档 |
| 7 / 8 | 全量体检 / 单月体检 | 17 | 启动 Web 控制台并打开浏览器 |
| 9 | 项目状态速览 | | |

**浏览器控制台额外提供**：指标胶囊条与覆盖率环、按月份快捷入口、SSE 实时日志（按语义着色 + 进度条解析 + 可下载）、任务历史回看、深色/浅色主题。

## 它是怎么判断「新增」的

两级比对，缺一不可：

1. **整页哈希**（规范化：去 BOM、CRLF→LF）命中 → 同一份文件，跳过。
2. **画廊内容签名**（标题 + 日期 + 图片 URL 序列 + 视频 URL 序列）命中 → 上游把同一画廊重复投稿成第二个 HTML，只往 manifest 记一行别名，**不建基线、不重下**。
3. 两者都不命中 → 真新增：解析标题/日期 → 生成 `[yy-mm-dd]标题` → 入基线 + 追加 manifest + 写入 pending。

产物形态：每个画廊一个文件夹，名同基线 HTML，内含 `0001.jpg…` 与 `video_01.mp4…`。断点续传基于磁盘文件状态（图片验魔数、视频验 mp4 非空且 188 字节对齐）。

## 目录结构

```
gallery/
├─ start.cmd / start-web.cmd        两个双击入口
├─ menu.ps1                        控制台交互菜单
├─ config.ps1                      ★中性参数真值源 + 共用解析与判重函数
├─ config.local.example.ps1        本机/来源参数模板（复制为 config.local.ps1 填真实值，不入库）
├─ sync.ps1                        ★命令行主入口：拉取 → 比对 → 入库 → pending → 可选下载
├─ run_all.ps1                     ★核心下载器（图片全局并发池 + 视频进程级并行 + 汇总报表）
├─ download_video_worker.ps1       视频子进程：串行下分片 → 拼 ts → ffmpeg 转 mp4
├─ audit.ps1                       体检（只读）：齐全性 + 完整性
├─ tools/                          fix_encoding / maint / dedupe / bench_log / make_icon
└─ web/                            浏览器控制台（Node 零依赖，只做编排与展示）
   ├─ server.mjs                   HTTP + 任务调度 + SSE 日志流
   ├─ run_job.ps1                  任务执行器（解 Base64 链 → 哈希表 splatting 调 .ps1）
   ├─ export_config.ps1            把 $Cfg 导成 JSON（路径真值仍在 config.ps1）
   ├─ probe_busy.ps1               跨进程查是否有重活脚本在跑（防并发下载）
   ├─ local_op.ps1                 本机动作：建桌面快捷方式等
   └─ public/                      index.html + theme.css + app.js（无 CDN，断网可用）
```

> 本地开发环境里还有 `PROJECT.md`（工作流 / 脚本职责 / 踩坑清单 / 状态基线）与 `AGENTS.md`，
> 因含本机绝对路径与上游站点信息，**不随本仓库发布**。

## 架构约定

Web 层**只做编排与展示**：每个动作都是启动 `powershell.exe -File web/run_job.ps1` 去调既有脚本。下载并发、画廊判重、体检规则一律不在 JavaScript 里重写——那些逻辑里全是踩坑成果（上游源站对并发极度敏感、图片必须走全局连接池、视频只能进程级串行）。

Web 服务只监听 `127.0.0.1:8787`，端口固定不递延，并有单实例锁与跨进程任务闸门：同一时刻只允许一个任务在跑。

## 已知坑

这两条最容易反复踩，也是改动前必须知道的：

1. **Windows PowerShell 5.1 读无 BOM 的 UTF-8 会按 GBK 解码** → 中文乱码甚至假语法错。改完任何 `.ps1` 必跑 `tools\fix_encoding.ps1`。
2. **上游视频源站极度厌恶并发**（每主机约只容忍 1 条流，突发后进入分钟级冷却且静默丢包）→ 不要同时跑两份下载，也不要反复重启下载进程。

## 依赖

- Windows PowerShell 5.1（系统自带，**不是** pwsh 7）
- `git`（`sync.ps1` 拉取上游）
- `ffmpeg`（视频 `.ts` → `.mp4` 无损转封装；缺失则保留 ts 并告警）
- `node`（仅浏览器控制台需要，零 npm 依赖；没有 node 用控制台菜单，功能不缺项）
