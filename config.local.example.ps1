# =============================================================================
#  config.local.example.ps1 —— 本机/来源配置的模板（可公开，全是占位符）
#
#  用法：复制成 config.local.ps1 再填真实值。
#      Copy-Item config.local.example.ps1 config.local.ps1
#  config.ps1 会自动 dot-source 同目录下的 config.local.ps1（它被 .gitignore 排除）。
#  缺这个文件时工具仍能启动，但 sync/网络自检会因为缺参数直接报错提示你建它。
# =============================================================================

# ---- 上游仓库（sync.ps1 clone/pull 用）----
$Cfg['RepoUrl'] = 'https://github.com/<owner>/<repo>.git'

# ---- 产物根目录（每个画廊一个同名子文件夹）----
$Cfg['OutDir'] = 'D:\gallery-out'

# ---- 永不下载的资源（宣传视频等，URL 子串匹配）----
$Cfg['BlockM3u8'] = @()

# ---- 网络自检目标：K 是稳定键名（maint.ps1 按它判定，不要改成按主机名匹配）----
#   repo=仓库  img=图床  list=视频列表  seg=视频分片
$Cfg['NetTargets'] = @(
    @{ K = 'repo'; N = '上游仓库'; U = 'https://github.com/' }
    # @{ K = 'img';  N = '图床';     U = 'https://<图片主机>/favicon.ico' }
    # @{ K = 'list'; N = '视频列表'; U = 'https://<列表主机>/' }
    # @{ K = 'seg';  N = '视频分片'; U = 'https://<分片主机>/' }
)
