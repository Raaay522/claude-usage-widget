<#
    Claude Code 用量桌面小工具
    - 讀取 ~/.claude/.credentials.json 內的 OAuth 存取權杖
    - 向 https://api.anthropic.com/api/oauth/usage 查詢額度使用率
    - 以半透明 WPF 視窗常駐桌面，可拖曳、可自訂更新間隔

    此查詢屬於帳號狀態讀取，不會消耗訂閱 token 額度。
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 狀態列圖示每次更新都會產生一個新的 icon handle，
# 不主動銷毀舊的會慢慢耗盡 GDI 資源，長時間執行後圖示會消失或畫面異常。
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class IconCleanup {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- 路徑與設定

$script:Root         = Split-Path -Parent $PSCommandPath
$script:ConfigPath   = Join-Path $script:Root 'config.json'
$script:LogPath      = Join-Path $script:Root 'widget.log'
$script:CachePath    = Join-Path $script:Root 'local-usage-cache.json'
$script:CredPath     = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:ProjectsRoot = Join-Path $env:USERPROFILE '.claude\projects'
$script:UsageUrl     = 'https://api.anthropic.com/api/oauth/usage'

. (Join-Path $script:Root 'LocalUsage.ps1')
. (Join-Path $script:Root 'SharedStore.ps1')

# 單一實例保護：開機自動啟動之後又手動點捷徑時，不要疊出第二個視窗
$script:Mutex = New-Object System.Threading.Mutex($false, 'ClaudeCodeUsageWidget.SingleInstance')
$script:HasMutex = $false
try {
    $script:HasMutex = $script:Mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # 前一個實例沒有正常結束就直接被關掉，接手即可
    $script:HasMutex = $true
}
if (-not $script:HasMutex) { exit 0 }

$script:Config = @{
    Left            = -1.0
    Top             = 48.0
    RefreshMinutes  = 5
    Topmost         = $true
    BackgroundAlpha = 250
    StatWindow      = 'session' # session = 本 5 小時；weekly = 本週；both = 兩個都顯示
    Theme           = 'auto' # auto = 跟隨 Windows 設定；light／dark 手動指定
    CloseToTray     = $true # 按 ✕ 時隱藏到狀態列，而不是真的結束
    StartHidden     = $false# 啟動時直接縮在狀態列，不跳出視窗
    TrayTipShown    = $false# 是否已經提示過「縮到狀態列了」
}

# 這兩個刻意固定、不做成選項：畫面高度有限，列太多會超出螢幕；
# 太久沒回報的機器留著也只是干擾判讀。
# 分組依據：name = 依 names.json 的名稱（多個 IP 對到同名會合併）；ip = 一個 IP 一列。
# 兩者在「一個 IP 一個名稱」時結果相同，差別只在有沒有合併。
$script:ViewMode      = 'name'

$script:MaxRows       = 5    # 最多列出幾台，超過的併成一列「其他 N 台」
$script:HideAfterDays = 30   # 超過這麼多天沒回報就不列出來

# ── 共享資料夾（寫死）────────────────────────────────────────
# 部署到新環境時只要改這一行。連不上時小工具會自動只顯示本機用量，
# 不會出錯也不會卡住，所以筆電帶出公司照樣能用。
$script:SharedFolder = 'T:\claude_usage'

<#
    取得這台電腦對外的 IPv4 位址。

    一律自動偵測，不接受手動指定 —— 手動填的值可能跟實際網路狀態對不上，
    白名單比對就會失準。排除 loopback 與 169.254.*（那是網路沒接通時
    系統自己給的暫時位址），多張網卡時挑路由優先度最高（InterfaceMetric 最小）的那張。

    這裡刻意不用 Get-NetIPConfiguration —— 它要 1.6 秒，Get-NetIPAddress 只要 20 毫秒。
#>
function Get-LocalIPv4 {
    try {
        $candidates = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })

        if ($candidates.Count -eq 1) { return [string]$candidates[0].IPAddress }

        if ($candidates.Count -gt 1) {
            $metrics = @{}
            try {
                foreach ($iface in Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop) {
                    $metrics[[int]$iface.InterfaceIndex] = [int]$iface.InterfaceMetric
                }
            } catch { }

            $best = $candidates | Sort-Object {
                $idx = [int]$_.InterfaceIndex
                if ($metrics.ContainsKey($idx)) { $metrics[$idx] } else { 9999 }
            } | Select-Object -First 1

            return [string]$best.IPAddress
        }
    } catch { }

    # 舊系統沒有 Get-NetIPAddress 時的退路
    try {
        $entry = [Net.Dns]::GetHostEntry([Net.Dns]::GetHostName())
        foreach ($addr in $entry.AddressList) {
            if ($addr.AddressFamily -eq 'InterNetwork') {
                $text = $addr.ToString()
                if ($text -notlike '127.*' -and $text -notlike '169.254.*') { return $text }
            }
        }
    } catch { }

    return ''
}

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path $script:LogPath) -and ((Get-Item $script:LogPath).Length -gt 200KB)) {
            Remove-Item $script:LogPath -Force -ErrorAction SilentlyContinue
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Import-Config {
    if (-not (Test-Path $script:ConfigPath)) { return }
    try {
        $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @($script:Config.Keys)) {
            $prop = $raw.PSObject.Properties[$key]
            if ($null -ne $prop -and $null -ne $prop.Value) { $script:Config[$key] = $prop.Value }
        }
    } catch {
        Write-Log "讀取設定失敗：$($_.Exception.Message)"
    }
}

function Export-Config {
    try {
        $obj = New-Object psobject
        foreach ($key in $script:Config.Keys) {
            Add-Member -InputObject $obj -MemberType NoteProperty -Name $key -Value $script:Config[$key]
        }
        $obj | ConvertTo-Json | Out-File -FilePath $script:ConfigPath -Encoding utf8
    } catch {
        Write-Log "寫入設定失敗：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- 資料取得

function Get-AccessToken {
    if (-not (Test-Path $script:CredPath)) {
        throw '找不到憑證檔，請先登入 Claude Code'
    }
    $cred = Get-Content $script:CredPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $token = $cred.claudeAiOauth.accessToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw '憑證檔內沒有存取權杖'
    }
    return $token
}

function Get-UsageData {
    $token = Get-AccessToken
    $headers = @{
        'Authorization'  = "Bearer $token"
        'anthropic-beta' = 'oauth-2025-04-20'
        'User-Agent'     = 'ClaudeUsageWidget/1.0'
    }
    return Invoke-RestMethod -Uri $script:UsageUrl -Headers $headers -Method Get -TimeoutSec 20 -ErrorAction Stop
}

function Get-LimitLabel {
    param($Limit)
    switch ($Limit.kind) {
        'session'       { return '5 小時區間' }
        'weekly_all'    { return '每週額度' }
        'weekly_scoped' {
            $name = $null
            if ($Limit.scope -and $Limit.scope.model) { $name = $Limit.scope.model.display_name }
            if ([string]::IsNullOrWhiteSpace($name)) { return '每週限定額度' }
            return "每週 $name 額度"
        }
        default { return [string]$Limit.kind }
    }
}

function Format-Reset {
    param([string]$Iso)
    if ([string]::IsNullOrWhiteSpace($Iso)) { return '本週尚未使用' }
    try {
        $reset = [datetimeoffset]::Parse($Iso).ToLocalTime()
        $span  = $reset - [datetimeoffset]::Now
        if ($span.TotalSeconds -le 0) { return '即將重置' }

        if ($span.TotalDays -ge 1) {
            $left = '{0} 天 {1} 小時' -f [int]$span.TotalDays, $span.Hours
        } elseif ($span.TotalHours -ge 1) {
            $left = '{0} 小時 {1} 分' -f [int]$span.TotalHours, $span.Minutes
        } else {
            $left = '{0} 分' -f [int]$span.TotalMinutes
        }

        if ($span.TotalDays -ge 1) {
            $when = $reset.ToString('MM/dd HH:mm')
        } else {
            $when = $reset.ToString('HH:mm')
        }
        return "$when 重置 · 剩 $left"
    } catch {
        return '重置時間無法解析'
    }
}

# ---------------------------------------------------------------- 佈景主題

<#
    兩套色票，取自 Claude 介面的深淺配色：淺色是米白底配深墨字，
    深色是暖調的深灰底配米白字，強調色都是 Claude 的橘。

    深色模式的進度條顏色會刻意調亮 —— 同一組藍／琥珀／紅在深底上會顯得太暗、
    彼此難以分辨。
#>
$script:Themes = @{
    light = @{
        Background  = 'FAF9F5'
        Border      = '#E3DFD5'
        Title       = '#1F1E1D'
        Text        = '#3D3B37'
        Muted       = '#8A8780'
        Faint       = '#B0ADA5'
        Track       = '#EAE7DE'
        Divider     = '#EDEAE2'
        Accent      = '#C96442'
        Error       = '#B91C1C'
        CloseHover  = '#D93A3A'
        BarLow      = '#2563EB'
        BarMid      = '#D97706'
        BarHigh     = '#DC2626'
        BarCrit     = '#B91C1C'
        RowSelf     = '#C96442'
        RowOther    = '#7C93B8'
        RowStale    = '#C9C6BE'
    }
    dark = @{
        Background  = '262624'
        Border      = '#403F3B'
        Title       = '#FAF9F5'
        Text        = '#D4D1CA'
        Muted       = '#918D85'
        Faint       = '#6E6A64'
        Track       = '#3A3936'
        Divider     = '#373633'
        Accent      = '#D97757'
        Error       = '#F87171'
        CloseHover  = '#F87171'
        BarLow      = '#60A5FA'
        BarMid      = '#FBBF24'
        BarHigh     = '#FB7185'
        BarCrit     = '#EF4444'
        RowSelf     = '#D97757'
        RowOther    = '#93A9C9'
        RowStale    = '#57554F'
    }
}

<#
    決定現在該用哪一套色票。設定值是 auto 時跟隨 Windows 的淺色／深色設定
    （AppsUseLightTheme：1 是淺色、0 是深色；讀不到就當淺色）。
#>
function Get-ThemeName {
    $mode = [string]$script:Config.Theme
    if ($mode -eq 'light' -or $mode -eq 'dark') { return $mode }

    try {
        $key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $value = (Get-ItemProperty -Path $key -Name 'AppsUseLightTheme' -ErrorAction Stop).AppsUseLightTheme
        if ([int]$value -eq 0) { return 'dark' }
    } catch { }

    return 'light'
}

function Get-Theme {
    return $script:Themes[(Get-ThemeName)]
}

# 依使用率決定顏色。刻意不使用紅綠對立，以照顧色覺差異：
# 低 = 藍、中 = 琥珀、高 = 深紅，並且百分比數字本身即為主要資訊。
function Get-BarColor {
    param([double]$Percent)
    $t = Get-Theme
    if ($Percent -ge 90) { return $t.BarCrit }
    if ($Percent -ge 75) { return $t.BarHigh }
    if ($Percent -ge 50) { return $t.BarMid }
    return $t.BarLow
}

# ---------------------------------------------------------------- 介面

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Code 用量"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="False"
        SizeToContent="Height"
        Width="296"
        ResizeMode="NoResize">
    <Border x:Name="Shell"
            CornerRadius="14"
            Background="#F2FBFCFD"
            BorderBrush="#D8DDE4"
            BorderThickness="1"
            Padding="16,14,16,13"
            Margin="10">
        <Border.Effect>
            <DropShadowEffect BlurRadius="18" ShadowDepth="2" Direction="270" Opacity="0.22" Color="#000000"/>
        </Border.Effect>
        <StackPanel>

            <Grid Margin="0,0,0,12">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Ellipse x:Name="Dot" Grid.Column="0" Width="9" Height="9" Fill="#C96442"
                         VerticalAlignment="Center" Margin="0,0,8,0"/>
                <TextBlock x:Name="TitleText" Grid.Column="1" Text="Claude Code 用量"
                           FontFamily="Microsoft JhengHei UI" FontSize="13" FontWeight="SemiBold"
                           Foreground="#1A1D21" VerticalAlignment="Center"/>
                <!-- Background 必須是 Transparent：沒有背景的 TextBlock 只有文字筆畫
                     本身接得到滑鼠事件，11px 的圖示會小到幾乎點不中 -->
                <TextBlock x:Name="BtnClose" Grid.Column="2" Text="&#xE711;"
                           FontFamily="Segoe MDL2 Assets" FontSize="11"
                           Foreground="#9AA3AE" VerticalAlignment="Center"
                           Background="Transparent" Padding="8,5,3,5"
                           Cursor="Hand" ToolTip="關閉小工具"/>
            </Grid>

            <StackPanel x:Name="Bars"/>

            <StackPanel x:Name="MachinesSection" Visibility="Collapsed">
                <Border x:Name="MachinesDivider" BorderBrush="#EAEEF2" BorderThickness="0,1,0,0" Margin="0,3,0,0" Padding="0,10,0,0">
                    <TextBlock x:Name="MachinesTitle" Text="本 5 小時各台佔用（估算）"
                               FontFamily="Microsoft JhengHei UI" FontSize="10.5"
                               Foreground="#8B95A1"/>
                </Border>
                <StackPanel x:Name="Machines" Margin="0,9,0,2"/>
            </StackPanel>

            <TextBlock x:Name="ErrorText" Text="" TextWrapping="Wrap"
                       FontFamily="Microsoft JhengHei UI" FontSize="11"
                       Foreground="#B91C1C" Margin="0,2,0,8" Visibility="Collapsed"/>

            <Border x:Name="FooterDivider" BorderBrush="#EAEEF2" BorderThickness="0,1,0,0" Margin="0,4,0,0" Padding="0,9,0,0">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="StatusText" Grid.Column="0" Text="載入中…"
                               FontFamily="Microsoft JhengHei UI" FontSize="10.5"
                               Foreground="#8B95A1" VerticalAlignment="Center"/>
                    <TextBlock x:Name="BtnRefresh" Grid.Column="1" Text="&#xE72C;"
                               FontFamily="Segoe MDL2 Assets" FontSize="12"
                               Foreground="#8B95A1" VerticalAlignment="Center"
                               Background="Transparent" Padding="8,5,3,5"
                               Cursor="Hand" ToolTip="立即更新"/>
                </Grid>
            </Border>

        </StackPanel>
    </Border>
</Window>
'@

Import-Config

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$shell           = $window.FindName('Shell')
$dot             = $window.FindName('Dot')
$titleText       = $window.FindName('TitleText')
$machinesDivider = $window.FindName('MachinesDivider')
$footerDivider   = $window.FindName('FooterDivider')
$bars            = $window.FindName('Bars')
$machinesSection = $window.FindName('MachinesSection')
$machinesTitle   = $window.FindName('MachinesTitle')
$machines        = $window.FindName('Machines')
$errorText       = $window.FindName('ErrorText')
$statusText      = $window.FindName('StatusText')
$btnClose        = $window.FindName('BtnClose')
$btnRefresh      = $window.FindName('BtnRefresh')

# 視窗本身保持不透明，僅讓外框背景色帶 alpha，
# 這樣底下的畫面會微微透出，但文字與進度條維持全實心、不會糊掉。
$window.Topmost = [bool]$script:Config.Topmost

function Set-ShellBackground {
    param([int]$Alpha)
    $hex = (Get-Theme).Background
    $r = [Convert]::ToByte($hex.Substring(0, 2), 16)
    $g = [Convert]::ToByte($hex.Substring(2, 2), 16)
    $b = [Convert]::ToByte($hex.Substring(4, 2), 16)
    $color = [Windows.Media.Color]::FromArgb($Alpha, $r, $g, $b)
    $shell.Background = New-Object Windows.Media.SolidColorBrush($color)
}

<#
    把目前色票套到所有「不會每次重畫」的元件上。

    進度條那些是每次更新時重新產生的，會自己拿到新色票，
    這裡只需要處理 XAML 裡寫死的靜態元件。
#>
function Set-WidgetTheme {
    $t = Get-Theme

    Set-ShellBackground ([int]$script:Config.BackgroundAlpha)
    $shell.BorderBrush = $t.Border

    $dot.Fill                  = $t.Accent
    $titleText.Foreground      = $t.Title
    $btnClose.Foreground       = $t.Muted
    $btnRefresh.Foreground     = $t.Muted
    $statusText.Foreground     = $t.Muted
    $errorText.Foreground      = $t.Error
    $machinesTitle.Foreground  = $t.Muted
    $machinesDivider.BorderBrush = $t.Divider
    $footerDivider.BorderBrush   = $t.Divider
}

$script:BarWidth = 264.0

function New-UsageBar {
    param(
        [string]$Label,
        [double]$Percent,
        [string]$Caption,
        [bool]$IsLast
    )

    $block = New-Object Windows.Controls.StackPanel
    if ($IsLast) { $block.Margin = '0,0,0,2' } else { $block.Margin = '0,0,0,13' }

    # 標題列：名稱靠左、百分比靠右
    $head = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $c1.Width = 'Auto'
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c3 = New-Object Windows.Controls.ColumnDefinition
    $c3.Width = 'Auto'
    $head.ColumnDefinitions.Add($c1)
    $head.ColumnDefinitions.Add($c2)
    $head.ColumnDefinitions.Add($c3)

    $theme = Get-Theme

    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $Label
    $name.FontFamily = 'Microsoft JhengHei UI'
    $name.FontSize = 11.5
    $name.Foreground = $theme.Text
    [Windows.Controls.Grid]::SetColumn($name, 0)

    $value = New-Object Windows.Controls.TextBlock
    $value.Text = '{0}%' -f [int][math]::Round($Percent)
    $value.FontFamily = 'Consolas'
    $value.FontSize = 12.5
    $value.FontWeight = 'Bold'
    $value.Foreground = (Get-BarColor $Percent)
    [Windows.Controls.Grid]::SetColumn($value, 2)

    $head.Children.Add($name) | Out-Null
    $head.Children.Add($value) | Out-Null
    $block.Children.Add($head) | Out-Null

    # 進度軌 + 進度條
    $track = New-Object Windows.Controls.Border
    $track.Height = 7
    $track.CornerRadius = 4
    $track.Background = $theme.Track
    $track.Margin = '0,6,0,0'
    $track.HorizontalAlignment = 'Left'
    $track.Width = $script:BarWidth

    $fill = New-Object Windows.Controls.Border
    $fill.Height = 7
    $fill.CornerRadius = 4
    $fill.Background = (Get-BarColor $Percent)
    $fill.HorizontalAlignment = 'Left'

    if ($Percent -le 0) {
        # 0% 時整條留白，不畫殘留的小色點
        $fill.Visibility = 'Collapsed'
    } else {
        $ratio = [math]::Min(100.0, $Percent) / 100.0
        $fill.Width = [math]::Max(7.0, $script:BarWidth * $ratio)
    }

    $track.Child = $fill
    $block.Children.Add($track) | Out-Null

    $cap = New-Object Windows.Controls.TextBlock
    $cap.Text = $Caption
    $cap.FontFamily = 'Microsoft JhengHei UI'
    $cap.FontSize = 10.5
    $cap.Foreground = $theme.Muted
    $cap.Margin = '0,5,0,0'
    $block.Children.Add($cap) | Out-Null

    return $block
}

function Format-Tokens {
    param([double]$Value)
    if ($Value -ge 1000000000) { return ('{0:N1}B' -f ($Value / 1000000000)) }
    if ($Value -ge 1000000)    { return ('{0:N1}M' -f ($Value / 1000000)) }
    if ($Value -ge 1000)       { return ('{0:N0}K' -f ($Value / 1000)) }
    return ('{0:N0}' -f $Value)
}

<#
    畫出單一台電腦的佔用列。

    Percent 是「這台估計吃掉帳號額度的幾個百分點」，不是它佔全體的比例；
    這樣三台的數字加起來就會等於畫面上方的帳號總用量，比較好對照。
#>
function New-MachineRow {
    param(
        [string]$Name,
        [double]$Percent,
        [double]$ShareRatio,
        [bool]$IsSelf,
        [bool]$IsStale,
        [string]$Caption
    )

    $block = New-Object Windows.Controls.StackPanel
    $block.Margin = '0,0,0,9'

    $head = New-Object Windows.Controls.Grid
    $cName = New-Object Windows.Controls.ColumnDefinition
    $cName.Width = 'Auto'
    $cGap = New-Object Windows.Controls.ColumnDefinition
    $cVal = New-Object Windows.Controls.ColumnDefinition
    $cVal.Width = 'Auto'
    $head.ColumnDefinitions.Add($cName)
    $head.ColumnDefinitions.Add($cGap)
    $head.ColumnDefinitions.Add($cVal)

    $theme = Get-Theme

    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $(if ($IsSelf) { "$Name（你）" } else { $Name })
    $label.FontFamily = 'Microsoft JhengHei UI'
    $label.FontSize = 11
    $label.TextTrimming = 'CharacterEllipsis'
    if ($IsStale) {
        $label.Foreground = $theme.Faint
    } elseif ($IsSelf) {
        $label.Foreground = $theme.Title
        $label.FontWeight = 'SemiBold'
    } else {
        $label.Foreground = $theme.Text
    }
    [Windows.Controls.Grid]::SetColumn($label, 0)

    $value = New-Object Windows.Controls.TextBlock
    $value.Text = '{0:N1}%' -f $Percent
    $value.FontFamily = 'Consolas'
    $value.FontSize = 11.5
    $value.Foreground = $(if ($IsStale) { $theme.Faint } else { $theme.Text })
    [Windows.Controls.Grid]::SetColumn($value, 2)

    $head.Children.Add($label) | Out-Null
    $head.Children.Add($value) | Out-Null
    $block.Children.Add($head) | Out-Null

    # 長條畫的是「這台佔全體的比例」，比純百分點更容易看出誰是大戶
    $track = New-Object Windows.Controls.Border
    $track.Height = 5
    $track.CornerRadius = 3
    $track.Background = $theme.Track
    $track.Margin = '0,5,0,0'
    $track.HorizontalAlignment = 'Left'
    $track.Width = $script:BarWidth

    $fill = New-Object Windows.Controls.Border
    $fill.Height = 5
    $fill.CornerRadius = 3
    $fill.HorizontalAlignment = 'Left'
    if ($IsStale) {
        $fill.Background = $theme.RowStale
    } elseif ($IsSelf) {
        # 自己那列用 Claude 的橘，跟其他人一眼分得開
        $fill.Background = $theme.RowSelf
    } else {
        $fill.Background = $theme.RowOther
    }

    if ($ShareRatio -le 0) {
        $fill.Visibility = 'Collapsed'
    } else {
        $fill.Width = [math]::Max(5.0, $script:BarWidth * [math]::Min(1.0, $ShareRatio))
    }
    $track.Child = $fill
    $block.Children.Add($track) | Out-Null

    if ($Caption) {
        $cap = New-Object Windows.Controls.TextBlock
        $cap.Text = $Caption
        $cap.FontFamily = 'Microsoft JhengHei UI'
        $cap.FontSize = 10
        $cap.Foreground = $theme.Faint
        $cap.Margin = '0,4,0,0'
        # 合併多個 IP 時這行會很長，讓它換行而不是被切掉
        $cap.TextWrapping = 'Wrap'
        $block.Children.Add($cap) | Out-Null
    }

    return $block
}

$script:LocalWeeklyTokens = 0.0

<#
    算出本機用量、回報到共享資料夾，再把所有機器的佔用畫出來。

    歸因方式：API 只給得出「整個帳號用了幾 %」，給不出是哪台用的。
    所以各台先各自算出自己在同一個時間視窗內產生的用量（換算成 USD 當量），
    再依各台佔全體的比例，把帳號總用量分攤下去。

    這是估算，不是官方數字 —— Anthropic 沒有公開額度百分比的實際計算權重，
    這裡用公開定價當代理指標。相對大小可信，絕對值僅供參考。
#>
<#
    檢查共享資料夾現在能不能用。

    直接對連不上的 UNC 路徑呼叫 Test-Path 會等到 SMB 自己逾時 —— 實測卡了 8 秒，
    這段時間整個視窗是凍住的。所以先用 1.2 秒逾時的 TCP 探測確認主機可達，
    不可達就直接判定為離線，不去碰檔案系統。
#>
function Test-SharedFolderAvailable {
    $folder = $script:SharedFolder
    if ([string]::IsNullOrWhiteSpace($folder)) { return $false }

    # 映射磁碟機（例如 T:\）背後也是網路位置，斷線時一樣會卡。
    # 先查出它對應的 UNC，後面才有主機名可以探測。
    # 注意這裡另存一個變數：探測用解析出來的主機，但最後檢查的仍是原本那個路徑，
    # 否則會變成檢查分享的根目錄，子資料夾不存在也會被判定為正常。
    $probeTarget = $folder
    if ($folder -match '^([A-Za-z]):') {
        $letter = $matches[1] + ':'
        try {
            $conn = Get-CimInstance Win32_NetworkConnection -Filter "LocalName='$letter'" -ErrorAction Stop
            if ($conn -and $conn.RemoteName) { $probeTarget = [string]$conn.RemoteName }
        } catch { }
    }

    if ($probeTarget -match '^\\\\([^\\]+)') {
        $server = $matches[1]
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $async = $client.BeginConnect($server, 445, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(1200)) { return $false }
            $client.EndConnect($async)
        }
        catch { return $false }
        finally { if ($client) { $client.Close() } }
    }

    try { return [bool](Test-Path -LiteralPath $folder -ErrorAction SilentlyContinue) }
    catch { return $false }
}

<#
    連不上共享資料夾時，改為呈現本機自己的用量。

    這不是錯誤狀態 —— 筆電帶出公司、NAS 沒開機都會走到這裡，
    所以用中性的說法呈現，不用紅字嚇人。
#>
function Show-LocalOnlySummary {
    param([double]$SessionTokens)

    $theme = Get-Theme
    $machines.Children.Clear()
    $machinesTitle.Text = '本機用量'

    foreach ($row in @(
        @{ Label = '本 5 小時'; Value = (Format-Tokens $SessionTokens) },
        @{ Label = '本週';      Value = (Format-Tokens $script:LocalWeeklyTokens) }
    )) {
        $grid = New-Object Windows.Controls.Grid
        $c1 = New-Object Windows.Controls.ColumnDefinition
        $c2 = New-Object Windows.Controls.ColumnDefinition
        $c2.Width = 'Auto'
        $grid.ColumnDefinitions.Add($c1)
        $grid.ColumnDefinitions.Add($c2)
        $grid.Margin = '0,0,0,6'

        $label = New-Object Windows.Controls.TextBlock
        $label.Text = $row.Label
        $label.FontFamily = 'Microsoft JhengHei UI'
        $label.FontSize = 11
        $label.Foreground = $theme.Text
        [Windows.Controls.Grid]::SetColumn($label, 0)

        $value = New-Object Windows.Controls.TextBlock
        $value.Text = $row.Value + ' tokens'
        $value.FontFamily = 'Consolas'
        $value.FontSize = 11.5
        $value.Foreground = $theme.Text
        [Windows.Controls.Grid]::SetColumn($value, 1)

        $grid.Children.Add($label) | Out-Null
        $grid.Children.Add($value) | Out-Null
        $machines.Children.Add($grid) | Out-Null
    }

    $note = New-Object Windows.Controls.TextBlock
    $note.Text = '未連上共享資料夾，只顯示這台的數字'
    $note.FontFamily = 'Microsoft JhengHei UI'
    $note.FontSize = 10
    $note.Foreground = $theme.Faint
    $note.TextWrapping = 'Wrap'
    $note.Margin = '0,2,0,0'
    $machines.Children.Add($note) | Out-Null

    $machinesSection.Visibility = 'Visible'
}

<#
    把分組結果畫成一列一列。

    $Period 決定看哪個區間的數字（Session＝本 5 小時、Weekly＝本週），
    兩個區間共用同一套排版，只是取的欄位與帳號百分比不同。
#>
function Add-BreakdownRows {
    param(
        $Rows,
        $AccountPercent,
        [ValidateSet('Session', 'Weekly')]
        [string]$Period
    )

    $costField   = $Period + 'Cost'
    $tokensField = $Period + 'Tokens'

    $totalCost = 0.0
    foreach ($r in @($Rows)) { $totalCost += [double]$r.$costField }

    $sorted = @($Rows | Sort-Object -Property $costField -Descending)

    # 台數多的時候視窗會被撐得很高，超過上限的併成一列，
    # 但本機那一列一定保留，否則自己反而看不到自己。
    $maxRows = $script:MaxRows
    $overflow = @()
    if ($maxRows -gt 0 -and $sorted.Count -gt $maxRows) {
        $kept = @()
        $rest = @()
        foreach ($r in $sorted) {
            # 一律用 IP 認自己：名字由 names.json 決定，不同機器可能同名
            $isSelfRow = ($r.IPs -contains $script:LocalIP)
            if ($kept.Count -lt $maxRows -or $isSelfRow) { $kept += $r } else { $rest += $r }
        }
        $sorted = $kept
        $overflow = $rest
    }

    foreach ($r in $sorted) {
        $ratio = 0.0
        if ($totalCost -gt 0) { $ratio = [double]$r.$costField / $totalCost }

        $pct = 0.0
        if ($null -ne $AccountPercent) { $pct = [double]$AccountPercent * $ratio }

        $isSelf = ($r.IPs -contains $script:LocalIP)

        $where = $r.Detail
        if ($r.IsStale) {
            $age = $r.MinAgeMinutes
            if ($null -eq $age -or [double]::IsInfinity([double]$age)) {
                $caption = '{0} · 未回報' -f $where
            } else {
                $caption = '{0} · 已 {1:N0} 分鐘未回報' -f $where, $age
            }
        } else {
            $caption = '{0} · {1} tokens' -f $where, (Format-Tokens ([double]$r.$tokensField))
        }
        $caption = $caption.TrimStart(' ', [char]0x00B7)

        $row = New-MachineRow -Name $r.Title -Percent $pct -ShareRatio $ratio `
            -IsSelf $isSelf -IsStale $r.IsStale -Caption $caption
        $machines.Children.Add($row) | Out-Null
    }

    if ($overflow.Count -gt 0) {
        $restCost = 0.0
        $restTokens = 0.0
        foreach ($r in $overflow) {
            $restCost   += [double]$r.$costField
            $restTokens += [double]$r.$tokensField
        }

        $ratio = 0.0
        if ($totalCost -gt 0) { $ratio = $restCost / $totalCost }
        $pct = 0.0
        if ($null -ne $AccountPercent) { $pct = [double]$AccountPercent * $ratio }

        $row = New-MachineRow -Name ('其他 {0} 台' -f $overflow.Count) -Percent $pct -ShareRatio $ratio `
            -IsSelf $false -IsStale $true -Caption ('合計 {0} tokens' -f (Format-Tokens $restTokens))
        $machines.Children.Add($row) | Out-Null
    }
}

function Update-MachineBreakdown {
    param(
        $SessionPercent,
        $WeeklyPercent,
        [string]$SessionReset,
        [string]$WeeklyReset
    )

    $folder = $script:SharedFolder

    # 時間視窗一律從 API 給的重置時間往回推，
    # 這樣每台電腦切出來的區間界線完全一致，加總才有意義。
    $now = [datetime]::UtcNow
    $sessionStart = $now.AddHours(-5)
    if (-not [string]::IsNullOrWhiteSpace($SessionReset)) {
        try { $sessionStart = ([datetimeoffset]$SessionReset).UtcDateTime.AddHours(-5) } catch { }
    }
    $weeklyStart = $now.AddDays(-7)
    if (-not [string]::IsNullOrWhiteSpace($WeeklyReset)) {
        try { $weeklyStart = ([datetimeoffset]$WeeklyReset).UtcDateTime.AddDays(-7) } catch { }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $buckets = Get-LocalUsageBuckets -ProjectsRoot $script:ProjectsRoot -CachePath $script:CachePath -SinceUtc $weeklyStart
    $localSession = Measure-UsageWindow -Buckets $buckets -StartUtc $sessionStart
    $localWeekly  = Measure-UsageWindow -Buckets $buckets -StartUtc $weeklyStart
    $sw.Stop()

    $sessionTokens = $localSession.Input + $localSession.Output + $localSession.CacheRead + $localSession.CacheWrite
    $script:LocalWeeklyTokens = $localWeekly.Input + $localWeekly.Output + $localWeekly.CacheRead + $localWeekly.CacheWrite

    Write-Log ('本機統計耗時 {0} ms；本區間 ${1:N4} 當量、{2:N0} tokens' -f `
        $sw.ElapsedMilliseconds, $localSession.Cost, $sessionTokens)

    # 共享資料夾沒設、不存在、或現在連不上（不在區網、NAS 沒開機）時，
    # 就只呈現本機自己的用量，不當成錯誤。
    if (-not (Test-SharedFolderAvailable)) {
        Show-LocalOnlySummary -SessionTokens $sessionTokens
        return
    }

    $script:LocalIP = Get-LocalIPv4
    $nameMap = Read-NameMap -SharedFolder $folder

    # 白名單：IP 沒登記在 names.json 裡就不上傳，避免未經同意的機器混進統計。
    # 仍然讀取並顯示其他人的數字，只是自己這台不寫進去。
    $script:IsRegistered = ($script:LocalIP -and $nameMap.ContainsKey($script:LocalIP))
    if (-not $script:IsRegistered) {
        $errorText.Text = ('本機 {0} 未登記於名稱對照表，用量不會上傳。' -f
            $(if ($script:LocalIP) { $script:LocalIP } else { '（取不到 IP）' }))
        $errorText.Visibility = 'Visible'
        Write-Log "本機 IP $($script:LocalIP) 不在白名單，略過上傳"
    }

    $report = @{
        ip            = $script:LocalIP
        updatedAt     = (Get-Date).ToString('o')
        sessionCost   = [math]::Round($localSession.Cost, 6)
        sessionTokens = $sessionTokens
        weeklyCost    = [math]::Round($localWeekly.Cost, 6)
        weeklyTokens  = $script:LocalWeeklyTokens
    }

    if ($script:IsRegistered) {
        if (-not (Write-MachineReport -SharedFolder $folder -Report $report)) {
            $machinesSection.Visibility = 'Visible'
            $machinesTitle.Text = '共享資料夾無法寫入，請確認路徑與權限'
            $machines.Children.Clear()
            return
        }
    }

    $reports = @(Read-AllMachineReports -SharedFolder $folder -MaxAgeDays $script:HideAfterDays)
    if ($reports.Count -eq 0) {
        $machinesSection.Visibility = 'Collapsed'
        return
    }

    $mode = $script:ViewMode

    $rows = @(Group-Reports -Reports $reports -By $mode -NameMap $nameMap)

    $unit = $(if ($mode -eq 'name') { '各名稱' } else { '各 IP' })

    $machines.Children.Clear()

    # 統計區間：本 5 小時、本週，或兩個都畫
    $window = [string]$script:Config.StatWindow
    if ([string]::IsNullOrWhiteSpace($window)) { $window = 'session' }

    $showSession = ($window -ne 'weekly')
    $showWeekly  = ($window -ne 'session')

    if ($showSession) {
        $machinesTitle.Text = '本 5 小時{0}佔用（估算）' -f $unit
        Add-BreakdownRows -Rows $rows -AccountPercent $SessionPercent -Period 'Session'
    }

    if ($showWeekly) {
        if ($showSession) {
            # 兩個區間都要畫時，第二段自己帶一個小標題
            $header = New-Object Windows.Controls.TextBlock
            $header.Text = '本週{0}佔用（估算）' -f $unit
            $header.FontFamily = 'Microsoft JhengHei UI'
            $header.FontSize = 10.5
            $header.Foreground = (Get-Theme).Muted
            $header.Margin = '0,6,0,9'
            $machines.Children.Add($header) | Out-Null
        } else {
            $machinesTitle.Text = '本週{0}佔用（估算）' -f $unit
        }
        Add-BreakdownRows -Rows $rows -AccountPercent $WeeklyPercent -Period 'Weekly'
    }

    $machinesSection.Visibility = 'Visible'
}

# ---------------------------------------------------------------- 狀態列圖示

$script:NotifyIcon      = $null
$script:LastIconHandle  = [IntPtr]::Zero
$script:App             = $null

<#
    把使用率畫成一個環形進度圖示，直接顯示在狀態列上。

    這樣不用點開視窗、也不用把滑鼠移過去，掃一眼就知道用掉多少。
    顏色跟視窗裡的進度條一致：藍（低）→ 琥珀（50% 起）→ 紅（75% 起）。
#>
function Update-TrayIcon {
    param(
        [double]$Percent,
        [string]$Tooltip
    )

    if ($null -eq $script:NotifyIcon) { return }

    try {
        $size = 32
        $bitmap = New-Object System.Drawing.Bitmap($size, $size)
        $gfx = [System.Drawing.Graphics]::FromImage($bitmap)
        $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $gfx.Clear([System.Drawing.Color]::Transparent)

        $hex = Get-BarColor $Percent
        $fg = [System.Drawing.ColorTranslator]::FromHtml($hex)

        # 底環用同色但很淡，看得出整圈的範圍
        $bgPen = New-Object System.Drawing.Pen(
            [System.Drawing.Color]::FromArgb(70, $fg.R, $fg.G, $fg.B), 5)
        $gfx.DrawEllipse($bgPen, 4, 4, 23, 23)

        $sweep = 360.0 * ([math]::Min(100.0, [math]::Max(0.0, $Percent)) / 100.0)
        if ($sweep -gt 0) {
            $pen = New-Object System.Drawing.Pen($fg, 5)
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
            # -90 度是從正上方開始畫，順時針
            $gfx.DrawArc($pen, 4, 4, 23, 23, -90, $sweep)
            $pen.Dispose()
        }
        $bgPen.Dispose()

        $handle = $bitmap.GetHicon()
        $script:NotifyIcon.Icon = [System.Drawing.Icon]::FromHandle($handle)

        # 先換上新圖示，再銷毀舊 handle，否則圖示會閃爍
        if ($script:LastIconHandle -ne [IntPtr]::Zero) {
            [void][IconCleanup]::DestroyIcon($script:LastIconHandle)
        }
        $script:LastIconHandle = $handle

        $gfx.Dispose()
        $bitmap.Dispose()

        # NotifyIcon.Text 上限 63 個字元，超過會直接拋例外
        if ($Tooltip.Length -gt 62) { $Tooltip = $Tooltip.Substring(0, 62) }
        $script:NotifyIcon.Text = $Tooltip
    }
    catch {
        Write-Log "更新狀態列圖示失敗：$($_.Exception.Message)"
    }
}

function Show-WidgetWindow {
    $window.Show()
    $window.Activate()
}

function Hide-WidgetWindow {
    $window.Hide()

    # 第一次縮起來時提醒一下，否則會以為程式被關掉了
    if (-not $script:Config.TrayTipShown -and $null -ne $script:NotifyIcon) {
        try {
            $script:NotifyIcon.ShowBalloonTip(5000, 'Claude Code 用量',
                '小工具縮到狀態列了。點一下這個圖示就會再出現。',
                [System.Windows.Forms.ToolTipIcon]::Info)
        } catch { }
        $script:Config.TrayTipShown = $true
        Export-Config
    }
}

$script:LastThemeName = ''

function Update-Widget {
    # 跟隨系統模式時，使用者在 Windows 切換深淺色後，下次更新就會自動換過來
    $themeNow = Get-ThemeName
    if ($themeNow -ne $script:LastThemeName) {
        $script:LastThemeName = $themeNow
        Set-WidgetTheme
    }

    try {
        $data = Get-UsageData

        $bars.Children.Clear()
        $errorText.Visibility = 'Collapsed'

        $limits = @()
        if ($data.limits) { $limits = @($data.limits) }

        if ($limits.Count -eq 0) {
            # 沒有 limits 陣列時退回舊欄位
            if ($data.five_hour) {
                $limits += [pscustomobject]@{ kind = 'session'; percent = $data.five_hour.utilization; resets_at = $data.five_hour.resets_at }
            }
            if ($data.seven_day) {
                $limits += [pscustomobject]@{ kind = 'weekly_all'; percent = $data.seven_day.utilization; resets_at = $data.seven_day.resets_at }
            }
        }

        $sessionPercent = $null
        $sessionReset   = $null
        $weeklyPercent  = $null
        $weeklyReset    = $null

        for ($i = 0; $i -lt $limits.Count; $i++) {
            $limit = $limits[$i]
            $pct = 0.0
            if ($null -ne $limit.percent) { $pct = [double]$limit.percent }

            switch ($limit.kind) {
                'session'    { $sessionPercent = $pct; $sessionReset = $limit.resets_at }
                'weekly_all' { $weeklyPercent  = $pct; $weeklyReset  = $limit.resets_at }
            }

            $caption = Format-Reset $limit.resets_at
            if ($limit.locked_reason) { $caption = "已鎖定：$($limit.locked_reason)" }

            $isLast = ($i -eq ($limits.Count - 1))
            $bar = New-UsageBar -Label (Get-LimitLabel $limit) -Percent $pct -Caption $caption -IsLast $isLast
            $bars.Children.Add($bar) | Out-Null
        }

        Update-MachineBreakdown -SessionPercent $sessionPercent -WeeklyPercent $weeklyPercent -SessionReset $sessionReset -WeeklyReset $weeklyReset

        $suffix = ''
        if ($script:LocalWeeklyTokens -gt 0) {
            $suffix = '本機本週 {0} · ' -f (Format-Tokens $script:LocalWeeklyTokens)
        }
        $statusText.Text = '{0}更新於 {1}' -f $suffix, (Get-Date -Format 'HH:mm')
        $statusText.Foreground = (Get-Theme).Muted
        $shell.BorderBrush = (Get-Theme).Border

        # 狀態列圖示畫 5 小時區間的用量，那是最需要盯著的數字
        $trayPct = 0.0
        if ($null -ne $sessionPercent) { $trayPct = [double]$sessionPercent }
        $tip = '5 小時 {0}%' -f [int][math]::Round($trayPct)
        if ($null -ne $weeklyPercent) { $tip += ' · 每週 {0}%' -f [int][math]::Round([double]$weeklyPercent) }
        $tip += ' · {0}' -f (Get-Date -Format 'HH:mm')
        Update-TrayIcon -Percent $trayPct -Tooltip $tip
    }
    catch {
        $message = $_.Exception.Message
        $hint = $message

        if ($message -match '401|Unauthorized') {
            $hint = '存取權杖已失效，請開啟一次 Claude Code 讓它重新登入。'
        } elseif ($message -match '找不到憑證檔') {
            $hint = '找不到 .credentials.json，請先登入 Claude Code。'
        } elseif ($message -match '429') {
            $hint = '查詢過於頻繁，稍後會自動重試。'
        } elseif ($message -match 'timed out|逾時|remote name|無法解析|could not be resolved') {
            $hint = '無法連線，將在下次排程重試。'
        }

        $errorText.Text = $hint
        $errorText.Visibility = 'Visible'
        $statusText.Text = '更新失敗 · {0}' -f (Get-Date -Format 'HH:mm')
        $statusText.Foreground = (Get-Theme).Error
        $shell.BorderBrush = (Get-Theme).Error
        Write-Log "更新失敗：$message"
    }
}

# ---------------------------------------------------------------- 互動

# 拖曳整個視窗
$window.Add_MouseLeftButtonDown({
    try { $window.DragMove() } catch { }
})

$window.Add_MouseLeftButtonUp({
    $script:Config.Left = $window.Left
    $script:Config.Top  = $window.Top
    Export-Config
})

# 這兩個圖示必須自己吃掉「按下」事件。
# 否則事件會冒泡到上面視窗層級的拖曳處理，DragMove() 會捕獲滑鼠，
# 放開時的 MouseLeftButtonUp 就永遠送不到按鈕身上 —— 游標會變成手指，但點了沒反應。
$btnClose.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
})

$btnClose.Add_MouseLeftButtonUp({
    param($sender, $e)
    $e.Handled = $true
    if ($script:Config.CloseToTray) { Hide-WidgetWindow } else { $window.Close() }
})

$btnRefresh.Add_MouseLeftButtonDown({
    param($sender, $e)
    $e.Handled = $true
})

$btnRefresh.Add_MouseLeftButtonUp({
    param($sender, $e)
    $e.Handled = $true
    $statusText.Text = '更新中…'
    Update-Widget
})

# 滑鼠移上去變色，讓人看得出這兩個圖示是可以點的
$btnClose.Add_MouseEnter({ $btnClose.Foreground = (Get-Theme).CloseHover })
$btnClose.Add_MouseLeave({ $btnClose.Foreground = (Get-Theme).Muted })
$btnRefresh.Add_MouseEnter({ $btnRefresh.Foreground = (Get-Theme).Accent })
$btnRefresh.Add_MouseLeave({ $btnRefresh.Foreground = (Get-Theme).Muted })

# 右鍵選單
$menu = New-Object Windows.Controls.ContextMenu

$miRefresh = New-Object Windows.Controls.MenuItem
$miRefresh.Header = '立即更新'
$miRefresh.Add_Click({ Update-Widget })
$menu.Items.Add($miRefresh) | Out-Null

$miTop = New-Object Windows.Controls.MenuItem
$miTop.Header = '總在最上層'
$miTop.IsCheckable = $true
$miTop.IsChecked = [bool]$script:Config.Topmost
$miTop.Add_Click({
    $window.Topmost = $miTop.IsChecked
    $script:Config.Topmost = $miTop.IsChecked
    Export-Config
})
$menu.Items.Add($miTop) | Out-Null

$miTheme = New-Object Windows.Controls.MenuItem
$miTheme.Header = '佈景主題'
$themeOptions = [ordered]@{
    '跟隨 Windows' = 'auto'
    '淺色'         = 'light'
    '深色'         = 'dark'
}
foreach ($label in $themeOptions.Keys) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $label
    $item.Tag = $themeOptions[$label]
    $item.IsCheckable = $true
    $item.IsChecked = ([string]$script:Config.Theme -eq $themeOptions[$label])
    $item.Add_Click({
        param($sender, $e)
        $mode = [string]$sender.Tag
        $script:Config.Theme = $mode
        foreach ($sibling in $miTheme.Items) { $sibling.IsChecked = ([string]$sibling.Tag -eq $mode) }
        Export-Config
        Set-WidgetTheme
        Update-Widget      # 進度條那些要重畫才會換色
    })
    $miTheme.Items.Add($item) | Out-Null
}
$menu.Items.Add($miTheme) | Out-Null

$miHideToTray = New-Object Windows.Controls.MenuItem
$miHideToTray.Header = '隱藏到狀態列'
$miHideToTray.Add_Click({ Hide-WidgetWindow })
$menu.Items.Add($miHideToTray) | Out-Null

$miCloseToTray = New-Object Windows.Controls.MenuItem
$miCloseToTray.Header = '按 ✕ 時隱藏而非結束'
$miCloseToTray.IsCheckable = $true
$miCloseToTray.IsChecked = [bool]$script:Config.CloseToTray
$miCloseToTray.Add_Click({
    $script:Config.CloseToTray = $miCloseToTray.IsChecked
    Export-Config
})
$menu.Items.Add($miCloseToTray) | Out-Null

$miStartHidden = New-Object Windows.Controls.MenuItem
$miStartHidden.Header = '開機時直接縮在狀態列'
$miStartHidden.IsCheckable = $true
$miStartHidden.IsChecked = [bool]$script:Config.StartHidden
$miStartHidden.Add_Click({
    $script:Config.StartHidden = $miStartHidden.IsChecked
    Export-Config
})
$menu.Items.Add($miStartHidden) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null

$miInterval = New-Object Windows.Controls.MenuItem
$miInterval.Header = '更新間隔'
foreach ($m in @(1, 5, 10, 30)) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = "$m 分鐘"
    $item.Tag = $m
    $item.IsCheckable = $true
    $item.IsChecked = ([int]$script:Config.RefreshMinutes -eq $m)
    $item.Add_Click({
        param($sender, $e)
        $minutes = [int]$sender.Tag
        $script:Config.RefreshMinutes = $minutes
        $script:Timer.Interval = [timespan]::FromMinutes($minutes)
        foreach ($sibling in $miInterval.Items) { $sibling.IsChecked = ([int]$sibling.Tag -eq $minutes) }
        Export-Config
    })
    $miInterval.Items.Add($item) | Out-Null
}
$menu.Items.Add($miInterval) | Out-Null

$miAlpha = New-Object Windows.Controls.MenuItem
$miAlpha.Header = '背景透明度'
$alphaOptions = [ordered]@{
    '不透明'     = 255
    '幾乎不透明' = 250
    '微透'       = 232
    '半透'       = 205
}
foreach ($label in $alphaOptions.Keys) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $label
    $item.Tag = $alphaOptions[$label]
    $item.IsCheckable = $true
    $item.IsChecked = ([int]$script:Config.BackgroundAlpha -eq $alphaOptions[$label])
    $item.Add_Click({
        param($sender, $e)
        $alpha = [int]$sender.Tag
        $script:Config.BackgroundAlpha = $alpha
        Set-ShellBackground $alpha
        foreach ($sibling in $miAlpha.Items) { $sibling.IsChecked = ([int]$sibling.Tag -eq $alpha) }
        Export-Config
    })
    $miAlpha.Items.Add($item) | Out-Null
}
$menu.Items.Add($miAlpha) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null

$miWindow = New-Object Windows.Controls.MenuItem
$miWindow.Header = '統計區間'
$windowOptions = [ordered]@{
    '本 5 小時' = 'session'
    '本週'      = 'weekly'
    '兩者都顯示' = 'both'
}
foreach ($label in $windowOptions.Keys) {
    $item = New-Object Windows.Controls.MenuItem
    $item.Header = $label
    $item.Tag = $windowOptions[$label]
    $item.IsCheckable = $true
    $item.IsChecked = ([string]$script:Config.StatWindow -eq $windowOptions[$label])
    $item.Add_Click({
        param($sender, $e)
        $w = [string]$sender.Tag
        $script:Config.StatWindow = $w
        foreach ($sibling in $miWindow.Items) { $sibling.IsChecked = ([string]$sibling.Tag -eq $w) }
        Export-Config
        Update-Widget
    })
    $miWindow.Items.Add($item) | Out-Null
}
$menu.Items.Add($miWindow) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null

$miFolder = New-Object Windows.Controls.MenuItem
$miFolder.Header = '開啟安裝資料夾'
$miFolder.Add_Click({ Start-Process explorer.exe $script:Root })
$menu.Items.Add($miFolder) | Out-Null

$miExit = New-Object Windows.Controls.MenuItem
$miExit.Header = '結束'
$miExit.Add_Click({ $window.Close() })
$menu.Items.Add($miExit) | Out-Null

$shell.ContextMenu = $menu

# ---------------------------------------------------------------- 啟動

# ---------------------------------------------------------------- 狀態列常駐

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Text = 'Claude Code 用量'

# 先給一個底圖，等第一次更新完才會換成真正的用量環
Update-TrayIcon -Percent 0 -Tooltip 'Claude Code 用量（載入中）'

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$trayShow = $trayMenu.Items.Add('顯示／隱藏視窗')
$trayShow.add_Click({
    if ($window.IsVisible) { Hide-WidgetWindow } else { Show-WidgetWindow }
})

$trayRefresh = $trayMenu.Items.Add('立即更新')
$trayRefresh.add_Click({ Update-Widget })

[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$trayExit = $trayMenu.Items.Add('結束')
$trayExit.add_Click({
    $script:ReallyExit = $true
    $window.Close()
})

$script:NotifyIcon.ContextMenuStrip = $trayMenu

# 左鍵單擊切換顯示，右鍵交給上面的選單
$script:NotifyIcon.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($window.IsVisible) { Hide-WidgetWindow } else { Show-WidgetWindow }
    }
})

$script:NotifyIcon.add_BalloonTipClicked({ Show-WidgetWindow })

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Interval = [timespan]::FromMinutes([int]$script:Config.RefreshMinutes)
$script:Timer.Add_Tick({ Update-Widget })

function Set-WidgetPosition {
    $work = [System.Windows.SystemParameters]::WorkArea

    if ([double]$script:Config.Left -lt 0) {
        $left = $work.Right - $window.ActualWidth - 16
    } else {
        $left = [double]$script:Config.Left
    }
    $top = [double]$script:Config.Top

    # 視窗若落在工作區外（例如換過螢幕解析度），拉回可見範圍
    if ($left -lt $work.Left) { $left = $work.Left + 8 }
    if ($left -gt ($work.Right - 60)) { $left = $work.Right - $window.ActualWidth - 16 }
    if ($top -lt $work.Top) { $top = $work.Top + 8 }
    if ($top -gt ($work.Bottom - 60)) { $top = $work.Bottom - $window.ActualHeight - 16 }

    $window.Left = $left
    $window.Top  = $top
}

$window.Add_Loaded({
    Set-WidgetTheme
    Update-Widget
    Set-WidgetPosition
    $script:Timer.Start()

    # 開機自動啟動時通常不希望視窗跳出來擋畫面，縮在狀態列就好
    if ($script:Config.StartHidden) {
        $window.Hide()
        Write-Log '依設定啟動時隱藏到狀態列'
    }
})

$window.Add_ContentRendered({
    # 內容填好後高度才真正確定，這裡再定位一次，
    # 避免 SizeToContent 撐開視窗後位置被系統重新安排。
    Set-WidgetPosition
    $work = [System.Windows.SystemParameters]::WorkArea
    Write-Log ('工作區 {0}x{1} 起點({2},{3})；視窗({4},{5}) 尺寸 {6}x{7}' -f `
        $work.Width, $work.Height, $work.Left, $work.Top, `
        [int]$window.Left, [int]$window.Top, [int]$window.ActualWidth, [int]$window.ActualHeight)
    Export-Config
})

$window.Add_Closed({
    $script:Timer.Stop()

    # 視窗被 Hide 時 Left/Top 仍是有效值，直接存即可
    $script:Config.Left = $window.Left
    $script:Config.Top  = $window.Top
    Export-Config

    # 不主動移除的話，圖示會卡在狀態列直到滑鼠掃過去才消失
    if ($null -ne $script:NotifyIcon) {
        $script:NotifyIcon.Visible = $false
        $script:NotifyIcon.Dispose()
    }
    if ($script:LastIconHandle -ne [IntPtr]::Zero) {
        [void][IconCleanup]::DestroyIcon($script:LastIconHandle)
    }

    # ShutdownMode 是 OnExplicitShutdown，訊息迴圈要自己收掉才會真的結束
    if ($null -ne $script:App) { $script:App.Shutdown() }
})

Write-Log '小工具啟動'

# 不能用 ShowDialog()：那是模態對話框，對它呼叫 Hide() 會讓 ShowDialog 直接返回，
# 整個程式就跟著結束了，視窗根本沒辦法縮到狀態列再叫回來。
# 改用 Application + OnExplicitShutdown，視窗可以自由 Hide/Show，
# 只有明確呼叫 Shutdown() 才會真正離開。
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:App.Run($window) | Out-Null

Write-Log '小工具關閉'

if ($script:HasMutex) {
    try { $script:Mutex.ReleaseMutex() } catch { }
    $script:Mutex.Dispose()
}
