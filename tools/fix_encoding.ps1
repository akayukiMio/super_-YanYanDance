<#
.SYNOPSIS
    为项目内所有 .ps1 补 UTF-8 BOM。
.DESCRIPTION
    PowerShell 5.1 读取无 BOM 的 UTF-8 脚本时会按系统 ANSI(GBK) 解码，导致中文字面量乱码、
    甚至语法错误。**每次编辑过任何 .ps1 之后都应跑一次本脚本。**
.EXAMPLE
    .\tools\fix_encoding.ps1
#>
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$root = Split-Path -Parent $PSScriptRoot
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$n = 0
foreach ($f in [System.IO.Directory]::GetFiles($root, '*.ps1', [System.IO.SearchOption]::AllDirectories)) {
    if ($f -like '*\repo\*') { continue }   # 上游仓库内容不动
    $text = [System.IO.File]::ReadAllText($f, $utf8NoBom)
    [System.IO.File]::WriteAllText($f, $text, $utf8Bom)
    $n++
}
Write-Host ("BOM 已确保: {0} 个 .ps1（根目录 {1}）" -f $n, $root)
