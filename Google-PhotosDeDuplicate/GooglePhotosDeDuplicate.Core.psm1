Set-StrictMode -Version Latest

$script:GPDState = [ordered]@{
    ChromeProcess = $null
    RemoteDebuggingPort = 9222
    UserDataDir = $null
    BrowserVersion = $null
    ActiveTarget = $null
    ActiveWebSocketUrl = $null
}

function Test-GPDEnvironment {
    [CmdletBinding()]
    param()

    $chrome = Get-GPDChromePath
    [pscustomobject]@{
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PSEdition = $PSVersionTable.PSEdition
        IsWindows = $IsWindows
        ChromePath = $chrome
        ChromeFound = [bool]$chrome
        ModuleRoot = $PSScriptRoot
    }
}

function Connect-GPDBrowser {
    [CmdletBinding()]
    param(
        [int]$RemoteDebuggingPort = 9222,
        [string]$UserDataDir = (Join-Path $env:LOCALAPPDATA 'GooglePhotosDeDuplicate\ChromeProfile'),
        [string]$ChromePath,
        [switch]$AttachOnly,
        [switch]$NewWindow
    )

    if (-not $ChromePath) { $ChromePath = Get-GPDChromePath }
    if (-not $ChromePath -and -not $AttachOnly) { throw 'Could not find chrome.exe. Supply -ChromePath.' }

    $script:GPDState.RemoteDebuggingPort = $RemoteDebuggingPort
    $script:GPDState.UserDataDir = $UserDataDir

    try {
        $version = Invoke-GPDRest -Path '/json/version' -Port $RemoteDebuggingPort -ErrorAction Stop
    }
    catch {
        if ($AttachOnly) { throw "Chrome is not listening on 127.0.0.1:$RemoteDebuggingPort." }
        if (-not (Test-Path -LiteralPath $UserDataDir)) { New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null }
        $arguments = @(
            "--remote-debugging-port=$RemoteDebuggingPort",
            "--user-data-dir=$UserDataDir",
            '--no-first-run',
            '--disable-background-timer-throttling',
            '--disable-renderer-backgrounding',
            'https://photos.google.com/'
        )
        if ($NewWindow) { $arguments = @('--new-window') + $arguments }
        Write-Verbose "Starting Chrome: $ChromePath $($arguments -join ' ')"
        $script:GPDState.ChromeProcess = Start-Process -FilePath $ChromePath -ArgumentList $arguments -PassThru
        Start-Sleep -Seconds 3
        $version = Invoke-GPDRest -Path '/json/version' -Port $RemoteDebuggingPort -ErrorAction Stop
    }

    $target = Get-GPDPhotosTarget -Port $RemoteDebuggingPort
    if (-not $target) {
        $null = New-GPDChromeTarget -Url 'https://photos.google.com/' -Port $RemoteDebuggingPort
        Start-Sleep -Seconds 1
        $target = Get-GPDPhotosTarget -Port $RemoteDebuggingPort
    }
    if (-not $target) { throw 'Could not open or locate a Google Photos Chrome target.' }

    $script:GPDState.BrowserVersion = $version
    $script:GPDState.ActiveTarget = $target
    $script:GPDState.ActiveWebSocketUrl = $target.webSocketDebuggerUrl

    [pscustomobject]@{
        Connected = $true
        RemoteDebuggingPort = $RemoteDebuggingPort
        UserDataDir = $UserDataDir
        Browser = $version.Browser
        TargetUrl = $target.url
        TargetTitle = $target.title
    }
}

function Start-GPDLibraryScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DatabasePath,
        [int]$MaxScrolls = 1000,
        [int]$ThrottleMs = 1200,
        [int]$HashConcurrency = 8,
        [switch]$FromTop,
        [switch]$StopWhenNoNewItems,
        [int]$NoNewItemRounds = 20
    )

    Assert-GPDBrowserConnected
    Initialize-GPDStore -DatabasePath $DatabasePath

    if ($FromTop) {
        Invoke-GPDChromeEvaluate -Expression 'window.scrollTo(0, 0); true;' | Out-Null
        Start-Sleep -Milliseconds 1000
    }

    $existingIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in Read-GPDMediaStore -DatabasePath $DatabasePath) {
        if ($item.LocalId) { [void]$existingIds.Add([string]$item.LocalId) }
    }

    $totalNew = 0
    $roundsWithoutNew = 0

    for ($scroll = 0; $scroll -lt $MaxScrolls; $scroll++) {
        $rawItems = @(Get-GPDVisibleTile)
        $normalised = @($rawItems | ForEach-Object -Parallel {
            $record = $_
            $source = @($record.ItemUrl, $record.ThumbnailUrl, $record.AriaLabel, $record.VisualHash64, $record.Width, $record.Height) -join '|'
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($source)
                $hash = $sha.ComputeHash($bytes)
                $localId = -join ($hash | ForEach-Object { $_.ToString('x2') })
            }
            finally { $sha.Dispose() }

            [pscustomobject]@{
                RecordType = 'MediaItem'
                LocalId = $localId
                Kind = $record.Kind
                ItemUrl = $record.ItemUrl
                MediaKey = $record.MediaKey
                ThumbnailUrl = $record.ThumbnailUrl
                VisualHash64 = $record.VisualHash64
                ApproxDate = $record.ApproxDate
                AriaLabel = $record.AriaLabel
                Width = $record.Width
                Height = $record.Height
                AspectBucket = if ($record.Width -and $record.Height) { [math]::Round(([double]$record.Width / [double]$record.Height), 2).ToString('0.00') } else { $null }
                ScrollY = $record.ScrollY
                SeenUtc = [datetime]::UtcNow.ToString('o')
                Deleted = $false
            }
        } -ThrottleLimit ([Math]::Max(1, $HashConcurrency)))

        $newRecords = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $normalised) {
            if ($item.LocalId -and $existingIds.Add([string]$item.LocalId)) { $newRecords.Add($item) }
        }

        if ($newRecords.Count -gt 0) {
            Add-GPDJsonLine -DatabasePath $DatabasePath -InputObject $newRecords
            $totalNew += $newRecords.Count
            $roundsWithoutNew = 0
        }
        else { $roundsWithoutNew++ }

        Write-Progress -Activity 'Scanning Google Photos timeline' -Status "Scroll $($scroll + 1)/$MaxScrolls - new: $($newRecords.Count), total: $totalNew" -PercentComplete ((($scroll + 1) / [Math]::Max(1, $MaxScrolls)) * 100)
        Write-Verbose "Scroll $($scroll + 1): visible=$($rawItems.Count), new=$($newRecords.Count), no-new-rounds=$roundsWithoutNew"

        if ($StopWhenNoNewItems -and $roundsWithoutNew -ge $NoNewItemRounds) { break }
        Invoke-GPDChromeEvaluate -Expression 'window.scrollBy(0, Math.round(window.innerHeight * 0.85)); document.scrollingElement ? document.scrollingElement.scrollTop : window.scrollY;' | Out-Null
        Start-Sleep -Milliseconds $ThrottleMs
    }

    Write-Progress -Activity 'Scanning Google Photos timeline' -Completed
    [pscustomobject]@{ DatabasePath = (Resolve-Path -LiteralPath $DatabasePath).Path; TotalNew = $totalNew; MaxScrolls = $MaxScrolls }
}

function Get-GPDMediaItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DatabasePath,
        [string[]]$LocalId,
        [string[]]$ItemUrl,
        [string[]]$MediaKey,
        [string]$VisualHash64,
        [datetime]$ApproxDate,
        [ValidateSet('Photo','Video')] [string]$Kind
    )
    Resolve-GPDMediaItem @PSBoundParameters
}

function Resolve-GPDMediaItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DatabasePath,
        [string[]]$LocalId,
        [string[]]$ItemUrl,
        [string[]]$MediaKey,
        [string]$VisualHash64,
        [string]$ThumbnailUrl,
        [datetime]$ApproxDate,
        [ValidateSet('Photo','Video')] [string]$Kind
    )

    $items = @(Read-GPDMediaStore -DatabasePath $DatabasePath)
    if ($LocalId) { $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$LocalId, [System.StringComparer]::OrdinalIgnoreCase); $items = @($items | Where-Object { $_.LocalId -and $set.Contains([string]$_.LocalId) }) }
    if ($ItemUrl) { $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$ItemUrl, [System.StringComparer]::OrdinalIgnoreCase); $items = @($items | Where-Object { $_.ItemUrl -and $set.Contains([string]$_.ItemUrl) }) }
    if ($MediaKey) { $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$MediaKey, [System.StringComparer]::OrdinalIgnoreCase); $items = @($items | Where-Object { $_.MediaKey -and $set.Contains([string]$_.MediaKey) }) }
    if ($VisualHash64) { $items = @($items | Where-Object { $_.VisualHash64 -eq $VisualHash64 }) }
    if ($ThumbnailUrl) { $items = @($items | Where-Object { $_.ThumbnailUrl -eq $ThumbnailUrl }) }
    if ($PSBoundParameters.ContainsKey('ApproxDate')) { $dateText = $ApproxDate.ToString('yyyy-MM-dd'); $items = @($items | Where-Object { $_.ApproxDate -eq $dateText }) }
    if ($Kind) { $items = @($items | Where-Object { $_.Kind -eq $Kind }) }
    $items | Sort-Object ApproxDate, Kind, LocalId
}

function Get-GPDDuplicateGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DatabasePath,
        [ValidateSet('ExactVisualHash','Conservative','Relaxed')] [string]$Similarity = 'Conservative',
        [int]$MaxBucketSize = 1500
    )

    $items = @(Read-GPDMediaStore -DatabasePath $DatabasePath | Where-Object { -not $_.Deleted })
    $groups = [System.Collections.Generic.List[object]]::new()
    $groupNumber = 0

    foreach ($group in ($items | Where-Object { $_.ThumbnailUrl } | Group-Object ThumbnailUrl | Where-Object { $_.Count -gt 1 })) {
        $groupNumber++
        $groups.Add((New-GPDDuplicateGroupObject -GroupNumber $groupNumber -Reason 'SameThumbnailUrl' -Members @($group.Group)))
    }

    if ($Similarity -eq 'ExactVisualHash') {
        foreach ($group in ($items | Where-Object { $_.VisualHash64 } | Group-Object Kind, VisualHash64 | Where-Object { $_.Count -gt 1 })) {
            $groupNumber++
            $groups.Add((New-GPDDuplicateGroupObject -GroupNumber $groupNumber -Reason 'SameVisualHash64' -Members @($group.Group)))
        }
        return $groups
    }

    $threshold = if ($Similarity -eq 'Relaxed') { 8 } else { 4 }
    $buckets = $items | Where-Object { $_.VisualHash64 -and $_.ApproxDate -and $_.AspectBucket } | Group-Object Kind, ApproxDate, AspectBucket
    foreach ($bucket in $buckets) {
        $bucketItems = @($bucket.Group)
        if ($bucketItems.Count -lt 2) { continue }
        if ($bucketItems.Count -gt $MaxBucketSize) { Write-Warning "Skipping oversized bucket '$($bucket.Name)' with $($bucketItems.Count) items."; continue }
        $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        for ($i = 0; $i -lt $bucketItems.Count; $i++) {
            $seed = $bucketItems[$i]
            if ($used.Contains([string]$seed.LocalId)) { continue }
            $members = [System.Collections.Generic.List[object]]::new()
            $members.Add($seed)
            for ($j = $i + 1; $j -lt $bucketItems.Count; $j++) {
                $candidate = $bucketItems[$j]
                if ($used.Contains([string]$candidate.LocalId)) { continue }
                $distance = Get-GPDHammingDistanceHex -Left $seed.VisualHash64 -Right $candidate.VisualHash64
                if ($distance -le $threshold) {
                    $candidate | Add-Member -NotePropertyName HashDistanceFromSeed -NotePropertyValue $distance -Force
                    $members.Add($candidate)
                }
            }
            if ($members.Count -gt 1) {
                foreach ($member in $members) { [void]$used.Add([string]$member.LocalId) }
                $groupNumber++
                $groups.Add((New-GPDDuplicateGroupObject -GroupNumber $groupNumber -Reason "VisualHashDistance<=$threshold" -Members @($members)))
            }
        }
    }
    $groups | Sort-Object Confidence, Count -Descending
}

function Export-GPDReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$DatabasePath,
        [Parameter(Mandatory)] [string]$Path,
        [ValidateSet('ExactVisualHash','Conservative','Relaxed')] [string]$Similarity = 'Conservative',
        [switch]$Open
    )

    $groups = @(Get-GPDDuplicateGroup -DatabasePath $DatabasePath -Similarity $Similarity)
    $outDir = Split-Path -Parent $Path
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    $cards = foreach ($group in $groups) {
        $members = foreach ($item in $group.Members) {
            $safeUrl = [System.Web.HttpUtility]::HtmlEncode([string]$item.ItemUrl)
            $safeThumb = [System.Web.HttpUtility]::HtmlEncode([string]$item.ThumbnailUrl)
            $safeId = [System.Web.HttpUtility]::HtmlEncode([string]$item.LocalId)
            $safeHash = [System.Web.HttpUtility]::HtmlEncode([string]$item.VisualHash64)
            $safeDate = [System.Web.HttpUtility]::HtmlEncode([string]$item.ApproxDate)
            $safeKind = [System.Web.HttpUtility]::HtmlEncode([string]$item.Kind)
            $badge = if ($item.LocalId -eq $group.ProposedKeeperLocalId) { '<span class="keeper">KEEPER</span>' } else { '<span class="deleteCandidate">candidate</span>' }
            $image = if ($safeThumb) { "<img src='$safeThumb' loading='lazy' alt='thumbnail' />" } else { '<div class="noThumb">No thumbnail</div>' }
            $link = if ($safeUrl) { "<a href='$safeUrl' target='_blank' rel='noreferrer'>Open in Google Photos</a>" } else { '<span>No link captured</span>' }
            "<article class='item'>$image<div class='meta'>$badge<div><b>$safeKind</b> $safeDate</div><code>$safeId</code><code>$safeHash</code><div>$link</div></div></article>"
        }
        "<section class='group'><h2>Group $($group.GroupId) <span>$($group.Reason)</span></h2><p>Confidence: $($group.Confidence) · Items: $($group.Count)</p><div class='items'>$($members -join "`n")</div></section>"
    }

    $generated = [datetime]::UtcNow.ToString('u')
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Google Photos Duplicate Review</title>
<style>:root{color-scheme:dark;--bg:#101018;--panel:#181827;--cyan:#25d9ff;--text:#f8f8ff;--muted:#b8b8cc;--good:#7CFF6B;--warn:#ffcc66}body{margin:0;font-family:Segoe UI,Roboto,Arial,sans-serif;background:radial-gradient(circle at top left,#32104b,var(--bg) 40%),var(--bg);color:var(--text)}header{padding:32px;background:linear-gradient(120deg,rgba(255,79,216,.25),rgba(37,217,255,.18));border-bottom:1px solid rgba(255,255,255,.12)}h1{margin:0;font-size:clamp(2rem,4vw,4rem)}.summary{color:var(--muted);font-size:1.1rem}.group{margin:24px;padding:18px;border:1px solid rgba(255,255,255,.12);background:rgba(24,24,39,.9);border-radius:18px;box-shadow:0 12px 30px rgba(0,0,0,.25)}h2{margin:0 0 8px}h2 span{color:var(--cyan);font-size:.9rem}.items{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:14px}.item{border:1px solid rgba(255,255,255,.10);border-radius:14px;overflow:hidden;background:#0d0d15}.item img,.noThumb{width:100%;height:210px;object-fit:cover;background:#05050a;display:flex;align-items:center;justify-content:center;color:var(--muted)}.meta{padding:12px;display:grid;gap:6px}code{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#d7d7ff;background:#07070b;padding:4px;border-radius:6px}a{color:var(--cyan)}.keeper{color:var(--good);font-weight:800}.deleteCandidate{color:var(--warn);font-weight:700}</style>
</head><body><header><h1>Google Photos Duplicate Review</h1><p class="summary">Generated $generated · Groups: $($groups.Count) · Similarity: $Similarity</p></header><main>$($cards -join "`n")</main></body></html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
    if ($Open) { Invoke-Item -LiteralPath $Path }
    [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; GroupCount = $groups.Count; Similarity = $Similarity }
}

function Remove-GPDMediaItem {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] [string]$DatabasePath,
        [Parameter(ValueFromPipelineByPropertyName)] [string[]]$LocalId,
        [string[]]$ItemUrl,
        [string[]]$MediaKey,
        [string]$VisualHash64,
        [string]$ThumbnailUrl,
        [datetime]$ApproxDate,
        [ValidateSet('Photo','Video')] [string]$Kind,
        [switch]$Force,
        [switch]$PassThru
    )

    begin { Assert-GPDBrowserConnected }
    process {
        $resolveParams = @{ DatabasePath = $DatabasePath }
        foreach ($name in 'LocalId','ItemUrl','MediaKey','VisualHash64','ThumbnailUrl','ApproxDate','Kind') {
            if ($PSBoundParameters.ContainsKey($name)) { $resolveParams[$name] = Get-Variable -Name $name -ValueOnly }
        }
        $matches = @(Resolve-GPDMediaItem @resolveParams)
        if ($matches.Count -eq 0) { throw 'No Google Photos media item matched the supplied identifier properties.' }
        if ($matches.Count -gt 1 -and -not $Force) {
            $matches | Select-Object LocalId, Kind, ApproxDate, ItemUrl, VisualHash64 | Format-Table | Out-String | Write-Warning
            throw "Identifier properties matched $($matches.Count) items. Refusing to delete. Supply a stronger identifier or use -Force after manual review."
        }
        foreach ($item in $matches) {
            if (-not $item.ItemUrl) { throw "Item $($item.LocalId) has no ItemUrl. Cannot safely delete through the browser UI." }
            if ($PSCmdlet.ShouldProcess($item.ItemUrl, 'Move Google Photos item to Trash')) {
                $result = Invoke-GPDBrowserDelete -Item $item -DatabasePath $DatabasePath
                if ($PassThru) { $result }
            }
        }
    }
}

function Invoke-GPDDeduplication {
    [CmdletBinding()]
    param(
        [switch]$Connect,
        [switch]$Scan,
        [switch]$FindDuplicates,
        [Parameter(Mandatory)] [string]$DatabasePath,
        [int]$MaxScrolls = 1000,
        [int]$ThrottleMs = 1200,
        [int]$HashConcurrency = 8,
        [string]$ExportReportPath,
        [switch]$OpenReport
    )
    $result = [ordered]@{}
    if ($Connect) { $result.Connect = Connect-GPDBrowser }
    if ($Scan) { $result.Scan = Start-GPDLibraryScan -DatabasePath $DatabasePath -MaxScrolls $MaxScrolls -ThrottleMs $ThrottleMs -HashConcurrency $HashConcurrency -StopWhenNoNewItems }
    if ($FindDuplicates) { $result.DuplicateGroups = @(Get-GPDDuplicateGroup -DatabasePath $DatabasePath -Similarity Conservative) }
    if ($ExportReportPath) { $result.Report = Export-GPDReport -DatabasePath $DatabasePath -Path $ExportReportPath -Open:$OpenReport }
    [pscustomobject]$result
}

function Invoke-GPDDetractorReview {
    [CmdletBinding()]
    param()
    $findings = [System.Collections.Generic.List[object]]::new()
    $moduleFile = Join-Path $PSScriptRoot 'GooglePhotosDeDuplicate.Core.psm1'
    $manifestFile = Join-Path $PSScriptRoot 'Google-PhotosDeDuplicate.psd1'
    foreach ($path in @($moduleFile, $manifestFile)) {
        if (-not (Test-Path -LiteralPath $path)) { $findings.Add([pscustomobject]@{ Severity = 'Error'; Rule = 'RequiredFile'; Message = "Missing file: $path" }) }
    }
    if (Test-Path -LiteralPath $moduleFile) {
        $content = Get-Content -LiteralPath $moduleFile -Raw
        if ($content -notmatch 'SupportsShouldProcess') { $findings.Add([pscustomobject]@{ Severity = 'Error'; Rule = 'DeletionSafety'; Message = 'Remove-GPDMediaItem should support ShouldProcess.' }) }
        if ($content -notmatch 'Identifier properties matched') { $findings.Add([pscustomobject]@{ Severity = 'Error'; Rule = 'AmbiguitySafety'; Message = 'Deletion should refuse ambiguous identifier matches.' }) }
        if ($content -match 'password\s*=|client_secret|refresh_token') { $findings.Add([pscustomobject]@{ Severity = 'Error'; Rule = 'SecretPattern'; Message = 'Potential secret-like string found in module.' }) }
        if ($content -notmatch 'targetResponse = \$null') { $findings.Add([pscustomobject]@{ Severity = 'Error'; Rule = 'CDPResponseMatching'; Message = 'WebSocket helper must wait for the matching CDP response id.' }) }
    }
    [pscustomobject]@{ Passed = -not @($findings | Where-Object Severity -eq 'Error'); FindingCount = $findings.Count; Findings = @($findings) }
}

function Get-GPDChromePath {
    [CmdletBinding()]
    param()
    $candidates = @()
    if ($IsWindows) {
        $candidates += Join-Path ${env:ProgramFiles} 'Google\Chrome\Application\chrome.exe'
        $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
        if ($programFilesX86) { $candidates += Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe' }
        $candidates += Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'
    }
    else {
        $candidates += '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
        $candidates += '/usr/bin/google-chrome'
        $candidates += '/usr/bin/google-chrome-stable'
        $candidates += '/snap/bin/chromium'
    }
    foreach ($candidate in $candidates) { if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate } }
    $command = Get-Command chrome, google-chrome, google-chrome-stable, chromium -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $null
}

function Invoke-GPDRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Path,
        [int]$Port = $script:GPDState.RemoteDebuggingPort,
        [ValidateSet('Get','Put')] [string]$Method = 'Get'
    )
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port$Path" -Method $Method -TimeoutSec 10
}

function Get-GPDPhotosTarget {
    [CmdletBinding()]
    param([int]$Port = $script:GPDState.RemoteDebuggingPort)
    $targets = @(Invoke-GPDRest -Path '/json/list' -Port $Port)
    $photos = $targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'https://photos.google.com/*' } | Select-Object -First 1
    if ($photos) { return $photos }
    $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
}

function New-GPDChromeTarget {
    [CmdletBinding()]
    param([string]$Url = 'https://photos.google.com/', [int]$Port = $script:GPDState.RemoteDebuggingPort)
    Invoke-GPDRest -Path "/json/new?$([uri]::EscapeDataString($Url))" -Port $Port -Method Put
}

function Assert-GPDBrowserConnected {
    if (-not $script:GPDState.ActiveWebSocketUrl) {
        $target = Get-GPDPhotosTarget -ErrorAction SilentlyContinue
        if ($target) { $script:GPDState.ActiveTarget = $target; $script:GPDState.ActiveWebSocketUrl = $target.webSocketDebuggerUrl }
    }
    if (-not $script:GPDState.ActiveWebSocketUrl) { throw 'Not connected to Chrome. Run Connect-GPDBrowser first.' }
}

function Invoke-GPDChromeEvaluate {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Expression, [int]$TimeoutSeconds = 60)
    Assert-GPDBrowserConnected
    $id = Get-Random -Minimum 1000 -Maximum 999999
    $message = [pscustomobject]@{
        id = $id
        method = 'Runtime.evaluate'
        params = [pscustomobject]@{ expression = $Expression; awaitPromise = $true; returnByValue = $true; userGesture = $true }
    } | ConvertTo-Json -Depth 20 -Compress
    Invoke-GPDWebSocketMessage -WebSocketUrl $script:GPDState.ActiveWebSocketUrl -JsonMessage $message -ExpectedId $id -TimeoutSeconds $TimeoutSeconds
}

function Invoke-GPDWebSocketMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$WebSocketUrl,
        [Parameter(Mandatory)] [string]$JsonMessage,
        [Parameter(Mandatory)] [int]$ExpectedId,
        [int]$TimeoutSeconds = 60
    )
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $cts = [System.Threading.CancellationTokenSource]::new([timespan]::FromSeconds($TimeoutSeconds))
    try {
        $socket.ConnectAsync([uri]$WebSocketUrl, $cts.Token).GetAwaiter().GetResult()
        $sendBytes = [System.Text.Encoding]::UTF8.GetBytes($JsonMessage)
        $socket.SendAsync([ArraySegment[byte]]::new($sendBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
        $buffer = [byte[]]::new(1048576)
        $targetResponse = $null
        while (-not $targetResponse) {
            $builder = [System.Text.StringBuilder]::new()
            do {
                $receive = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cts.Token).GetAwaiter().GetResult()
                if ($receive.Count -gt 0) { [void]$builder.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $receive.Count)) }
            } until ($receive.EndOfMessage)
            $candidate = $builder.ToString() | ConvertFrom-Json
            if ($candidate.id -eq $ExpectedId) { $targetResponse = $candidate }
        }
        if ($targetResponse.error) { throw ($targetResponse.error | ConvertTo-Json -Depth 10) }
        if ($targetResponse.result.result.subtype -eq 'error') { throw $targetResponse.result.result.description }
        $targetResponse.result.result.value
    }
    finally {
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) { $socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() }
        $socket.Dispose()
        $cts.Dispose()
    }
}

function Get-GPDVisibleTile {
    [CmdletBinding()]
    param()
    $script = @'
(async () => {
  const toGray = (r,g,b) => 0.299*r + 0.587*g + 0.114*b;
  const hashImage = async (img) => {
    try {
      if (!img.complete || !img.naturalWidth || !img.naturalHeight) { return null; }
      const canvas = document.createElement('canvas'); canvas.width = 9; canvas.height = 8;
      const ctx = canvas.getContext('2d', { willReadFrequently: true }); ctx.drawImage(img, 0, 0, 9, 8);
      const data = ctx.getImageData(0, 0, 9, 8).data; let bits = '';
      for (let y = 0; y < 8; y++) { for (let x = 0; x < 8; x++) {
        const i1 = (y * 9 + x) * 4; const i2 = (y * 9 + x + 1) * 4;
        bits += toGray(data[i1], data[i1+1], data[i1+2]) > toGray(data[i2], data[i2+1], data[i2+2]) ? '1' : '0';
      }}
      let out = ''; for (let i = 0; i < 64; i += 4) { out += parseInt(bits.slice(i, i+4), 2).toString(16); }
      return out.padStart(16, '0');
    } catch { return null; }
  };
  const visible = (el) => { const r = el.getBoundingClientRect(); return r.width >= 40 && r.height >= 40 && r.bottom >= 0 && r.right >= 0 && r.top <= innerHeight && r.left <= innerWidth; };
  const normaliseDate = (text) => { if (!text) return null; const iso = text.match(/\b(20\d{2}|19\d{2})[-/](\d{1,2})[-/](\d{1,2})\b/); return iso ? `${iso[1]}-${String(iso[2]).padStart(2,'0')}-${String(iso[3]).padStart(2,'0')}` : null; };
  const mediaKeyFromUrl = (url) => { if (!url) return null; const m = url.match(/\/photo\/([^/?#]+)/) || url.match(/\/video\/([^/?#]+)/); return m ? decodeURIComponent(m[1]) : null; };
  const imgs = Array.from(document.querySelectorAll('img')).filter(visible); const records = [];
  for (const img of imgs) {
    const src = img.currentSrc || img.src || ''; if (!src || !/googleusercontent|photos/i.test(src)) continue;
    const anchor = img.closest('a[href]'); const labelled = img.closest('[aria-label]');
    const aria = (labelled && labelled.getAttribute('aria-label')) || img.alt || img.title || '';
    const itemUrl = anchor ? anchor.href : null;
    records.push({ Kind: /video|movie|play/i.test(aria) ? 'Video' : 'Photo', ItemUrl: itemUrl, MediaKey: mediaKeyFromUrl(itemUrl), ThumbnailUrl: src, VisualHash64: await hashImage(img), ApproxDate: normaliseDate(aria), AriaLabel: aria, Width: img.naturalWidth || null, Height: img.naturalHeight || null, ScrollY: Math.round(window.scrollY || document.documentElement.scrollTop || 0) });
  }
  return records;
})()
'@
    @(Invoke-GPDChromeEvaluate -Expression $script -TimeoutSeconds 90)
}

function Initialize-GPDStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DatabasePath)
    $directory = Split-Path -Parent $DatabasePath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $DatabasePath)) { New-Item -ItemType File -Path $DatabasePath -Force | Out-Null }
}

function Add-GPDJsonLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DatabasePath, [Parameter(Mandatory)] [object[]]$InputObject)
    Initialize-GPDStore -DatabasePath $DatabasePath
    $lines = foreach ($object in $InputObject) { $object | ConvertTo-Json -Depth 20 -Compress }
    Add-Content -LiteralPath $DatabasePath -Value $lines -Encoding UTF8
}

function Read-GPDMediaStore {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$DatabasePath)
    if (-not (Test-Path -LiteralPath $DatabasePath)) { return @() }
    $latest = [ordered]@{}
    Get-Content -LiteralPath $DatabasePath -ReadCount 1000 | ForEach-Object {
        foreach ($line in $_) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $record = $line | ConvertFrom-Json } catch { continue }
            if ($record.RecordType -eq 'MediaItem' -and $record.LocalId) { $latest[[string]$record.LocalId] = $record }
            elseif ($record.RecordType -eq 'DeleteAudit' -and $record.LocalId -and $latest.Contains([string]$record.LocalId)) {
                $latest[[string]$record.LocalId].Deleted = $true
                $latest[[string]$record.LocalId] | Add-Member -NotePropertyName DeleteResult -NotePropertyValue $record.Result -Force
                $latest[[string]$record.LocalId] | Add-Member -NotePropertyName DeleteAttemptedUtc -NotePropertyValue $record.AttemptedUtc -Force
            }
        }
    }
    @($latest.Values)
}

function Get-GPDHammingDistanceHex {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Left, [Parameter(Mandatory)] [string]$Right)
    if ($Left.Length -ne $Right.Length) { return [int]::MaxValue }
    $distance = 0
    for ($i = 0; $i -lt $Left.Length; $i++) {
        $x = [Convert]::ToInt32($Left[$i].ToString(), 16) -bxor [Convert]::ToInt32($Right[$i].ToString(), 16)
        while ($x -gt 0) { $distance += ($x -band 1); $x = $x -shr 1 }
    }
    $distance
}

function New-GPDDuplicateGroupObject {
    [CmdletBinding()]
    param([int]$GroupNumber, [string]$Reason, [object[]]$Members)
    $orderedMembers = @($Members | Sort-Object @{ Expression = { if ($_.Width -and $_.Height) { [int]$_.Width * [int]$_.Height } else { 0 } }; Descending = $true }, LocalId)
    [pscustomobject]@{ GroupId = ('G{0:000000}' -f $GroupNumber); Reason = $Reason; Confidence = if ($Reason -eq 'SameThumbnailUrl') { 100 } elseif ($Reason -eq 'SameVisualHash64') { 95 } else { 80 }; Count = $orderedMembers.Count; ProposedKeeperLocalId = $orderedMembers[0].LocalId; Members = $orderedMembers }
}

function Invoke-GPDBrowserDelete {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object]$Item, [Parameter(Mandatory)] [string]$DatabasePath)
    $navScript = "location.href = '$([System.Web.HttpUtility]::JavaScriptStringEncode([string]$Item.ItemUrl))'; true;"
    Invoke-GPDChromeEvaluate -Expression $navScript | Out-Null
    Start-Sleep -Seconds 3
    $deleteScript = @'
(async () => {
  const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));
  const isVisible = (el) => { if (!el) return false; const r = el.getBoundingClientRect(); const s = getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const textOf = (el) => [el.getAttribute('aria-label'), el.getAttribute('title'), el.textContent].filter(Boolean).join(' ');
  const clickMatching = (patterns) => { const candidates = Array.from(document.querySelectorAll('button, [role="button"], div[aria-label], span[aria-label]')).filter(isVisible); for (const el of candidates) { const text = textOf(el); if (patterns.some(p => p.test(text))) { el.click(); return { clicked: true, text }; } } return { clicked: false, text: null }; };
  let first = clickMatching([/move to trash/i, /move to bin/i, /^delete$/i, /trash/i, /bin/i]);
  if (!first.clicked) return { ok:false, stage:'delete-button-not-found' };
  await sleep(900);
  let second = clickMatching([/move to trash/i, /move to bin/i, /^delete$/i, /^ok$/i, /^confirm$/i]);
  if (!second.clicked) return { ok:false, stage:'confirm-button-not-found', first:first };
  await sleep(1200);
  return { ok:true, first:first, second:second, url: location.href };
})()
'@
    $result = Invoke-GPDChromeEvaluate -Expression $deleteScript -TimeoutSeconds 30
    $status = if ($result.ok) { 'MovedToTrash' } else { "Failed:$($result.stage)" }
    Add-GPDJsonLine -DatabasePath $DatabasePath -InputObject @([pscustomobject]@{ RecordType = 'DeleteAudit'; LocalId = $Item.LocalId; ItemUrl = $Item.ItemUrl; AttemptedUtc = [datetime]::UtcNow.ToString('o'); Result = $status; BrowserResult = $result })
    if (-not $result.ok) { throw "Browser deletion failed for $($Item.LocalId): $($result.stage)" }
    [pscustomobject]@{ LocalId = $Item.LocalId; ItemUrl = $Item.ItemUrl; Result = $status }
}

Export-ModuleMember -Function @(
    'Connect-GPDBrowser',
    'Test-GPDEnvironment',
    'Start-GPDLibraryScan',
    'Get-GPDMediaItem',
    'Resolve-GPDMediaItem',
    'Get-GPDDuplicateGroup',
    'Export-GPDReport',
    'Remove-GPDMediaItem',
    'Invoke-GPDDeduplication',
    'Invoke-GPDDetractorReview'
)
