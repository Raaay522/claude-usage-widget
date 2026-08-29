<#
    安裝／移除 Claude Code 用量小工具的捷徑。

    用法：
        .\Install.ps1              建立桌面捷徑與開機自動啟動
        .\Install.ps1 -Uninstall   移除兩個捷徑（不刪程式檔）
#>

[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSCommandPath
$launcher  = Join-Path $root 'StartWidget.vbs'
$desktop   = [Environment]::GetFolderPath('Desktop')
$startup   = [Environment]::GetFolderPath('Startup')
$linkName  = 'Claude 用量小工具.lnk'
$desktopLink = Join-Path $desktop $linkName
$startupLink = Join-Path $startup $linkName

function New-Shortcut {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($Path)
    $sc.TargetPath       = $launcher
    $sc.WorkingDirectory = $root
    $sc.Description      = 'Claude Code 額度用量桌面小工具'
    $sc.IconLocation     = "$env:SystemRoot\System32\imageres.dll,109"
    $sc.Save()
    Write-Host "  已建立：$Path" -ForegroundColor Green
}

if ($Uninstall) {
    Write-Host '移除捷徑…' -ForegroundColor Cyan
    foreach ($p in @($desktopLink, $startupLink)) {
        if (Test-Path $p) {
            Remove-Item $p -Force
            Write-Host "  已移除：$p" -ForegroundColor Yellow
        } else {
            Write-Host "  不存在：$p" -ForegroundColor DarkGray
        }
    }
    Write-Host '完成。程式檔仍保留在' $root -ForegroundColor Cyan
    return
}

if (-not (Test-Path $launcher)) {
    throw "找不到啟動器：$launcher"
}

Write-Host '建立捷徑…' -ForegroundColor Cyan
New-Shortcut -Path $desktopLink
New-Shortcut -Path $startupLink

Write-Host ''
Write-Host '完成。' -ForegroundColor Cyan
Write-Host '  桌面捷徑：手動啟動用'
Write-Host '  開機啟動：下次登入 Windows 時自動出現'
Write-Host ''
Write-Host '要移除請執行： .\Install.ps1 -Uninstall' -ForegroundColor DarkGray
