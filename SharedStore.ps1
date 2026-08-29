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
    回報檔名以 IP 為主、Windows 使用者名為輔。

    用 IP 當主要識別是因為固定 IP 由網管統一配發，比電腦名可靠；
    但同一台電腦仍可能有不同 Windows 使用者各自跑 Claude Code（各自有獨立的 ~/.claude），
    那種情況兩份回報的 IP 會相同，所以檔名再帶上使用者名避免互相覆蓋。
#>
function Get-MachineReportPath {
    param([string]$SharedFolder, [string]$Machine, [string]$User, [string]$IP)

    $safeUser = $User -replace '[^\w\-\.]', '_'
    if (-not [string]::IsNullOrWhiteSpace($IP)) {
        $safeIP = $IP -replace '[^\w\-\.]', '_'
        if ([string]::IsNullOrWhiteSpace($safeUser)) { return (Join-Path $SharedFolder "$safeIP.json") }
        return (Join-Path $SharedFolder "$safeIP`_$safeUser.json")
    }

    # 取不到 IP 時退回用電腦名，功能不會因此中斷
    $safeMachine = $Machine -replace '[^\w\-\.]', '_'
    if ([string]::IsNullOrWhiteSpace($safeUser)) { return (Join-Path $SharedFolder "$safeMachine.json") }
    return (Join-Path $SharedFolder "$safeMachine`_$safeUser.json")
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
        $obj = Get-Content $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
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

    $target = Get-MachineReportPath -SharedFolder $SharedFolder -Machine $Report.machine -User $Report.user -IP $Report.ip
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
            if (-not $obj.machine) { continue }

            $ageMinutes = [double]::PositiveInfinity
            if ($obj.updatedAt) {
                try {
                    $updated = [datetimeoffset]::Parse($obj.updatedAt)
                    $ageMinutes = ([datetimeoffset]::Now - $updated).TotalMinutes
                } catch { }
            }

            # 顯示名稱一律由共享的 names.json 決定，回報檔本身不帶名字。
            # 舊版回報檔可能還有 displayName 欄位，這裡直接忽略。
            $user = [string]$obj.user

            if ($MaxAgeDays -gt 0 -and $ageMinutes -gt ($MaxAgeDays * 1440)) { continue }

            $reports += [pscustomobject]@{
                Machine       = [string]$obj.machine
                User          = $user
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
    刪掉共享資料夾裡長期沒更新的回報檔，用來把已經不再使用的電腦移出名單。

    注意：如果那台電腦的小工具還在跑，它下次更新時又會把自己寫回來。
    要真正移除，得先在那台上關掉小工具（或停用共享）再刪。
#>
function Remove-StaleReports {
    param(
        [string]$SharedFolder,
        [int]$OlderThanDays = 7
    )

    $removed = 0
    if ([string]::IsNullOrWhiteSpace($SharedFolder)) { return $removed }
    if (-not (Test-Path $SharedFolder)) { return $removed }

    $cutoff = [datetimeoffset]::Now.AddDays(-$OlderThanDays)

    foreach ($file in (Get-ChildItem -Path $SharedFolder -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -eq $script:NameMapFile) { continue }
        try {
            $obj = Get-Content $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
            if (-not $obj.machine) { continue }
            if (-not $obj.updatedAt) { continue }

            $updated = [datetimeoffset]::Parse($obj.updatedAt)
            if ($updated -lt $cutoff) {
                Remove-Item $file.FullName -Force -ErrorAction Stop
                $removed++
            }
        } catch { continue }
    }

    return $removed
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
        # 名稱只有一個來源：共享的 names.json。查不到就留空，後面用 IP 或電腦名頂替。
        $resolved = $null
        if ($r.IP -and $NameMap.ContainsKey($r.IP)) { $resolved = $NameMap[$r.IP] }

        switch ($By) {
            'name' {
                # 管理者把多個 IP 對到同一個名稱，這裡就會自動合併
                $key = $resolved
                if ([string]::IsNullOrWhiteSpace($key)) { $key = $r.IP }
            }
            default {
                $key = $r.IP
                if ([string]::IsNullOrWhiteSpace($key)) { $key = $r.Machine }
            }
        }
        if ([string]::IsNullOrWhiteSpace($key)) { $key = '(未知)' }

        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{
                GroupKey       = $key
                Title          = ''
                Detail         = ''
                IPs            = @()
                Machines       = @()
                People         = @()
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
        if ($r.IP)          { $g.IPs      += $r.IP }
        if ($r.Machine)     { $g.Machines += $r.Machine }
        if ($resolved)      { $g.People   += $resolved }
        if (-not $r.IsStale) { $g.ActiveMachines++ }
        if ($r.AgeMinutes -lt $g.MinAgeMinutes) { $g.MinAgeMinutes = $r.AgeMinutes }
    }

    foreach ($key in @($groups.Keys)) {
        $g = $groups[$key]
        $g.IsStale   = ($g.ActiveMachines -eq 0)
        $g.IPs       = @($g.IPs      | Select-Object -Unique)
        $g.Machines  = @($g.Machines | Select-Object -Unique)
        $g.People    = @($g.People   | Select-Object -Unique)

        switch ($By) {
            'name' {
                $g.Title  = $key
                $g.Detail = ($g.Machines -join '、')
                if ($g.Machines.Count -gt 1) { $g.Detail = '{0} 台：{1}' -f $g.Machines.Count, ($g.Machines -join '、') }
            }
            default {
                # 對照表裡有名字就顯示名字，IP 退到副標；沒有的話主標直接顯示 IP
                $named = @($g.People)[0]
                if ($named) {
                    $g.Title  = $named
                    $g.Detail = ((@($g.IPs) + @($g.Machines)) | Where-Object { $_ } | Select-Object -Unique) -join ' · '
                } else {
                    # 對照表還沒建立時，主標顯示 IP，副標把人名與電腦名帶上才認得出是誰
                    $g.Title  = $key
                    $g.Detail = ((@($g.People) + @($g.Machines)) | Where-Object { $_ } | Select-Object -Unique) -join ' · '
                }
            }
        }
    }

    return @($groups.Values)
}
