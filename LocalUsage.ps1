<#
    本機用量解析

    從 Claude Code 的對話紀錄（~/.claude/projects/**/*.jsonl）算出「這台電腦」
    實際產生的用量，並用官方公開定價換算成 USD 當量，作為跨模型比較的共同尺度。

    為什麼要換算成 USD：不同模型的單位成本差到 10 倍（Opus 的 output 是 Haiku 的 5 倍價），
    直接比 token 數會讓跑輕量模型的機器被高估。用金額當量才是公平的比較基準。

    換算公式的正確性已用紀錄中 Claude Code 自己寫入的 cost-state 數字反覆驗證：
        Haiku:  892 in × $1/1M + 14 out × $5/1M      = 0.000962（與紀錄完全相同）
        Opus 5: 反解 cache write 單價得 $10/1M，即 input 價的 2×（1 小時 TTL）
#>

# 官方定價（USD / 每百萬 token），取自 Anthropic 公開價目表
$script:ModelPrices = @{
    'claude-fable-5'    = @{ In = 10.0; Out = 50.0 }
    'claude-mythos-5'   = @{ In = 10.0; Out = 50.0 }
    'claude-opus-5'     = @{ In = 5.0;  Out = 25.0 }
    'claude-opus-4-8'   = @{ In = 5.0;  Out = 25.0 }
    'claude-opus-4-7'   = @{ In = 5.0;  Out = 25.0 }
    'claude-opus-4-6'   = @{ In = 5.0;  Out = 25.0 }
    'claude-opus-4-5'   = @{ In = 5.0;  Out = 25.0 }
    'claude-sonnet-5'   = @{ In = 2.0;  Out = 10.0 }
    'claude-sonnet-4-6' = @{ In = 3.0;  Out = 15.0 }
    'claude-sonnet-4-5' = @{ In = 3.0;  Out = 15.0 }
    'claude-haiku-4-5'  = @{ In = 1.0;  Out = 5.0 }
}

# 未知模型時的保守預設（用 Opus 價，寧可高估也不要漏算）
$script:DefaultPrice = @{ In = 5.0; Out = 25.0 }

# 快取相關倍率（相對於該模型的 input 單價）
$script:CacheReadRate    = 0.1    # 讀快取
$script:CacheWrite5mRate = 1.25   # 寫入 5 分鐘 TTL 快取
$script:CacheWrite1hRate = 2.0    # 寫入 1 小時 TTL 快取

# 時間桶粒度（分鐘）。10 分鐘可讓 5 小時視窗的邊界誤差控制在 3% 左右，
# 同時讓一週的桶數維持在 1000 出頭，快取檔不會過大。
$script:BucketMinutes = 10

function Get-ModelPrice {
    param([string]$Model)

    if ([string]::IsNullOrWhiteSpace($Model)) { return $script:DefaultPrice }
    if ($script:ModelPrices.ContainsKey($Model)) { return $script:ModelPrices[$Model] }

    # 模型 id 常帶日期後綴（例如 claude-haiku-4-5-20251001），取最長的前綴比對
    $best = $null
    $bestLen = 0
    foreach ($key in $script:ModelPrices.Keys) {
        if ($Model.StartsWith($key) -and $key.Length -gt $bestLen) {
            $best = $key
            $bestLen = $key.Length
        }
    }
    if ($best) { return $script:ModelPrices[$best] }
    return $script:DefaultPrice
}

function Get-BucketKey {
    param([datetime]$Utc)
    $floored = $Utc.AddMinutes(-($Utc.Minute % $script:BucketMinutes))
    return $floored.ToString('yyyy-MM-ddTHH:mm')
}

function New-EmptyBucket {
    return @{ Cost = 0.0; Input = 0.0; Output = 0.0; CacheRead = 0.0; CacheWrite = 0.0 }
}

<#
    解析單一 jsonl 檔，回傳「時間桶 -> 用量」的 hashtable。
    只讀 message.usage 與 timestamp 兩個欄位，不碰對話內容。
#>
function Read-JsonlUsage {
    param([string]$Path)

    $buckets = @{}
    $reader = $null

    # 同一次 API 請求會被寫進紀錄好幾次（實測 48 行只對應 21 次真實請求），
    # 直接累加會嚴重高估。以 requestId 去重，同一個 id 以最後出現的那筆為準
    # ——串流過程中的紀錄是漸進的，最後一筆才是完整用量。
    $seen = @{}

    # Claude Code 會在紀錄裡寫 cost-state 行，累計這個 session 的實際花費。
    # 它比逐筆解析更完整：有些背景請求（分類、標題生成之類）不會寫成對話訊息，
    # 但一樣計入帳號額度，只有 cost-state 算得到。實測差距約 5%。
    # 所以最後用 cost-state 校正總量，同時保留逐筆解析得到的時間分佈。
    $costState = $null

    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)

        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -like '*"totalCostUSD"*') {
                try {
                    $cs = $line | ConvertFrom-Json
                    if ($null -ne $cs.totalCostUSD) { $costState = $cs }
                } catch { }
                continue
            }

            # 先做便宜的字串篩選，避免對絕大多數不含用量的行做 JSON 解析
            if ($line.Length -lt 40 -or $line -notlike '*"usage"*') { continue }

            try { $obj = $line | ConvertFrom-Json } catch { continue }

            $usage = $obj.message.usage
            if (-not $usage) { continue }
            if ([string]::IsNullOrWhiteSpace($obj.timestamp)) { continue }

            $key = $null
            if ($obj.requestId)     { $key = 'r:' + $obj.requestId }
            elseif ($obj.message.id) { $key = 'm:' + $obj.message.id }
            elseif ($obj.uuid)       { $key = 'u:' + $obj.uuid }
            else                     { $key = 'n:' + $seen.Count }

            $seen[$key] = @{ Timestamp = [string]$obj.timestamp; Model = [string]$obj.message.model; Usage = $usage }
        }
    }
    catch {
        # 單一檔案讀取失敗不該讓整體統計中斷
    }
    finally {
        if ($reader) { $reader.Dispose() }
    }

    try {
        foreach ($key in $seen.Keys) {
            $record = $seen[$key]
            $usage = $record.Usage

            try { $when = ([datetimeoffset]$record.Timestamp).UtcDateTime } catch { continue }

            $price = Get-ModelPrice $record.Model

            $inTok  = [double]$usage.input_tokens
            $outTok = [double]$usage.output_tokens
            $crTok  = 0.0
            if ($usage.cache_read_input_tokens) { $crTok = [double]$usage.cache_read_input_tokens }

            # 快取寫入分兩種 TTL，倍率不同，能分就分
            $cw5  = 0.0
            $cw1h = 0.0
            if ($usage.cache_creation) {
                if ($usage.cache_creation.ephemeral_5m_input_tokens) { $cw5  = [double]$usage.cache_creation.ephemeral_5m_input_tokens }
                if ($usage.cache_creation.ephemeral_1h_input_tokens) { $cw1h = [double]$usage.cache_creation.ephemeral_1h_input_tokens }
            }
            if (($cw5 + $cw1h) -eq 0 -and $usage.cache_creation_input_tokens) {
                # 沒有細分欄位時，Claude Code 預設用 1 小時 TTL
                $cw1h = [double]$usage.cache_creation_input_tokens
            }

            $cost = (
                $inTok  * $price.In +
                $outTok * $price.Out +
                $crTok  * $price.In * $script:CacheReadRate +
                $cw5    * $price.In * $script:CacheWrite5mRate +
                $cw1h   * $price.In * $script:CacheWrite1hRate
            ) / 1000000.0

            $key = Get-BucketKey $when
            if (-not $buckets.ContainsKey($key)) { $buckets[$key] = New-EmptyBucket }

            $b = $buckets[$key]
            $b.Cost       += $cost
            $b.Input      += $inTok
            $b.Output     += $outTok
            $b.CacheRead  += $crTok
            $b.CacheWrite += ($cw5 + $cw1h)
        }
    }
    catch {
        # 統計過程出錯時回傳目前已累積的結果，不讓整體更新中斷
    }

    # 用 cost-state 把總量校正到 Claude Code 自己算的數字，
    # 時間分佈維持逐筆解析的結果（等比例放大）。
    if ($costState -and $buckets.Count -gt 0) {
        $rawCost   = 0.0
        $rawTokens = 0.0
        foreach ($key in $buckets.Keys) {
            $b = $buckets[$key]
            $rawCost   += $b.Cost
            $rawTokens += $b.Input + $b.Output + $b.CacheRead + $b.CacheWrite
        }

        $trueCost   = [double]$costState.totalCostUSD
        $trueTokens = 0.0
        if ($costState.modelUsage) {
            foreach ($prop in $costState.modelUsage.PSObject.Properties) {
                $mu = $prop.Value
                $trueTokens += [double]$mu.inputTokens + [double]$mu.outputTokens +
                               [double]$mu.cacheReadInputTokens + [double]$mu.cacheCreationInputTokens
            }
        }

        $costFactor  = 1.0
        $tokenFactor = 1.0
        if ($rawCost   -gt 0 -and $trueCost   -gt 0) { $costFactor  = $trueCost / $rawCost }
        if ($rawTokens -gt 0 -and $trueTokens -gt 0) { $tokenFactor = $trueTokens / $rawTokens }

        # 係數應該只是小幅修正；離譜的比例代表哪裡判斷錯了，寧可不校正
        if ($costFactor  -lt 0.3 -or $costFactor  -gt 3.0) { $costFactor  = 1.0 }
        if ($tokenFactor -lt 0.3 -or $tokenFactor -gt 3.0) { $tokenFactor = 1.0 }

        if ($costFactor -ne 1.0 -or $tokenFactor -ne 1.0) {
            foreach ($key in $buckets.Keys) {
                $b = $buckets[$key]
                $b.Cost       = $b.Cost * $costFactor
                $b.Input      = $b.Input * $tokenFactor
                $b.Output     = $b.Output * $tokenFactor
                $b.CacheRead  = $b.CacheRead * $tokenFactor
                $b.CacheWrite = $b.CacheWrite * $tokenFactor
            }
        }
    }

    return $buckets
}

function ConvertTo-Hashtable {
    param($Object)
    $result = @{}
    if ($null -eq $Object) { return $result }
    foreach ($prop in $Object.PSObject.Properties) {
        $result[$prop.Name] = $prop.Value
    }
    return $result
}

<#
    掃描所有專案紀錄，維護一份解析快取。

    快取的判斷依據是「檔案大小 + 最後修改時間」：只要沒變就直接沿用上次的解析結果。
    實務上只有當前正在使用的那個 session 檔會變動，其他幾十個檔案都會命中快取，
    所以每次更新真正需要重新解析的資料量很小。
#>
function Get-LocalUsageBuckets {
    param(
        [string]$ProjectsRoot,
        [string]$CachePath,
        [datetime]$SinceUtc
    )

    $cache = @{}
    if (Test-Path $CachePath) {
        try {
            $raw = Get-Content $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $raw.PSObject.Properties) {
                $entry = $prop.Value
                $cache[$prop.Name] = @{
                    Size    = [long]$entry.Size
                    Mtime   = [string]$entry.Mtime
                    Buckets = ConvertTo-Hashtable $entry.Buckets
                }
            }
        } catch { $cache = @{} }
    }

    if (-not (Test-Path $ProjectsRoot)) { return @{} }

    $files = Get-ChildItem -Path $ProjectsRoot -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTimeUtc -ge $SinceUtc }

    $newCache = @{}
    $merged = @{}

    foreach ($file in $files) {
        $path  = $file.FullName
        $mtime = $file.LastWriteTimeUtc.ToString('o')

        $entry = $null
        if ($cache.ContainsKey($path)) {
            $old = $cache[$path]
            if ($old.Size -eq $file.Length -and $old.Mtime -eq $mtime) {
                $entry = $old   # 檔案沒動過，沿用上次結果
            }
        }

        if (-not $entry) {
            $parsed = Read-JsonlUsage -Path $path
            $entry = @{ Size = $file.Length; Mtime = $mtime; Buckets = $parsed }
        }

        $newCache[$path] = $entry

        foreach ($key in $entry.Buckets.Keys) {
            $src = $entry.Buckets[$key]
            if (-not $merged.ContainsKey($key)) { $merged[$key] = New-EmptyBucket }
            $dst = $merged[$key]
            $dst.Cost       += [double]$src.Cost
            $dst.Input      += [double]$src.Input
            $dst.Output     += [double]$src.Output
            $dst.CacheRead  += [double]$src.CacheRead
            $dst.CacheWrite += [double]$src.CacheWrite
        }
    }

    try {
        $newCache | ConvertTo-Json -Depth 6 -Compress | Out-File -FilePath $CachePath -Encoding utf8
    } catch { }

    return $merged
}

<#
    把時間桶彙總成某個時間視窗（例如「這個 5 小時區間」）的用量。
#>
function Measure-UsageWindow {
    param(
        [hashtable]$Buckets,
        [datetime]$StartUtc
    )

    $result = New-EmptyBucket
    if (-not $Buckets) { return $result }

    # 視窗起點所在的桶整個算進來，邊界誤差最多一個桶的長度
    $startKey = Get-BucketKey $StartUtc

    foreach ($key in $Buckets.Keys) {
        if ([string]::Compare($key, $startKey) -lt 0) { continue }
        $b = $Buckets[$key]
        $result.Cost       += [double]$b.Cost
        $result.Input      += [double]$b.Input
        $result.Output     += [double]$b.Output
        $result.CacheRead  += [double]$b.CacheRead
        $result.CacheWrite += [double]$b.CacheWrite
    }

    return $result
}
