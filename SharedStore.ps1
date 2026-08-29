<#
    共享資料夾讀寫

    每台電腦在共享資料夾裡維護一個以自己電腦名命名的小 JSON，
    內容只有彙總後的數字（金額當量、token 數、時間），不含任何對話內容。

    寫入採「先寫暫存檔再改名」，避免其他機器在同一瞬間讀到只寫了一半的檔案。
#>

# 超過這個時間沒更新的機器，視為目前沒在線上
$script:StaleMinutes = 20

# 名稱對照表的檔名。它跟各機器的回報檔放在同一個資料夾，
# 讀取回報時必須把它排除掉。
$script:NameMapFile = 'names.json'

<#
    回報檔名就是 IP，一台一個檔。

    同一台電腦若有不同 Windows 使用者各自跑 Claude Code，兩者的 IP 相同，
    會寫進同一個檔、後寫的覆蓋先寫的 —— 那是刻意的：以 IP 為單位計算用量，
    不細分到個別使用者。
#>
function Get-MachineReportPath {
    param([string]$SharedFolder, [string]$IP)

    if ([string]::IsNullOrWhiteSpace($IP)) { return $null }
    $safeIP = $IP -replace '[^\w\-\.]', '_'
    return (Join-Path $SharedFolder "$safeIP.json")
}

<#
    讀取共享的「IP → 名稱」對照表。

    放在共享資料夾集中管理，任何一台改了所有人都會看到，
    不必為了改一個名字跑遍每台電腦。
#>
function Read-NameMap {
    param([string]$SharedFolder)

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($SharedFolder)) { return $map }

    $path = Join-Path $SharedFolder $script:NameMapFile
    if (-not (Test-Path $path)) { return $map }

    try {
        # 這個檔是人用記事本編的，編碼不一定是 UTF-8。
        # 先照 UTF-8 嚴格解碼，失敗才退回系統 ANSI —— 舊版記事本存的中文名稱
        # 若當成 UTF-8 讀會變亂碼，而 IP 是 ASCII 不受影響，
        # 結果就是白名單照常運作、只有名字壞掉，這種半壞狀況很難察覺。
        $bytes = [IO.File]::ReadAllBytes($path)
        $text = $null
        try {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strict.GetString($bytes)
        }
        catch {
            $text = [System.Text.Encoding]::Default.GetString($bytes)
        }

        # 自己讀位元組就要自己處理 BOM，留著會讓 ConvertFrom-Json 解析失敗
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

        $obj = $text | ConvertFrom-Json
        foreach ($prop in $obj.PSObject.Properties) {
            $map[[string]$prop.Name] = [string]$prop.Value
        }
    } catch { }

    return $map
}

function Write-MachineReport {
    param(
        [string]$SharedFolder,
        [hashtable]$Report
    )

    if ([string]::IsNullOrWhiteSpace($SharedFolder)) { return $false }
    if (-not (Test-Path $SharedFolder)) { return $false }

    $target = Get-MachineReportPath -SharedFolder $SharedFolder -IP $Report.ip
    if (-not $target) { return $false }   # 取不到 IP 就無從識別，不寫
    $temp   = "$target.$PID.tmp"

    try {
        $Report | ConvertTo-Json -Depth 6 | Out-File -FilePath $temp -Encoding utf8 -ErrorAction Stop
        Move-Item -Path $temp -Destination $target -Force -ErrorAction Stop
        return $true
    }
    catch {
        if (Test-Path $temp) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Read-AllMachineReports {
    param(
        [string]$SharedFolder,
        [int]$MaxAgeDays = 0   # 大於 0 時，超過這個天數沒回報的機器就不列出來
    )

    $reports = @()
    if ([string]::IsNullOrWhiteSpace($SharedFolder)) { return $reports }
    if (-not (Test-Path $SharedFolder)) { return $reports }

    $files = Get-ChildItem -Path $SharedFolder -Filter '*.json' -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if ($file.Name -eq $script:NameMapFile) { continue }   # 名稱對照表不是機器回報
        try {
            $obj = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if (-not $obj.ip) { continue }

            $ageMinutes = [double]::PositiveInfinity
            if ($obj.updatedAt) {
                try {
                    $updated = [datetimeoffset]::Parse($obj.updatedAt)
                    $ageMinutes = ([datetimeoffset]::Now - $updated).TotalMinutes
                } catch { }
            }

            # 回報檔只帶 IP 與數字，名稱由共享的 names.json 決定。
            # 舊版檔案可能還有 machine／user／displayName，一律忽略。

            if ($MaxAgeDays -gt 0 -and $ageMinutes -gt ($MaxAgeDays * 1440)) { continue }

            $reports += [pscustomobject]@{
                IP            = [string]$obj.ip
                UpdatedAt     = [string]$obj.updatedAt
                AgeMinutes    = $ageMinutes
                IsStale       = ($ageMinutes -gt $script:StaleMinutes)
                SessionCost   = [double]$obj.sessionCost
                SessionTokens = [double]$obj.sessionTokens
                WeeklyCost    = [double]$obj.weeklyCost
                WeeklyTokens  = [double]$obj.weeklyTokens
            }
        }
        catch {
            # 某一台的檔案壞掉或正在被寫入，跳過即可，不影響其他機器
            continue
        }
    }

    return $reports
}

<#
    把各機器的回報合併成畫面上的一列一列。

    $By 決定合併的依據：
        ip      —— 依固定 IP（預設）。同一個 IP 上不同 Windows 使用者的用量會加在一起
        name    —— 依 names.json 裡的名稱。多個 IP 對到同一個名稱時會合併加總

    只要那一組還有任何一台在線上，整組就不算離線。
#>
function Group-Reports {
    param(
        $Reports,
        [string]$By = 'ip',
        [hashtable]$NameMap = @{}
    )

    $groups = @{}

    foreach ($r in @($Reports)) {
        # 名稱只有一個來源：共享的 names.json。查不到就留空，後面直接顯示 IP。
        $resolved = $null
        if ($r.IP -and $NameMap.ContainsKey($r.IP)) { $resolved = $NameMap[$r.IP] }

        switch ($By) {
            'name' {
                # 管理者把多個 IP 對到同一個名稱，這裡就會自動合併
                $key = $resolved
                if ([string]::IsNullOrWhiteSpace($key)) { $key = $r.IP }
            }
            default { $key = $r.IP }
        }
        if ([string]::IsNullOrWhiteSpace($key)) { $key = '(未知)' }

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{
                GroupKey       = $key
                Title          = ''
                Detail         = ''
                IPs            = @()
                Names          = @()
                SessionCost    = 0.0
                SessionTokens  = 0.0
                WeeklyCost     = 0.0
                WeeklyTokens   = 0.0
                ActiveMachines = 0
                MinAgeMinutes  = [double]::PositiveInfinity
                IsStale        = $true
            }
        }

        $g = $groups[$key]
        $g.SessionCost   += $r.SessionCost
        $g.SessionTokens += $r.SessionTokens
        $g.WeeklyCost    += $r.WeeklyCost
        $g.WeeklyTokens  += $r.WeeklyTokens
        if ($r.IP)          { $g.IPs   += $r.IP }
        if ($resolved)      { $g.Names += $resolved }
        if (-not $r.IsStale) { $g.ActiveMachines++ }
        if ($r.AgeMinutes -lt $g.MinAgeMinutes) { $g.MinAgeMinutes = $r.AgeMinutes }
    }

    foreach ($key in @($groups.Keys)) {
        $g = $groups[$key]
        $g.IsStale   = ($g.ActiveMachines -eq 0)
        $g.IPs   = @($g.IPs   | Select-Object -Unique)
        $g.Names = @($g.Names | Select-Object -Unique)

        switch ($By) {
            'name' {
                $g.Title  = $key
                $g.Detail = ($g.IPs -join '、')
                if ($g.IPs.Count -gt 1) { $g.Detail = '{0} 個 IP：{1}' -f $g.IPs.Count, ($g.IPs -join '、') }
            }
            default {
                # 對照表裡有名字就顯示名字、IP 退到副標；沒有的話主標直接顯示 IP
                $named = @($g.Names)[0]
                if ($named) {
                    $g.Title  = $named
                    $g.Detail = ($g.IPs -join '、')
                } else {
                    $g.Title  = $key
                    $g.Detail = ''
                }
            }
        }
    }

    return @($groups.Values)
}
