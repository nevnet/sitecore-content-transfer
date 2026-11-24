#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ContentBase = '/sitecore/api/content/transfer/v1/transfers'
$script:ItemBase = '/sitecore/shell/api/v3/ItemsTransfer'
$script:Strategies = @('KeepExistingItem', 'OverrideExistingItem', 'OverrideExistingTree')

function Protect-TransferText {
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [AllowNull()]$Runtime)
    if ($null -eq $Text) { return '' }
    if ($Runtime) {
        foreach ($secret in $Runtime.Secrets) {
            if ($secret) {
                $encoded = [uri]::EscapeDataString($secret)
                $jsonString = ConvertTo-Json -InputObject $secret -Compress
                $Text = $Text.Replace($jsonString.Substring(1, $jsonString.Length - 2), '[REDACTED]')
                $Text = $Text.Replace($secret, '[REDACTED]').Replace($encoded, '[REDACTED]').Replace($encoded.Replace('%20', '+'), '[REDACTED]')
            }
        }
    }
    $Text = $Text -replace '(?i)Bearer\s+[^\s"'',;]+', 'Bearer [REDACTED]'
    $Text = $Text -replace '(?i)(\b(?:Proxy-)?Authorization\s*:\s*)[^\r\n]*', '$1[REDACTED]'
    $Text = $Text -replace '(?i)(\b(?:Set-Cookie|Cookie)\s*:\s*)[^\r\n]*', '$1[REDACTED]'
    $Text = $Text -replace '(?i)("(?:authorization|client[_-]?id|client[_-]?secret|access[_-]?token|refresh[_-]?token|password|secret|token)"\s*:\s*")(?:\\.|[^"\\])*', '$1[REDACTED]'
    $Text = $Text -replace '(?i)([?&](?:[^=&\s]*(?:secret|token|password|signature|api[_-]?key)|sig|code|client_id)=)[^&\s"'']*', '$1[REDACTED]'
    return $Text
}

function Write-TransferLog {
    param([string]$Message, $Runtime)
    Write-Information ("[{0}] {1}" -f [datetime]::UtcNow.ToString('HH:mm:ss'), (Protect-TransferText $Message $Runtime)) -InformationAction Continue
}

function Read-TransferConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath, [string]$MergeStrategyOverride)
    if ($MergeStrategyOverride -and $MergeStrategyOverride -cnotin $script:Strategies) { throw 'Invalid merge strategy override.' }
    try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { throw 'Cannot read configuration: supply a readable file containing valid JSON.' }
    if ($config -isnot [System.Collections.IDictionary] -or
        $config.database -isnot [string] -or $config.database -notmatch '^[A-Za-z0-9_-]+$' -or
        $config.paths -isnot [array] -or $config.paths.Count -eq 0) {
        throw 'Configuration requires a database name and a nonempty paths array.'
    }
    if (@($config.Keys | Where-Object { $_ -cnotin @('database', 'paths') }).Count) {
        throw 'Configuration supports only database and paths; TransferId and Configuration are generated at runtime.'
    }
    $trees = @()
    foreach ($path in $config.paths) {
        if ($path -isnot [System.Collections.IDictionary] -or
            $path.itemPath -isnot [string] -or $path.itemPath -notmatch '^/sitecore(?:/[^/\r\n]+)*$' -or
            $path.itemPath -ne $path.itemPath.Trim() -or $path.itemPath -match '[/]\.\.?(/|$)|[\\\x00-\x1f]' -or
            $path.scope -cnotin @('SingleItem', 'ItemAndDescendants') -or $path.mergeStrategy -cnotin $script:Strategies) {
            throw 'Each path requires an absolute Sitecore itemPath, scope (SingleItem or ItemAndDescendants), and a valid mergeStrategy.'
        }
        if (@($path.Keys | Where-Object { $_ -cnotin @('itemPath', 'scope', 'mergeStrategy') }).Count) {
            throw 'Path entries support only itemPath, scope, and mergeStrategy.'
        }
        foreach ($tree in $trees) {
            if ($path.itemPath.Equals($tree.ItemPath, [StringComparison]::OrdinalIgnoreCase) -or
                $path.itemPath.StartsWith($tree.ItemPath + '/', [StringComparison]::OrdinalIgnoreCase) -or
                $tree.ItemPath.StartsWith($path.itemPath + '/', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Configuration paths overlap (case-insensitive duplicates or ancestor/descendant roots). Choose disjoint roots.'
            }
        }
        $trees += @{
            ItemPath = $path.itemPath
            Scope = $path.scope
            MergeStrategy = $(if ($MergeStrategyOverride) { $MergeStrategyOverride } else { $path.mergeStrategy })
        }
    }
    return @{ Database = $config.database; DataTrees = $trees }
}

function ConvertTo-TransferOrigin {
    param([string]$Value)
    $parsed = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$parsed) -or
        $parsed.Scheme -ne 'https' -or $parsed.UserInfo -or $parsed.Query -or $parsed.Fragment -or $parsed.AbsolutePath -ne '/') {
        throw 'Environment URLs must be HTTPS origins, without credentials, paths, queries or fragments.'
    }
    return $parsed.GetLeftPart([UriPartial]::Authority)
}

function New-TransferRuntime {
    [CmdletBinding()]
    param(
        [string]$SourceBaseUrl, [string]$DestinationBaseUrl,
        [string]$SourceClientId = $env:SITECORE_TRANSFER_SOURCE_CLIENT_ID,
        [string]$SourceClientSecret = $env:SITECORE_TRANSFER_SOURCE_CLIENT_SECRET,
        [string]$SourceAccessToken = $env:SITECORE_TRANSFER_SOURCE_ACCESS_TOKEN,
        [string]$DestinationClientId = $env:SITECORE_TRANSFER_DESTINATION_CLIENT_ID,
        [string]$DestinationClientSecret = $env:SITECORE_TRANSFER_DESTINATION_CLIENT_SECRET,
        [string]$DestinationAccessToken = $env:SITECORE_TRANSFER_DESTINATION_ACCESS_TOKEN
    )
    $source = ConvertTo-TransferOrigin $SourceBaseUrl
    $destination = ConvertTo-TransferOrigin $DestinationBaseUrl
    if ($source -eq $destination) { throw 'Source and destination must be different environments.' }
    $auth = @{}
    $secrets = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @(
        @{ Name = 'Source'; Id = $SourceClientId; Secret = $SourceClientSecret; Token = $SourceAccessToken },
        @{ Name = 'Destination'; Id = $DestinationClientId; Secret = $DestinationClientSecret; Token = $DestinationAccessToken }
    )) {
        if (-not $entry.Token -and (-not $entry.Id -or -not $entry.Secret)) {
            throw "Supply $($entry.Name) environment automation client credentials or an access token through SITECORE_TRANSFER_* environment variables."
        }
        foreach ($value in @($entry.Id, $entry.Secret, $entry.Token)) { if ($value) { $secrets.Add($value) } }
        $expires = [datetime]::UtcNow.AddHours(24).AddMinutes(-5)
        if ($entry.Token) {
            try {
                $payload = $entry.Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
                $payload = $payload.PadRight([int]([math]::Ceiling($payload.Length / 4.0) * 4), '=')
                $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
                if ($claims.exp) { $expires = [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).UtcDateTime.AddSeconds(-60) }
            }
            catch { throw "The $($entry.Name) access token must be a JWT with a readable payload." }
        }
        $auth[$entry.Name] = @{ ClientId = $entry.Id; ClientSecret = $entry.Secret; Token = $entry.Token; ExpiresUtc = $expires }
    }
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.UseCookies = $false
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
    $handler.PooledConnectionLifetime = [timespan]::FromMinutes(10)
    $handler.ConnectTimeout = [timespan]::FromSeconds(30)
    $client = [System.Net.Http.HttpClient]::new($handler, $true)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    return @{ Client = $client; Source = $source; Destination = $destination; Auth = $auth; Secrets = $secrets; RequestTimeoutSeconds = 300 }
}

function Get-TransferToken {
    param($Runtime, [string]$Environment, [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None)
    $auth = $Runtime.Auth[$Environment]
    if ($auth.Token -and $auth.ExpiresUtc -gt [datetime]::UtcNow) { return $auth.Token }
    if (-not $auth.ClientId -or -not $auth.ClientSecret) {
        throw "$Environment access token expired; supply environment automation credentials for proactive refresh. The request was not sent."
    }
    $form = [System.Collections.Generic.Dictionary[string,string]]::new()
    $form.Add('client_id', $auth.ClientId)
    $form.Add('client_secret', $auth.ClientSecret)
    $form.Add('grant_type', 'client_credentials')
    $form.Add('audience', 'https://api.sitecorecloud.io')
    $content = [System.Net.Http.FormUrlEncodedContent]::new($form)
    $reply = Invoke-TransferHttp -Runtime $Runtime -Environment $Environment -Method POST `
        -Url 'https://auth.sitecorecloud.io/oauth/token' -Content $content -ExpectedStatus 200 -Sensitive -CancellationToken $CancellationToken
    try {
        $tokenData = $reply.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
        if (-not $tokenData.access_token -or -not $tokenData.expires_in -or [double]$tokenData.expires_in -le 60) { throw 'Invalid token response.' }
        $auth.Token = [string]$tokenData.access_token
        $auth.ExpiresUtc = [datetime]::UtcNow.AddSeconds([double]$tokenData.expires_in - 60)
        $Runtime.Secrets.Add($auth.Token)
        Write-TransferLog "$Environment authentication refreshed; expiration $($auth.ExpiresUtc.ToString('o'))." $Runtime
        return $auth.Token
    }
    catch { throw "$Environment authentication returned an invalid credential response (details suppressed)." }
    finally { $reply.Dispose() }
}

function Get-TransferHttpErrorDetail {
    [CmdletBinding()]
    param([System.Net.Http.HttpResponseMessage]$Response, $Runtime)
    $type = $Response.Content.Headers.ContentType
    if (-not $type -or $type.MediaType -notmatch '^(application/(?:[\w.-]+\+)?json|text/(plain|html))$') {
        return '' # Never interpret a binary or untyped error response as text.
    }
    try {
        # Non-streaming responses are already buffered by HttpClient. Bound what can enter logs/journals.
        $raw = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $safe = Protect-TransferText $raw $Runtime
        $diagnostic = $safe.Substring(0, [math]::Min($safe.Length, 4096))
        if ($safe.Length -gt 4096) { $diagnostic += ' [truncated]' }
        Write-Verbose "HTTP error body: $diagnostic"
        $summary = ''
        if ($type.MediaType -match 'json$') {
            # Do not parse arbitrarily large bodies solely for diagnostics.
            if ($raw.Length -le 65536) {
                try {
                    $errorData = $raw | ConvertFrom-Json -AsHashtable
                    if ($errorData -is [System.Collections.IDictionary]) {
                        foreach ($name in @('Error', 'Message', 'title', 'detail')) {
                            if ($errorData[$name] -is [string] -and $errorData[$name]) {
                                $summary = Protect-TransferText $errorData[$name] $Runtime
                                break
                            }
                        }
                    }
                }
                catch { $summary = '' }
            }
        }
        elseif ($type.MediaType -eq 'text/plain') { $summary = $safe }
        if ($summary) { return $summary.Substring(0, [math]::Min($summary.Length, 1024)) }
        return ''
    }
    catch {
        Write-Verbose 'Could not inspect the error body; preserving the HTTP failure.'
        return ''
    }
}

function Invoke-TransferHttp {
    [CmdletBinding()]
    param(
        $Runtime, [ValidateSet('Source', 'Destination')][string]$Environment,
        [string]$Method, [string]$Url, [System.Net.Http.HttpContent]$Content,
        [int[]]$ExpectedStatus = @(200), [switch]$Streaming, [switch]$Sensitive, [double]$TimeoutSeconds = 0,
        [System.Threading.CancellationToken]$CancellationToken = [System.Threading.CancellationToken]::None
    )
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), [uri]$Url)
    $response = $null
    $cancellation = $null
    $timer = [diagnostics.stopwatch]::StartNew()
    try {
        $request.Content = $Content
        # Authentication and the API request share one deadline; refresh must not restart the clock.
        $limit = if ($TimeoutSeconds -gt 0) { [math]::Min($TimeoutSeconds, $Runtime.RequestTimeoutSeconds) } else { $Runtime.RequestTimeoutSeconds }
        $cancellation = [System.Threading.CancellationTokenSource]::CreateLinkedTokenSource($CancellationToken, [System.Threading.CancellationToken]::None)
        $cancellation.CancelAfter([timespan]::FromSeconds($limit))
        $cancellation.Token.ThrowIfCancellationRequested()
        if (-not $Sensitive) {
            $origin = $Runtime[$Environment]
            if (-not $Url.StartsWith($origin + '/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Request origin does not match its authentication environment.' }
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', (Get-TransferToken $Runtime $Environment $cancellation.Token))
        }
        $request.Headers.Accept.ParseAdd('application/json')
        Write-TransferLog "$Environment $Method $Url" $Runtime
        Write-Verbose (Protect-TransferText ("Request headers: " + $request.Headers.ToString()) $Runtime)
        if (-not $Sensitive -and $Content) {
            Write-Verbose (Protect-TransferText ("Request content headers: " + $Content.Headers.ToString()) $Runtime)
        }
        if (-not $Sensitive -and $Content -is [System.Net.Http.StringContent]) {
            Write-Verbose (Protect-TransferText ($Content.ReadAsStringAsync().GetAwaiter().GetResult()) $Runtime)
        }
        $option = if ($Streaming) { [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead } else { [System.Net.Http.HttpCompletionOption]::ResponseContentRead }
        $cancellation.Token.ThrowIfCancellationRequested()
        $response = $Runtime.Client.SendAsync($request, $option, $cancellation.Token).GetAwaiter().GetResult()
        $code = [int]$response.StatusCode
        Write-TransferLog ("$Environment $Method => HTTP $code ({0:N2}s)" -f $timer.Elapsed.TotalSeconds) $Runtime
        if (-not $Sensitive) {
            Write-Verbose (Protect-TransferText ("Response headers: " + $response.Headers.ToString() + $response.Content.Headers.ToString()) $Runtime)
        }
        if ($code -notin $ExpectedStatus) {
            $detail = ''
            if (-not $Sensitive -and -not $Streaming) {
                $detail = Get-TransferHttpErrorDetail $response $Runtime
            }
            if ($detail) { throw "HTTP $code for $Environment $Method $Url; server detail: $detail; no automatic replay was attempted." }
            throw "HTTP $code for $Environment $Method $Url; no automatic replay was attempted."
        }
        return $response
    }
    catch {
        if ($response) { $response.Dispose() }
        $message = if ($Sensitive) { 'Authentication request failed (credential details suppressed).' } else { 'Request failed: ' + $_.Exception.Message }
        throw (Protect-TransferText $message $Runtime)
    }
    finally {
        if ($cancellation) { $cancellation.Dispose() }
        $request.Dispose()
    }
}

function Invoke-TransferJson {
    [CmdletBinding()]
    param($Runtime, [string]$Environment, [string]$Method, [string]$Path, $Body,
        [int[]]$ExpectedStatus = @(200), [double]$TimeoutSeconds = 0)
    $content = $null
    if ($null -ne $Body) { $content = [System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 20 -Compress), [Text.Encoding]::UTF8, 'application/json') }
    $response = Invoke-TransferHttp -Runtime $Runtime -Environment $Environment -Method $Method `
        -Url ($Runtime[$Environment] + $Path) -Content $content -ExpectedStatus $ExpectedStatus -TimeoutSeconds $TimeoutSeconds
    try {
        $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        Write-Verbose (Protect-TransferText $raw $Runtime)
        $data = if ($raw) { $raw | ConvertFrom-Json -AsHashtable } else { $null }
        return @{ Data = $data; Location = [string]$response.Headers.Location; StatusCode = [int]$response.StatusCode }
    }
    finally { $response.Dispose() }
}

function ConvertTo-SafeJournalValue {
    param([AllowNull()]$Value, $Runtime)
    if ($Value -is [System.Collections.IDictionary]) {
        $snapshot = @{}
        foreach ($key in $Value.Keys) { $snapshot[$key] = ConvertTo-SafeJournalValue $Value[$key] $Runtime }
        return $snapshot
    }
    if ($Value -is [string]) { return (Protect-TransferText $Value $Runtime) }
    if ($Value -is [array]) {
        $snapshot = @(foreach ($element in $Value) { ConvertTo-SafeJournalValue $element $Runtime })
        return ,$snapshot
    }
    return $Value
}

function Save-TransferJournal {
    param($Context, [string]$StatePath, $Runtime)
    $temporary = $StatePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        # Redact string values before encoding, so a numeric-looking secret cannot corrupt JSON numbers.
        # This is a transient serialization snapshot of Context, not a separately maintained state model.
        $json = ConvertTo-SafeJournalValue $Context $Runtime | ConvertTo-Json -Depth 30
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temporary, $StatePath, [System.Management.Automation.Language.NullString]::Value)
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Set-TransferStage {
    param($Context, [string]$Stage, [string]$StatePath, $Runtime)
    $Context.Stage = $Stage
    Save-TransferJournal $Context $StatePath $Runtime
    Write-TransferLog "Stage: $Stage; source transfer $($Context.SourceTransfer.Id)." $Runtime
}

function Wait-TransferTick {
    param([diagnostics.stopwatch]$Timer, [int]$TimeoutSeconds, [int]$IntervalSeconds, [string]$Operation)
    $remaining = Get-RemainingSeconds $Timer $TimeoutSeconds $Operation
    Start-Sleep -Milliseconds ([int]([math]::Min($IntervalSeconds, $remaining) * 1000))
}

function Get-RemainingSeconds {
    param([diagnostics.stopwatch]$Timer, [int]$TimeoutSeconds, [string]$Operation)
    $remaining = $TimeoutSeconds - $Timer.Elapsed.TotalSeconds
    if ($remaining -le 0) { throw "Timed out after $TimeoutSeconds seconds waiting for $Operation." }
    return $remaining
}

function Wait-SourceExport {
    param($Runtime, $Context, [string]$StatePath, [int]$PollIntervalSeconds, [int]$PollTimeoutSeconds)
    $timer = [diagnostics.stopwatch]::StartNew()
    do {
        $remaining = Get-RemainingSeconds $timer $PollTimeoutSeconds 'source export'
        $result = (Invoke-TransferJson $Runtime Source GET "$script:ContentBase/$($Context.SourceTransfer.Id)/status" -TimeoutSeconds $remaining).Data
        $state = [string]$result.State
        if ($state -cnotin @('Running', 'Completed', 'Failed', 'NotFound')) { throw 'Source status has a missing or unsupported State.' }
        $Context.SourceTransfer.ExportState = $state
        Save-TransferJournal $Context $StatePath $Runtime
        Write-TransferLog "Export State=$state" $Runtime
        if ($state -in @('Failed', 'NotFound')) { throw "Source export State=$state. A new source transfer is required; import retries do not apply." }
        if ($state -eq 'Completed') {
            if ($result.ChunkSetsMetadata -isnot [array] -or $result.ChunkSetsMetadata.Count -eq 0) { throw 'Completed export has no ChunkSetsMetadata array.' }
            foreach ($metadata in $result.ChunkSetsMetadata) {
                $id = [guid]::Empty
                if (-not [guid]::TryParse([string]$metadata.ChunkSetId, [ref]$id) -or
                    ($metadata.ChunkCount -isnot [long] -and $metadata.ChunkCount -isnot [int]) -or
                    $metadata.ChunkCount -lt 1 -or $metadata.ChunkCount -gt [int]::MaxValue) {
                    throw 'Export contains an invalid ChunkSetId or ChunkCount.'
                }
                if (@($Context.ChunkSets | Where-Object Id -eq $id.ToString()).Count) { throw 'Export contains duplicate chunk set IDs.' }
                $Context.ChunkSets += @{
                    Id = $id.ToString(); ChunkCount = $metadata.ChunkCount; CompletedChunks = @(); UploadAttempt = $null
                    CompletionState = 'Planned'; BlobName = $null; BlobState = $null; BlobDeleted = $false
                    Import = @{ Id = $null; LocationKey = $null; LocationKind = $null; KnownIds = @(); SourceName = $null; State = 'NotStarted'; Status = 'NotStarted'; Retries = 0; ValidationErrors = @() }
                }
            }
            Save-TransferJournal $Context $StatePath $Runtime
            return
        }
        Wait-TransferTick $timer $PollTimeoutSeconds $PollIntervalSeconds 'source export'
    } while ($true)
}

function Copy-TransferChunk {
    [CmdletBinding()]
    param($Runtime, $Context, $ChunkSet, [int]$ChunkId, [string]$StatePath)
    $path = "$script:ContentBase/$($Context.SourceTransfer.Id)/chunksets/$($ChunkSet.Id)/chunks/$ChunkId"
    $ChunkSet.UploadAttempt = @{ ChunkId = $ChunkId; State = 'PossiblyCreated' }
    Save-TransferJournal $Context $StatePath $Runtime
    $download = Invoke-TransferHttp $Runtime Source GET ($Runtime.Source + $path) -Streaming
    $stream = $null
    try {
        $disposition = $download.Content.Headers.ContentDisposition
        if (-not $disposition) { throw 'Chunk response has no Content-Disposition header.' }
        $media = @($disposition.Parameters | Where-Object Name -IEQ 'IsMedia')
        $isMedia = $false
        if ($media.Count -ne 1 -or -not [bool]::TryParse($media[0].Value.Trim('"'), [ref]$isMedia)) {
            throw 'Chunk Content-Disposition must contain one boolean IsMedia parameter.'
        }
        $stream = $download.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $content = [System.Net.Http.StreamContent]::new($stream)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $length = $download.Content.Headers.ContentLength
        if ($null -ne $length) { $content.Headers.ContentLength = $length }
        $ChunkSet.UploadAttempt.IsMedia = $isMedia
        $ChunkSet.UploadAttempt.ContentLength = $length
        $ChunkSet.UploadAttempt.LengthMode = if ($null -eq $length) { 'UnknownLengthStream' } else { 'ContentLength' }
        Save-TransferJournal $Context $StatePath $Runtime
        $lengthLabel = if ($null -eq $length) { 'unknown (HttpClient selects streaming framing)' } else { "$length bytes" }
        Write-TransferLog "Uploading chunk $ChunkId of set $($ChunkSet.Id): IsMedia=$isMedia; Content-Length=$lengthLabel; Content-Type=application/octet-stream." $Runtime
        $upload = Invoke-TransferHttp $Runtime Destination PUT ($Runtime.Destination + $path + '?isMedia=' + $isMedia.ToString().ToLowerInvariant()) `
            -Content $content -ExpectedStatus 201
        $upload.Dispose()
        $ChunkSet.CompletedChunks += $ChunkId
        $ChunkSet.UploadAttempt.State = 'Uploaded'
        Save-TransferJournal $Context $StatePath $Runtime
        $size = if ($null -ne $length) { "$length bytes" } else { 'streamed bytes; length not supplied' }
        Write-TransferLog "Chunk set $($ChunkSet.Id): chunk $ChunkId uploaded ($($ChunkSet.CompletedChunks.Count)/$($ChunkSet.ChunkCount)); IsMedia=$isMedia; $size." $Runtime
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $download.Dispose()
    }
}

function Get-ImportLocation {
    param([string]$Location, $Runtime)
    if (-not $Location) { throw 'Import was accepted without a Location header; consumption state is ambiguous.' }
    $parsed = [uri]::new([uri]($Runtime.Destination + '/'), $Location)
    if ($parsed.GetLeftPart([UriPartial]::Authority) -ne $Runtime.Destination -or $parsed.Query -or $parsed.Fragment) {
        throw 'Import Location must reference the destination origin without query or fragment.'
    }
    $key = [uri]::UnescapeDataString(($parsed.AbsolutePath.TrimEnd('/') -split '/')[-1])
    if (-not $key -or $key -match '[/\\\r\n]' -or $key -in @('.', '..')) { throw 'Import Location has an invalid final segment.' }
    $kind = if ($parsed.AbsolutePath.StartsWith("$script:ItemBase/sources/blobs/", [StringComparison]::OrdinalIgnoreCase)) { 'Blob' } else { 'Transfer' }
    return @{ Key = $key; Kind = $kind }
}

function Wait-BlobReady {
    param($Runtime, $ChunkSet, $Context, [string]$StatePath, [int]$PollIntervalSeconds, [int]$PollTimeoutSeconds)
    $timer = [diagnostics.stopwatch]::StartNew()
    do {
        $remaining = Get-RemainingSeconds $timer $PollTimeoutSeconds 'blob availability'
        $blob = (Invoke-TransferJson $Runtime Destination GET "$script:ItemBase/sources/blobs/$([uri]::EscapeDataString($ChunkSet.BlobName))" -TimeoutSeconds $remaining).Data
        $ChunkSet.BlobState = [string]$blob.BlobState
        Save-TransferJournal $Context $StatePath $Runtime
        Write-TransferLog "Blob $($ChunkSet.BlobName): BlobState=$($ChunkSet.BlobState)" $Runtime
        if ($ChunkSet.BlobState -ceq 'Uploaded') { return }
        if ($ChunkSet.BlobState -cnotin @('Unknown', 'Uploading', 'Initializing', 'Queued')) { throw 'Blob is not available for a new import; expected Uploaded.' }
        Wait-TransferTick $timer $PollTimeoutSeconds $PollIntervalSeconds 'blob availability'
    } while ($true)
}

function Resolve-ImportTransferId {
    param($Runtime, $ChunkSet, [string]$Database, [diagnostics.stopwatch]$Timer, [int]$TimeoutSeconds, [int]$IntervalSeconds,
        [switch]$AfterRetry, $Context, [string]$StatePath)
    # The blob Location identifies the source. Its SourceName identifies the consumed import job.
    $blobPath = "$script:ItemBase/sources/blobs/$([uri]::EscapeDataString($ChunkSet.BlobName))"
    do {
        $remaining = Get-RemainingSeconds $Timer $TimeoutSeconds 'destination import discovery'
        $blob = (Invoke-TransferJson $Runtime Destination GET $blobPath -TimeoutSeconds $remaining).Data
        $ChunkSet.BlobState = [string]$blob.BlobState
        if ($Context -and $StatePath) { Save-TransferJournal $Context $StatePath $Runtime }
        if ($blob['Name'] -and $blob['Name'] -ne $ChunkSet.BlobName) { throw 'Import discovery returned a different blob.' }
        $id = [string]$blob['SourceName']
        if ($id -and $id -ne $ChunkSet.BlobName) {
            if ([string]::IsNullOrWhiteSpace($id) -or $id -match '[/\\\r\n]' -or $id -in @('.', '..')) { throw 'Blob SourceName is not a valid import ID.' }
            $ready = $true
            if ($AfterRetry -and $id -in $ChunkSet.Import.KnownIds) {
                # Requeue may reuse the ID. Do not mistake its previous Failed status for a new attempt.
                $remaining = Get-RemainingSeconds $Timer $TimeoutSeconds 'destination import discovery'
                $reply = Invoke-TransferJson $Runtime Destination GET "$script:ItemBase/transfers/$([uri]::EscapeDataString($id))" -TimeoutSeconds $remaining -ExpectedStatus @(200, 404)
                $ready = $reply.StatusCode -eq 200 -and $reply.Data['TransferState'] -and $reply.Data['TransferState'] -ne 'Failed'
                if ($ready -and (($reply.Data['SourceName'] -and $reply.Data['SourceName'] -ne $ChunkSet.BlobName) -or
                    ($reply.Data['DatabaseName'] -and $reply.Data['DatabaseName'] -ne $Database))) { throw 'Requeued import refers to a different source or database.' }
            }
            if ($ready) {
                Write-TransferLog "Resolved destination import $id from blob $($ChunkSet.BlobName)." $Runtime
                return $id
            }
        }
        elseif (-not $AfterRetry -and $ChunkSet.BlobState -in @('Error', 'Discarded', 'TransferredWithErrors')) {
            throw "Blob failed before its import ID became available: BlobState=$($ChunkSet.BlobState)."
        }
        Write-TransferLog "Waiting for blob $($ChunkSet.BlobName) to identify its import: BlobState=$($ChunkSet.BlobState)." $Runtime
        Wait-TransferTick $Timer $TimeoutSeconds $IntervalSeconds 'destination import discovery'
    } while ($true)
}

function Update-ImportStatus {
    param($Runtime, $Context, $ChunkSet, $Details, [string]$StatePath)
    $import = $ChunkSet.Import
    $state = if ($Details -is [System.Collections.IDictionary]) { [string]$Details['TransferState'] } else { '' }
    if ($state -cnotin @('Unknown', 'InProgress', 'Finished', 'Failed', 'Queued', 'Discarded', 'TransferredWithErrors')) {
        $import.State = 'Unknown'
        Save-TransferJournal $Context $StatePath $Runtime
        throw 'Import status has a missing or unsupported TransferState.'
    }
    if (($Details.SourceName -and $Details.SourceName -ne $ChunkSet.BlobName) -or
        ($Details.DatabaseName -and $Details.DatabaseName -ne $Context.Configuration.Database)) {
        $import.State = 'Unknown'
        Save-TransferJournal $Context $StatePath $Runtime
        throw 'Import status refers to a different source or database; consumption state is ambiguous.'
    }
    $import.State = $state
    if ($Details.Id) {
        $import.Id = [string]$Details.Id
        if ($import.Id -notin $import.KnownIds) { $import.KnownIds += $import.Id }
    }
    $import.ValidationErrors = @($Details.ValidationErrors | Where-Object { $_ } | ForEach-Object { Protect-TransferText ([string]$_) $Runtime })
    Save-TransferJournal $Context $StatePath $Runtime
}

function Invoke-FailedImportRetry {
    param($Runtime, $Context, $ChunkSet, [string]$StatePath, [diagnostics.stopwatch]$Timer,
        [int]$PollIntervalSeconds, [int]$PollTimeoutSeconds, [int]$RetryCount)
    $import = $ChunkSet.Import
    if ($import.State -ne 'Failed' -or $import.Retries -ge $RetryCount -or $ChunkSet.BlobState -eq 'TransferredWithErrors') { return $false }
    $import.Retries++
    $import.Status = 'PossiblyRequeued'
    $import.State = 'Unknown' # Response loss after requeue must never allow deletion.
    Save-TransferJournal $Context $StatePath $Runtime
    $database = [uri]::EscapeDataString($Context.Configuration.Database)
    $retry = Invoke-TransferJson $Runtime Destination PUT "$script:ItemBase/transfers/databases/$database/sources/$([uri]::EscapeDataString($import.SourceName))"
    if (-not $retry.Data -or $retry.Data.SourceName -ne $import.SourceName -or $retry.Data.DatabaseName -ne $Context.Configuration.Database) { throw 'Retry response did not identify the expected source and database.' }
    $Timer.Restart()
    $import.Id = Resolve-ImportTransferId $Runtime $ChunkSet $Context.Configuration.Database $Timer $PollTimeoutSeconds $PollIntervalSeconds -AfterRetry -Context $Context -StatePath $StatePath
    if ($import.Id -notin $import.KnownIds) { $import.KnownIds += $import.Id }
    $import.Status = 'InProgress'
    Save-TransferJournal $Context $StatePath $Runtime
    return $true
}

function Invoke-BlobImport {
    [CmdletBinding()]
    param($Runtime, $Context, $ChunkSet, [string]$StatePath, [int]$PollIntervalSeconds, [int]$PollTimeoutSeconds, [int]$RetryCount)
    Wait-BlobReady $Runtime $ChunkSet $Context $StatePath $PollIntervalSeconds $PollTimeoutSeconds
    $database = [uri]::EscapeDataString($Context.Configuration.Database)
    $blobPath = "$script:ItemBase/sources/blobs/$([uri]::EscapeDataString($ChunkSet.BlobName))"
    $import = $ChunkSet.Import
    $import.Status = 'PossiblyStarted'
    $import.State = 'Unknown'
    Save-TransferJournal $Context $StatePath $Runtime
    $start = Invoke-TransferJson $Runtime Destination POST "$script:ItemBase/transfers/databases/$database/sources?blobName=$([uri]::EscapeDataString($ChunkSet.BlobName))" -ExpectedStatus 202
    $location = Get-ImportLocation $start.Location $Runtime
    $import.LocationKey = $location.Key
    $import.LocationKind = $location.Kind
    $import.SourceName = $ChunkSet.BlobName
    $import.Status = 'Discovering'
    Save-TransferJournal $Context $StatePath $Runtime
    $timer = [diagnostics.stopwatch]::StartNew()
    if ($location.Kind -eq 'Blob' -or $location.Key -eq $ChunkSet.BlobName) {
        if ($location.Key -ne $ChunkSet.BlobName) { throw 'Import Location refers to a different blob; consumption state is ambiguous.' }
        $import.Id = Resolve-ImportTransferId $Runtime $ChunkSet $Context.Configuration.Database $timer $PollTimeoutSeconds $PollIntervalSeconds -Context $Context -StatePath $StatePath
    }
    else { $import.Id = $location.Key }
    $import.KnownIds += $import.Id
    $import.Status = 'InProgress'
    Save-TransferJournal $Context $StatePath $Runtime
    do {
        $remaining = Get-RemainingSeconds $timer $PollTimeoutSeconds 'destination import'
        $statusReply = Invoke-TransferJson $Runtime Destination GET "$script:ItemBase/transfers/$([uri]::EscapeDataString($import.Id))" -TimeoutSeconds $remaining -ExpectedStatus @(200, 404)
        if ($statusReply.StatusCode -eq 404) {
            $import.State = 'Unknown'
            Save-TransferJournal $Context $StatePath $Runtime
            Write-TransferLog "Import $($import.Id) status is not yet visible; polling without restarting consumption." $Runtime
            Wait-TransferTick $timer $PollTimeoutSeconds $PollIntervalSeconds 'destination import'
            continue
        }
        Update-ImportStatus $Runtime $Context $ChunkSet $statusReply.Data $StatePath
        $remaining = Get-RemainingSeconds $timer $PollTimeoutSeconds 'destination import'
        $blob = (Invoke-TransferJson $Runtime Destination GET $blobPath -TimeoutSeconds $remaining).Data
        $ChunkSet.BlobState = [string]$blob.BlobState
        Save-TransferJournal $Context $StatePath $Runtime
        Write-TransferLog "Import $($import.Id), source $($ChunkSet.BlobName): TransferState=$($import.State); BlobState=$($ChunkSet.BlobState); validation errors=$($import.ValidationErrors.Count)." $Runtime
        foreach ($validationError in $import.ValidationErrors) { Write-Warning $validationError }
        if (Invoke-FailedImportRetry $Runtime $Context $ChunkSet $StatePath $timer $PollIntervalSeconds $PollTimeoutSeconds $RetryCount) { continue }
        if ($import.State -in @('Failed', 'Discarded', 'TransferredWithErrors') -or $ChunkSet.BlobState -in @('Error', 'TransferredWithErrors', 'Discarded')) {
            $import.Status = 'Failed'
            Save-TransferJournal $Context $StatePath $Runtime
            throw "Destination import failed or partially succeeded: TransferState=$($import.State); BlobState=$($ChunkSet.BlobState)."
        }
        if ($import.State -eq 'Finished') {
            if ($import.ValidationErrors.Count -gt 0) {
                $import.Status = 'Failed'
                Save-TransferJournal $Context $StatePath $Runtime
                throw 'Destination import Finished with validation errors.'
            }
            if ($ChunkSet.BlobState -eq 'Transferred') {
                $import.Status = 'Completed'
                Save-TransferJournal $Context $StatePath $Runtime
                return
            }
        }
        Wait-TransferTick $timer $PollTimeoutSeconds $PollIntervalSeconds 'destination import'
    } while ($true)
}

function Test-BlobCleanupSafe {
    param($ChunkSet)
    return ($ChunkSet.Import.State -eq 'Finished' -and $ChunkSet.BlobState -in @('Transferred', 'TransferredWithErrors'))
}

function Invoke-TransferCleanup {
    [CmdletBinding()]
    param($Runtime, $Context, [string]$StatePath)
    foreach ($set in $Context.ChunkSets) {
        if ($set.BlobName -and -not $set.BlobDeleted) {
            if (-not (Test-BlobCleanupSafe $set)) {
                Write-Warning (Protect-TransferText "Preserving blob $($set.BlobName): import state $($set.Import.State), blob state $($set.BlobState); manual investigation/cleanup required." $Runtime)
                $Context.Cleanup += @{ Resource = $set.BlobName; Outcome = 'Preserved'; AtUtc = [datetime]::UtcNow.ToString('o') }
                continue
            }
            $attempt = @{ Resource = $set.BlobName; Outcome = 'Attempting'; AtUtc = [datetime]::UtcNow.ToString('o') }
            $Context.Cleanup += $attempt
            try {
                Save-TransferJournal $Context $StatePath $Runtime
                Invoke-TransferJson $Runtime Destination DELETE "$script:ItemBase/sources/blobs/$([uri]::EscapeDataString($set.BlobName))" -ExpectedStatus @(204, 404) | Out-Null
                $set.BlobDeleted = $true
                $attempt.Outcome = 'DeletedOrAbsent'
            }
            catch { $attempt.Outcome = 'Failed'; $attempt.Error = Protect-TransferText $_.Exception.Message $Runtime; Write-Warning $attempt.Error }
        }
        elseif ($set.CompletionState -ne 'Completed' -and $set.UploadAttempt) {
            Write-Warning "Incomplete destination chunk set $($set.Id), transfer $($Context.SourceTransfer.Id): no documented deletion endpoint. Completion may be ambiguous if its response was lost."
            $Context.Cleanup += @{ Resource = $set.Id; Outcome = 'NoDocumentedPartialChunkCleanup'; AtUtc = [datetime]::UtcNow.ToString('o') }
        }
    }
    if ($Context.SourceTransfer.ResourceState -in @('PossiblyCreated', 'Created')) {
        $attempt = @{ Resource = $Context.SourceTransfer.Id; Outcome = 'Attempting'; AtUtc = [datetime]::UtcNow.ToString('o') }
        $Context.Cleanup += $attempt
        try {
            Save-TransferJournal $Context $StatePath $Runtime
            Invoke-TransferJson $Runtime Source DELETE "$script:ContentBase/$($Context.SourceTransfer.Id)" -ExpectedStatus @(202, 404) | Out-Null
            $Context.SourceTransfer.ResourceState = 'Deleted'
            $attempt.Outcome = 'DeletedOrAbsent'
        }
        catch { $attempt.Outcome = 'Failed'; $attempt.Error = Protect-TransferText $_.Exception.Message $Runtime; Write-Warning $attempt.Error }
    }
    Save-TransferJournal $Context $StatePath $Runtime
}

function Invoke-SitecoreContentTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration, [Parameter(Mandatory)]$Runtime,
        [Parameter(Mandatory)][string]$ConfigPath, [string]$StatePath,
        [ValidateRange(1, 3600)][int]$PollIntervalSeconds = 5,
        [ValidateRange(1, 86400)][int]$PollTimeoutSeconds = 1800,
        [ValidateRange(0, 100)][int]$RetryCount = 0, [bool]$AutoCleanup = $true
    )
    $runId = [guid]::NewGuid().ToString()
    if (-not $StatePath) { $StatePath = Join-Path ([IO.Path]::GetTempPath()) "sitecore-transfer/$runId.json" }
    $StatePath = [IO.Path]::GetFullPath($StatePath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($StatePath)) | Out-Null
    $reservation = [IO.File]::Open($StatePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $reservation.Dispose()
    $context = @{
        RunId = $runId; StartedUtc = [datetime]::UtcNow.ToString('o'); EndedUtc = $null
        Stage = 'Initialized'; Status = 'Running'; Source = $Runtime.Source; Destination = $Runtime.Destination
        ConfigPath = $ConfigPath; Configuration = $Configuration
        SourceTransfer = @{ Id = [guid]::NewGuid().ToString(); ResourceState = 'Planned'; ExportState = $null }
        Request = $null; ChunkSets = @(); TemporaryFiles = @(); Cleanup = @(); Error = $null
    }
    $context.Request = @{ TransferId = $context.SourceTransfer.Id; Configuration = $Configuration }
    Save-TransferJournal $context $StatePath $Runtime
    Write-TransferLog "Config $ConfigPath; source $($Runtime.Source); destination $($Runtime.Destination); journal $StatePath; run $runId." $Runtime
    foreach ($tree in $Configuration.DataTrees) { Write-TransferLog "$($tree.ItemPath): scope=$($tree.Scope); strategy=$($tree.MergeStrategy)." $Runtime }
    try {
        Set-TransferStage $context 'CreateSourceTransfer' $StatePath $Runtime
        $context.SourceTransfer.ResourceState = 'PossiblyCreated'
        Save-TransferJournal $context $StatePath $Runtime
        Invoke-TransferJson $Runtime Source POST $script:ContentBase -Body $context.Request -ExpectedStatus 202 | Out-Null
        $context.SourceTransfer.ResourceState = 'Created'
        Set-TransferStage $context 'WaitForExport' $StatePath $Runtime
        Wait-SourceExport $Runtime $context $StatePath $PollIntervalSeconds $PollTimeoutSeconds
        foreach ($set in $context.ChunkSets) {
            Set-TransferStage $context "CopyChunkSet:$($set.Id)" $StatePath $Runtime
            for ($chunk = 0; $chunk -lt $set.ChunkCount; $chunk++) { Copy-TransferChunk $Runtime $context $set $chunk $StatePath }
            $set.CompletionState = 'PossiblyCompleted'
            Set-TransferStage $context "CompleteChunkSet:$($set.Id)" $StatePath $Runtime
            $completed = Invoke-TransferJson $Runtime Destination POST "$script:ContentBase/$($context.SourceTransfer.Id)/chunksets/$($set.Id)/complete"
            $name = [string]$completed.Data.ContentTransferFileName
            if (-not $name -or $name -notmatch '(?i)\.raif$' -or $name -match '[/\\\r\n]' -or @($context.ChunkSets | Where-Object BlobName -eq $name).Count) {
                throw 'Chunk completion returned a missing, invalid or duplicate ContentTransferFileName; inspect the journal for the possibly completed set.'
            }
            $set.BlobName = $name
            $set.CompletionState = 'Completed'
            Save-TransferJournal $context $StatePath $Runtime
            Write-TransferLog "Chunk set $($set.Id) completed: $name." $Runtime
            Set-TransferStage $context "ImportBlob:$name" $StatePath $Runtime
            Invoke-BlobImport $Runtime $context $set $StatePath $PollIntervalSeconds $PollTimeoutSeconds $RetryCount
        }
        Set-TransferStage $context 'Cleanup' $StatePath $Runtime
        Invoke-TransferCleanup $Runtime $context $StatePath
        if (@($context.Cleanup | Where-Object Outcome -eq 'Failed').Count) { throw 'Content imported, but mandatory cleanup failed. Review the journal; cleanup is not rollback.' }
        $context.Status = 'Succeeded'
        $context.Stage = 'Completed'
        Write-TransferLog 'Transfer succeeded. Content is not automatically published.' $Runtime
    }
    catch {
        $original = Protect-TransferText $_.Exception.Message $Runtime
        $context.Status = 'Failed'
        $context.Error = @{ Stage = $context.Stage; Message = $original; AtUtc = [datetime]::UtcNow.ToString('o') }
        if ($AutoCleanup -and $context.Stage -ne 'Cleanup') {
            try { Invoke-TransferCleanup $Runtime $context $StatePath }
            catch { Write-Warning (Protect-TransferText ("Cleanup/journal failure: " + $_.Exception.Message) $Runtime) }
        }
        elseif (-not $AutoCleanup) { Write-Warning "Failure cleanup disabled. Resources are preserved; inspect journal $StatePath." }
        throw "Transfer failed: $original Journal: $StatePath. Cleanup does not roll back imported items."
    }
    finally {
        $context.EndedUtc = [datetime]::UtcNow.ToString('o')
        try { Save-TransferJournal $context $StatePath $Runtime }
        catch {
            if ($context.Status -eq 'Succeeded') { throw 'Transfer completed, but the final execution journal could not be persisted.' }
            Write-Warning 'Final journal write failed; the original transfer failure is preserved.'
        }
        Write-TransferLog "Outcome=$($context.Status); journal=$StatePath" $Runtime
    }
    return $context
}

Export-ModuleMember -Function Read-TransferConfiguration, New-TransferRuntime, Invoke-SitecoreContentTransfer, Protect-TransferText
