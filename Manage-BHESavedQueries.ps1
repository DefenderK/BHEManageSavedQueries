#Requires -Version 5.1
<#
.SYNOPSIS
Preview, back up, delete, or import BloodHound saved queries.
.DESCRIPTION
Omit operation options for the startup menu; .env in the current folder loads
automatically unless EnvFile is supplied. With OwnerUserId, preview
is the default. -Delete requires -BackupPath and supports -WhatIf/-Confirm.
Authenticate with an administrator API token ID/key, or an existing bearer JWT.
OwnerUserId is the BloodHound application user's UUID, not an AD object ID.
Use -EnvFile for literal BHE_URL/BHE_TOKEN_ID/BHE_TOKEN_KEY settings.
Use -Scope Owned for the authenticated user's queries, including private queries.
-BackupOnly saves queries without deleting. -ImportPath imports a tool backup
as the authenticated user, creating new private queries with new IDs.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [uri]$BaseUrl,
    [string]$EnvFile,
    [guid]$OwnerUserId,
    [ValidateSet('Public','Owned')][string]$Scope = 'Public',
    [switch]$BackupOnly,
    [string]$ImportPath,
    [string]$ResultsPath,
    [string]$TokenId = $env:BHE_TOKEN_ID,
    [string]$TokenKey = $env:BHE_TOKEN_KEY,
    [string]$BearerToken = $env:BHE_BEARER_TOKEN,
    [switch]$Delete,
    [string]$BackupPath,
    [ValidateRange(1, 1000)][int]$PageSize = 100,
    [ValidateRange(1, 100000)][int]$MaxQueries = 10000,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host @'

     ____  _   _ _____
    | __ )| | | | ____|
    |  _ \| |_| |  _|
    | |_) |  _  | |___
    |____/|_| |_|_____|

    +----------------------------------+
    |      BHE-ManageSavedQueries       |
    +----------------------------------+

'@ -ForegroundColor Cyan
function Invoke-BHESavedQueryOperation {
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [uri]$BaseUrl,
    [string]$EnvFile,
    [guid]$OwnerUserId,
    [ValidateSet('Public','Owned')][string]$Scope = 'Public',
    [switch]$BackupOnly,
    [string]$ImportPath,
    [string]$ResultsPath,
    [string]$TokenId = $env:BHE_TOKEN_ID,
    [string]$TokenKey = $env:BHE_TOKEN_KEY,
    [string]$BearerToken = $env:BHE_BEARER_TOKEN,
    [switch]$Delete,
    [string]$BackupPath,
    [ValidateRange(1, 1000)][int]$PageSize = 100,
    [ValidateRange(1, 100000)][int]$MaxQueries = 10000,
    [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
)

# Navigation is signalled only by our prompts, before any pending mutation.
function Read-ToolPrompt {
    param([string]$Prompt)
    $value = Read-Host ($Prompt + ' | [R]eturn to main menu')
    if ($value.Trim() -ieq 'R') {
        $navigation = New-Object System.OperationCanceledException('Return to main menu')
        $navigation.Data['BHEReturnToMainMenu'] = $true
        throw $navigation
    }
    return $value
}

$showStartupMenu = @('OwnerUserId','Scope','BackupOnly','Delete','ImportPath' | Where-Object { $PSBoundParameters.ContainsKey($_) }).Count -eq 0
$menuAction = ''
if ($showStartupMenu) {
    Write-Host 'BloodHound saved queries'
    Write-Host '1. Manage public queries (select a user, then preview/delete)'
    Write-Host '2. List my owned queries'
    Write-Host '3. Back up my owned queries (including private queries)'
    Write-Host '4. Delete my owned queries (backup first, including private queries)'
    Write-Host '5. Import a backup as the authenticated user'
    while ($true) {
        $menuAction = (Read-Host 'Choose 1-5, or Q/Enter to quit').Trim()
        if ($menuAction -eq '' -or $menuAction -ieq 'Q') { Write-Host 'Cancelled.'; return }
        if ($menuAction -in @('1','2','3','4','5')) { break }
        Write-Host 'Enter 1, 2, 3, 4, 5, or Q.'
    }
    switch ($menuAction) {
        '2' { $Scope='Owned' }
        '3' { $Scope='Owned'; $BackupOnly=$true }
        '4' { $Scope='Owned'; $Delete=$true }
        '5' {
            $ImportPath = Read-ToolPrompt 'Backup JSON file to import (Q or Enter to cancel)'
            if ([string]::IsNullOrWhiteSpace($ImportPath) -or $ImportPath.Trim() -ieq 'Q') { Write-Host 'Cancelled.'; return }
        }
    }
}

# Read configuration as data only: no dot-sourcing, command evaluation, or expansion.
# Automatic discovery is limited to .env in the current working directory.
$loadEnvFile = $PSBoundParameters.ContainsKey('EnvFile')
if (-not $loadEnvFile -and (Test-Path -LiteralPath '.\.env' -PathType Leaf)) {
    $EnvFile='.\.env'
    $loadEnvFile=$true
    Write-Host ("Loading configuration: {0}" -f $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile))
}
$fileSettings = @{}
if ($loadEnvFile) {
    if ([string]::IsNullOrWhiteSpace($EnvFile)) { throw 'EnvFile cannot be empty.' }
    $envPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
    $lines = [IO.File]::ReadAllLines($envPath, [Text.Encoding]::UTF8)
    $lineNumber = 0
    foreach ($line in $lines) {
        $lineNumber++
        $text = $line.Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        if ($text -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            throw "Invalid env file syntax on line $lineNumber. Expected NAME=value."
        }
        $name = $Matches[1].ToUpperInvariant()
        $value = $Matches[2].Trim()
        if ($name -notin @('BHE_URL','BHE_TOKEN_ID','BHE_TOKEN_KEY','BHE_BEARER_TOKEN')) {
            throw "Unsupported setting on env file line $lineNumber."
        }
        if ($fileSettings.ContainsKey($name)) { throw "Duplicate setting on env file line $lineNumber." }
        if ($value.StartsWith('"') -or $value.StartsWith("'")) {
            $quote = $value.Substring(0,1)
            if ($value.Length -lt 2 -or -not $value.EndsWith($quote)) {
                throw "Unclosed quoted value on env file line $lineNumber."
            }
            $value = $value.Substring(1,$value.Length-2)
        }
        $fileSettings[$name] = $value
    }
}
# Precedence per setting: explicit parameter > env file > process environment.
if (-not $PSBoundParameters.ContainsKey('BaseUrl')) {
    $urlValue = if ($fileSettings.ContainsKey('BHE_URL')) { $fileSettings['BHE_URL'] } else { $env:BHE_URL }
    if ([string]::IsNullOrWhiteSpace($urlValue)) { throw 'Set BHE_URL in .env in the current folder, supply -EnvFile/-BaseUrl, or set BHE_URL in the process environment.' }
    $parsedUrl = $null
    if (-not [uri]::TryCreate($urlValue, [UriKind]::Absolute, [ref]$parsedUrl)) {
        throw 'BHE_URL must be an absolute tenant URL (HTTPS, or HTTP on loopback).'
    }
    $BaseUrl = $parsedUrl
}
if (-not $PSBoundParameters.ContainsKey('TokenId') -and $fileSettings.ContainsKey('BHE_TOKEN_ID')) {
    $TokenId = $fileSettings['BHE_TOKEN_ID']
}
if (-not $PSBoundParameters.ContainsKey('TokenKey') -and $fileSettings.ContainsKey('BHE_TOKEN_KEY')) {
    $TokenKey = $fileSettings['BHE_TOKEN_KEY']
}
if (-not $PSBoundParameters.ContainsKey('BearerToken') -and $fileSettings.ContainsKey('BHE_BEARER_TOKEN')) {
    $BearerToken = $fileSettings['BHE_BEARER_TOKEN']
}
if ($null -eq $BaseUrl -or -not $BaseUrl.IsAbsoluteUri -or
    ($BaseUrl.Scheme -ne 'https' -and -not ($BaseUrl.Scheme -eq 'http' -and $BaseUrl.IsLoopback)) -or
    $BaseUrl.AbsolutePath -ne '/' -or
    $BaseUrl.Query -or $BaseUrl.Fragment -or $BaseUrl.UserInfo) {
    throw 'BaseUrl must be a tenant origin using HTTPS, or HTTP on loopback (localhost, 127.0.0.1, or [::1]), with no path, query, fragment, or credentials.'
}
$importing = $PSBoundParameters.ContainsKey('ImportPath') -or $menuAction -eq '5'
if ($importing -and ([string]::IsNullOrWhiteSpace($ImportPath) -or $Delete -or $BackupOnly -or
    $PSBoundParameters.ContainsKey('OwnerUserId') -or $PSBoundParameters.ContainsKey('Scope') -or
    $PSBoundParameters.ContainsKey('BackupPath'))) { throw 'Use ImportPath alone with connection settings, ResultsPath, limits, and confirmation options.' }
if ($BackupOnly -and $Delete) { throw 'Choose BackupOnly or Delete, not both.' }
if (-not $importing -and $PSBoundParameters.ContainsKey('ResultsPath')) { throw 'ResultsPath is only used with ImportPath.' }
$interactive = -not $importing -and $Scope -eq 'Public' -and -not $PSBoundParameters.ContainsKey('OwnerUserId')
if ($PSBoundParameters.ContainsKey('OwnerUserId') -and $OwnerUserId -eq [guid]::Empty) { throw 'OwnerUserId cannot be the empty UUID.' }
if ($interactive -and $Delete) { throw 'Omit -Delete in interactive mode; choose deletion from the menu.' }
$hasBearer = -not [string]::IsNullOrWhiteSpace($BearerToken)
$hasId = -not [string]::IsNullOrWhiteSpace($TokenId)
$hasKey = -not [string]::IsNullOrWhiteSpace($TokenKey)
if (($hasBearer -and ($hasId -or $hasKey)) -or
    (-not $hasBearer -and (-not $hasId -or -not $hasKey))) {
    throw 'Supply either TokenId plus TokenKey, or BearerToken, exclusively.'
}
if ($Delete -and $menuAction -ne '4' -and -not $WhatIfPreference -and [string]::IsNullOrWhiteSpace($BackupPath)) {
    throw '-Delete requires -BackupPath. An existing file will never be overwritten.'
}

function Get-Hmac {
    param([byte[]]$Key, [AllowEmptyCollection()][byte[]]$Data)
    $hmac = New-Object Security.Cryptography.HMACSHA256 -ArgumentList (, $Key)
    try { return ,$hmac.ComputeHash($Data) } finally { $hmac.Dispose() }
}

function Invoke-BHERequest {
    param([ValidateSet('GET','DELETE','POST')][string]$Method, [string]$ApiPath, [string]$JsonBody = '')
    $headers = @{ Accept = 'application/json' }
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($JsonBody)
    if ($hasBearer) { $headers.Authorization = "Bearer $BearerToken" }
    else {
        $utf8 = [Text.Encoding]::UTF8
        $date = [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $operation = Get-Hmac $utf8.GetBytes($TokenKey) $utf8.GetBytes($Method + $ApiPath)
        $hour = Get-Hmac $operation $utf8.GetBytes($date.Substring(0,13))
        $signature = Get-Hmac $hour $bodyBytes
        $headers.Authorization = "bhesignature $TokenId"
        $headers.RequestDate = $date
        $headers.Signature = [Convert]::ToBase64String($signature)
    }
    # Sign and send the same UTF-8 bytes. No automatic mutation retries or redirects.
    $request = @{ UseBasicParsing=$true; Method=$Method; Uri=($BaseUrl.AbsoluteUri.TrimEnd('/') + $ApiPath)
        Headers=$headers; TimeoutSec=$TimeoutSeconds; MaximumRedirection=0 }
    if ($Method -eq 'POST') { $request.Body=$bodyBytes; $request.ContentType='application/json' }
    $response = Invoke-WebRequest @request
    if ($Method -eq 'DELETE') {
        if ([int]$response.StatusCode -ne 204) { throw "Unexpected DELETE status: $($response.StatusCode)" }
        return
    }
    if ($Method -eq 'POST' -and [int]$response.StatusCode -ne 201) { throw "Unexpected import status: $($response.StatusCode)" }
    return ($response.Content | ConvertFrom-Json)
}

function Get-SavedQueries {
    param([ValidateSet('Public','Owned')][string]$QueryScope = $Scope)
    $queries = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $skip = 0
    $total = $null
    do {
        # Some server versions rewrite user_id to user_sq.id in SQL filters.
        # Fetch only public queries, then apply the exact owner filter locally.
        $scopeName = $QueryScope.ToLowerInvariant()
        $page = Invoke-BHERequest GET "/api/v2/saved-queries?scope=$scopeName&sort_by=id&skip=$skip&limit=$PageSize"
        if ($null -eq $page -or $null -eq $page.PSObject.Properties['count'] -or
            $null -eq $page.PSObject.Properties['data'] -or $null -eq $page.data -or
            [string]$page.count -notmatch '^\d+$') { throw 'Unexpected saved-query response; stopping.' }
        if ($null -eq $total) { $total = [long]$page.count }
        if ([long]$page.count -ne $total) { throw 'Query count changed during pagination. Run preview again.' }
        if ($total -gt $MaxQueries) { throw "Found $total $QueryScope queries to scan, exceeding MaxQueries=$MaxQueries. No queries deleted." }
        $items = @($page.data)
        if ($items.Count -eq 0 -and $skip -lt $total) { throw 'Incomplete pagination; stopping.' }
        foreach ($query in $items) {
            if ([string]$query.id -notmatch '^[1-9]\d*$') { throw 'Unexpected query ID; stopping.' }
            if ($seen.ContainsKey([string]$query.id)) { throw 'Duplicate query ID during pagination; stopping.' }
            $seen[[string]$query.id] = $true
            if ($QueryScope -eq 'Owned' -and [string]$query.user_id -ine $OwnerUserId.ToString()) {
                throw 'Owned query response contained a different owner. Stopping.'
            }
            if ([string]$query.user_id -ieq $OwnerUserId.ToString()) { $queries.Add($query) }
        }
        $skip += $items.Count
        if ($skip -gt $total -or $skip -gt $MaxQueries) { throw 'Pagination exceeded expected bounds; stopping.' }
    } while ($skip -lt $total)
    return ,$queries.ToArray()
}

function Get-UserText {
    param($User, [string]$Field)
    $property = $User.PSObject.Properties[$Field]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    $value = $property.Value
    if ($value -is [string]) { return $value }
    # BloodHound nullable strings are returned as {string, valid}.
    if ($null -ne $value.PSObject.Properties['valid'] -and $value.valid -eq $true -and
        $null -ne $value.PSObject.Properties['string']) { return [string]$value.string }
    return ''
}

function Read-MenuNumber {
    param([string]$Prompt, [int]$Maximum)
    while ($true) {
        $answer = (Read-ToolPrompt $Prompt).Trim()
        if ($answer -ieq 'Q' -or $answer -eq '') { return 0 }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Maximum) {
            return $number
        }
        Write-Host "Enter a number from 1 to $Maximum, or Q to cancel."
    }
}

function Select-BHEUser {
    try {
        $response = Invoke-BHERequest GET '/api/v2/bloodhound-users'
    } catch {
        $failure = $_
        $responseProperty = $failure.Exception.PSObject.Properties['Response']
        if ($null -eq $responseProperty -or $null -eq $responseProperty.Value -or
            [int]$responseProperty.Value.StatusCode -ne 403) { throw }
        $requestId = 'not provided'
        if ($null -ne $failure.ErrorDetails) {
            try {
                $details = $failure.ErrorDetails.Message | ConvertFrom-Json
                $parsedId = [guid]::Empty
                if ([guid]::TryParse([string]$details.request_id, [ref]$parsedId)) { $requestId = $parsedId.ToString() }
            } catch { $requestId = 'not provided' }
        }
        $message = @(
            'Access denied (HTTP 403): this account cannot list BloodHound users.'
            'Option 1 needs user-list permission. Use an account with that permission (typically an Administrator).'
            'Alternatively, choose option 2, 3, 4, or 5 to work with the authenticated user''s own queries.'
            'No queries were changed. Returning to the main menu.'
            'Request: GET /api/v2/bloodhound-users'
            ("Request ID: {0}" -f $requestId)
        ) -join [Environment]::NewLine
        $navigation = New-Object System.UnauthorizedAccessException('User-list permission required')
        $navigation.Data['BHEReturnToMainMenu'] = $true
        $navigation.Data['BHEFriendlyError'] = $message
        throw $navigation
    }
    if ($null -eq $response.data -or $null -eq $response.data.PSObject.Properties['users'] -or
        $null -eq $response.data.users) { throw 'Unexpected users response; expected data.users.' }
    $users = @($response.data.users | Sort-Object principal_name, id)
    if ($users.Count -eq 0) { Write-Host 'No BloodHound users were returned.'; return $null }
    $seen = @{}
    for ($index = 0; $index -lt $users.Count; $index++) {
        $user = $users[$index]
        $uuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$user.id, [ref]$uuid) -or $uuid -eq [guid]::Empty -or
            $seen.ContainsKey($uuid.ToString())) { throw 'Invalid or duplicate user UUID; stopping.' }
        $seen[$uuid.ToString()] = $true
        $email = Get-UserText $user 'email_address'
        $name = ((Get-UserText $user 'first_name') + ' ' + (Get-UserText $user 'last_name')).Trim()
        Write-Host ("{0}. {1} | {2} | {3} | UUID: {4}" -f ($index+1), $user.principal_name, $name, $email, $uuid)
    }
    $choice = Read-MenuNumber 'Select a user number (Q or Enter to cancel)' $users.Count
    if ($choice -eq 0) { return $null }
    return $users[$choice-1]
}

function Get-QueryPermissions {
    param([string]$Id)
    try {
        $permissions = Invoke-BHERequest GET "/api/v2/saved-queries/$Id/permissions"
    } catch {
        $failure = $_
        $status = 0
        $responseProperty = $failure.Exception.PSObject.Properties['Response']
        if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
            $status = [int]$responseProperty.Value.StatusCode
        }
        $missingRecord = $false
        if ($status -eq 404 -and $null -ne $failure.ErrorDetails) {
            try {
                $details = $failure.ErrorDetails.Message | ConvertFrom-Json
                foreach ($errorItem in @($details.errors)) {
                    if ($errorItem.message -ceq 'no query permissions exist for saved query') { $missingRecord = $true }
                }
            } catch { $missingRecord = $false }
        }
        if ($Scope -ne 'Owned' -or -not $missingRecord) { throw $failure }
        # The server also uses this 404 for inaccessible permissions. Never infer
        # ownership from the error alone: confirm the query and authenticated owner.
        $current = (Invoke-BHERequest GET "/api/v2/saved-queries/$Id").data
        if ([string]$current.id -ne $Id -or [string]$current.user_id -ine $OwnerUserId.ToString()) {
            throw "Cannot confirm authenticated ownership of query $Id after permissions returned 404."
        }
        return [pscustomobject]@{
            query_id = [long]$Id
            public = $false
            shared_to_user_ids = @()
            permissions_source = 'not_returned_404'
            permissions_message = 'no query permissions exist for saved query'
        }
    }
    if ($null -eq $permissions.data -or [string]$permissions.data.query_id -ne $Id -or
        $permissions.data.public -isnot [bool]) { throw 'Unexpected query permissions response.' }
    return $permissions.data
}

function Write-NewJson {
    param([string]$Path, $Value)
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $json = ConvertTo-Json -InputObject $Value -Depth 50
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    return $fullPath
}

function Get-AuthenticatedUser {
    $user = (Invoke-BHERequest GET '/api/v2/self').data
    $uuid = [guid]::Empty
    if ($null -eq $user -or -not [guid]::TryParse([string]$user.id, [ref]$uuid) -or
        $uuid -eq [guid]::Empty -or $null -eq $user.PSObject.Properties['principal_name']) {
        throw 'Expected an authenticated BloodHound application user from /api/v2/self.'
    }
    Write-Host ("Authenticated as: {0} | UUID: {1}" -f $user.principal_name, $uuid)
    return $user
}


function Write-QueryPreview {
    param([AllowEmptyCollection()][object[]]$PreviewQueries)
    for ($index = 0; $index -lt $PreviewQueries.Count; $index++) {
        $query = $PreviewQueries[$index]
        Write-Host ("{0}. {1} | Query ID: {2}" -f ($index+1), $query.name, $query.id)
        Write-Host ("   Description: {0}" -f $query.description)
        Write-Host $query.query
        Write-Host ''
    }
    Write-Host ("Total saved queries: {0} | Scope: {1} | Owner UUID: {2}" -f $PreviewQueries.Count, $Scope.ToLowerInvariant(), $OwnerUserId)
    Write-Host ''
}

function Read-BackupDestination {
    $defaultPath = '.\queries-backup-{0}-{1}.json' -f $OwnerUserId, [datetime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff'Z'")
    Write-Host 'The backup contains query text and sharing details.'
    Write-Host ("Press Enter to save in your current folder: {0}" -f $defaultPath)
    Write-Host 'Or enter a different path in an existing folder. Existing files are never overwritten.'
    $answer = Read-ToolPrompt 'Backup JSON file path (Enter = default, Q = quit without changing queries)'
    if ($answer.Trim() -ieq 'Q') { return $null }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $defaultPath }
    return $answer
}

if ($Scope -eq 'Owned' -or $importing) {
    $self = Get-AuthenticatedUser
    if ($PSBoundParameters.ContainsKey('OwnerUserId') -and $OwnerUserId -ne [guid]$self.id) {
        throw 'Scope Owned only operates on the authenticated user. OwnerUserId does not match that user.'
    }
    $OwnerUserId = [guid]$self.id
}

if ($importing) {
    $fullImportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ImportPath)
    if ((Get-Item -LiteralPath $fullImportPath).Length -gt 32MB) { throw 'Import backup exceeds the 32 MiB file limit.' }
    $source = [IO.File]::ReadAllText($fullImportPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -eq $source -or $source.schema_version -ne 1 -or $source.queries -isnot [array]) {
        throw 'Expected a schema_version 1 JSON backup produced by this tool.'
    }
    if ($source.queries.Count -gt $MaxQueries) { throw 'Import exceeds MaxQueries.' }
    $sourceOwner = [guid]::Empty
    if (-not [guid]::TryParse([string]$source.owner_user_id,[ref]$sourceOwner) -or $sourceOwner -eq [guid]::Empty) {
        throw 'Invalid source owner in backup.'
    }
    $names = @{}
    $sourceIds = @{}
    $payloads = foreach ($record in $source.queries) {
        $query = $record.saved_query
        if ([string]$query.id -notmatch '^[1-9]\d*$' -or [string]$query.user_id -ine $sourceOwner.ToString() -or
            $query.name -isnot [string] -or [string]::IsNullOrWhiteSpace($query.name) -or
            $query.query -isnot [string] -or [string]::IsNullOrWhiteSpace($query.query) -or
            ($null -ne $query.description -and $query.description -isnot [string])) { throw 'Invalid saved query in backup.' }
        if ($names.ContainsKey($query.name) -or $sourceIds.ContainsKey([string]$query.id)) { throw 'Duplicate query names or IDs in backup.' }
        $names[$query.name]=$true
        $sourceIds[[string]$query.id]=$true
        [pscustomobject]@{ SourceId=$query.id; Name=$query.name
            Json=(ConvertTo-Json -InputObject ([ordered]@{name=$query.name;query=$query.query;description=[string]$query.description}) -Compress) }
    }
    $payloads = @($payloads)
    if ($payloads.Count -eq 0) { Write-Host 'Backup contains no queries to import.'; return }
    # Detect destination name collisions before creating anything. Never update/overwrite queries.
    $existing = Get-SavedQueries -QueryScope Owned
    foreach ($query in $existing) {
        if ($names.ContainsKey([string]$query.name)) { throw "Destination already owns a query named '$($query.name)'. No queries imported." }
    }
    Write-Host ("Importing {0} queries from owner {1} as {2}. New queries will be private; IDs and sharing are not restored." -f $payloads.Count,$sourceOwner,$OwnerUserId)
    if ($WhatIfPreference) {
        foreach ($payload in $payloads) {
            [void]$PSCmdlet.ShouldProcess("$($payload.Name) -> owner $OwnerUserId", 'Import saved query')
            [pscustomobject]@{Name=$payload.Name;OwnerUserId=$OwnerUserId;Status='Preview'}
        }
        return
    }
    if ($menuAction -eq '5') {
        $approval=Read-ToolPrompt 'Type IMPORT to create these queries as the authenticated user (anything else cancels)'
        if ($approval -cne 'IMPORT') { Write-Host 'No queries imported.'; return }
        if (-not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference='None' }
    }
    if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
        $ResultsPath = '.\queries-import-results-{0}-{1}.jsonl' -f $OwnerUserId, [datetime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff'Z'")
    }
    $importLogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsPath)
    $importStream = [IO.File]::Open($importLogPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $importWriter = New-Object IO.StreamWriter($importStream,(New-Object Text.UTF8Encoding($false)))
    $importWriter.AutoFlush=$true
    $importFailures=0
    try {
        foreach ($payload in $payloads) {
            $result=[ordered]@{SourceId=$payload.SourceId;Name=$payload.Name;OwnerUserId=$OwnerUserId.ToString();Status='Declined';Detail=''}
            if ($PSCmdlet.ShouldProcess("$($payload.Name) -> owner $OwnerUserId", 'Import saved query')) {
                try {
                    $reply=Invoke-BHERequest POST '/api/v2/saved-queries/import' $payload.Json
                    if ($reply.data -cne 'imported 1 queries') { throw 'Unexpected import response; verify destination before retrying.' }
                    $result.Status='Imported'
                } catch {
                    $importFailures++
                    $result.Status='ImportUnconfirmed'
                    $result.Detail=$_.Exception.Message
                }
            }
            $importWriter.WriteLine((ConvertTo-Json -InputObject $result -Compress))
            [pscustomobject]$result
            # Stop after an uncertain mutation to limit partial imports. Do not automatically retry.
            if ($importFailures) { break }
        }
    } finally { $importWriter.Dispose(); $importStream.Dispose() }
    Write-Host "Import results saved: $importLogPath"
    if ($importFailures) { throw "Import stopped with an unconfirmed result. Remaining queries were not attempted. Review $importLogPath and preview destination before retrying." }
    return
}

if ($interactive) {
    $selectedUser = Select-BHEUser
    if ($null -eq $selectedUser) { Write-Host 'Cancelled.'; return }
    $OwnerUserId = [guid]$selectedUser.id
    Write-Host ("Selected: {0} | UUID: {1}" -f $selectedUser.principal_name, $OwnerUserId)
}
$queries = Get-SavedQueries
Write-Host ("Matched {0} {1} saved queries for owner {2}." -f $queries.Count, $Scope.ToLowerInvariant(), $OwnerUserId)
if ($menuAction -in @('2','3','4')) {
    if ($queries.Count -eq 0) { return }
    Write-QueryPreview -PreviewQueries $queries
    if ($menuAction -eq '2') { return }
    if (-not $WhatIfPreference) {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $BackupPath=Read-BackupDestination
            if ([string]::IsNullOrWhiteSpace($BackupPath)) { Write-Host 'Cancelled.'; return }
        }
        Write-Host ("Backup file: {0}" -f $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupPath))
        if ($menuAction -eq '4') {
            Write-Host ("Delete all {0} currently listed queries owned by {1}." -f $queries.Count,$OwnerUserId)
            $approval=Read-ToolPrompt 'Type DELETE to confirm (anything else cancels)'
            if ($approval -cne 'DELETE') { Write-Host 'No queries deleted.'; return }
            if (-not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference='None' }
        }
    }
}
if ($interactive -and -not $BackupOnly) {
    if ($queries.Count -eq 0) { return }
    Write-QueryPreview -PreviewQueries $queries
    while ($true) {
        $action = (Read-ToolPrompt 'Delete [S]elected query, [A]ll matching queries, or [Q]uit (default Q)').Trim()
        if ($action -eq '' -or $action -ieq 'Q') { Write-Host 'No queries deleted.'; return }
        if ($action -ieq 'S') {
            $choice = Read-MenuNumber 'Select a query number (Q or Enter to cancel)' $queries.Count
            if ($choice -eq 0) { Write-Host 'No queries deleted.'; return }
            $queries = @($queries[$choice-1])
            break
        }
        if ($action -ieq 'A') { break }
        Write-Host 'Enter S, A, or Q.'
    }
    $Delete = $true
    if (-not $WhatIfPreference) {
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $timestamp = [datetime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            $defaultBackupPath = '.\queries-backup-{0}-{1}.json' -f $OwnerUserId, $timestamp
            Write-Host 'Before deleting, the script saves the selected queries and their sharing details to a JSON backup.'
            Write-Host ("Press Enter to use this timestamped file in your current folder: {0}" -f $defaultBackupPath)
            Write-Host 'Or enter a different path. The folder must already exist, and the file must not already exist.'
            $answer = Read-ToolPrompt 'Backup JSON file path (Enter = default, Q = quit without deleting)'
            if ($answer.Trim() -ieq 'Q') { Write-Host 'No queries deleted.'; return }
            $BackupPath = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultBackupPath } else { $answer }
        }
        Write-Host ("Backup file: {0}" -f $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupPath))
        Write-Host ("Selected {0} queries for deletion. Owner UUID: {1}" -f $queries.Count, $OwnerUserId)
        $approval = Read-ToolPrompt 'Type DELETE to confirm this selection (anything else cancels)'
        if ($approval -cne 'DELETE') { Write-Host 'No queries deleted.'; return }
        # One explicit confirmation covers the selection; an explicit -Confirm still adds per-query prompts.
        if (-not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }
    }
}
if ((-not $Delete -and -not $BackupOnly) -or $WhatIfPreference) {
    foreach ($query in $queries) {
        if ($Delete) { [void]$PSCmdlet.ShouldProcess("$($query.id): $($query.name)", "Delete $Scope saved query") }
        if ($BackupOnly) { [void]$PSCmdlet.ShouldProcess($query.name, 'Back up saved query') }
        [pscustomobject]@{ Id=$query.id; Name=$query.name; OwnerUserId=$query.user_id; Status='Preview' }
    }
    return
}
if ($queries.Count -eq 0) { return }

if ($BackupOnly) {
    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        $BackupPath = '.\queries-backup-{0}-{1}.json' -f $OwnerUserId, [datetime]::UtcNow.ToString("yyyyMMdd-HHmmss-fff'Z'")
    }
    if (-not $PSCmdlet.ShouldProcess($BackupPath, 'Save query backup without deleting')) { return }
}

# Fetch sharing metadata for the entire backup before issuing any DELETE request.
$backupRecords = foreach ($query in $queries) {
    $permissions = Get-QueryPermissions ([string]$query.id)
    if ($Scope -eq 'Public' -and -not $permissions.public) { throw 'Public sharing changed before backup. Run preview again.' }
    [pscustomobject]@{ saved_query=$query; permissions=$permissions }
}
$backup = [ordered]@{
    schema_version=1; tenant=$BaseUrl.AbsoluteUri.TrimEnd('/'); owner_user_id=$OwnerUserId.ToString()
    exported_at=[datetime]::UtcNow.ToString('o'); scope=$Scope.ToLowerInvariant(); queries=@($backupRecords)
}
$savedPath = Write-NewJson $BackupPath $backup
Write-Host "Backup saved: $savedPath"
if ($BackupOnly) {
    foreach ($query in $queries) { [pscustomobject]@{Id=$query.id;Name=$query.name;OwnerUserId=$query.user_id;Status='BackedUp';BackupPath=$savedPath} }
    return
}
$backupStem = [IO.Path]::GetFileNameWithoutExtension($savedPath)
if ($backupStem.StartsWith('queries-backup-', [StringComparison]::OrdinalIgnoreCase)) {
    $backupStem = $backupStem.Substring('queries-backup-'.Length)
}
$resultsPath = Join-Path ([IO.Path]::GetDirectoryName($savedPath)) ("queries-deletion-results-{0}.jsonl" -f $backupStem)
# Reserve the results file before deletion; it is flushed after every attempt.
$resultStream = [IO.File]::Open($resultsPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
$writer = New-Object IO.StreamWriter($resultStream, (New-Object Text.UTF8Encoding($false)))
$writer.AutoFlush = $true
$failed = 0
try {
    foreach ($query in $queries) {
        $result = [ordered]@{ Id=$query.id; Name=$query.name; OwnerUserId=$query.user_id; Status='Declined'; Detail='' }
        if ($PSCmdlet.ShouldProcess("$($query.id): $($query.name) | owner $OwnerUserId", "Delete $Scope saved query")) {
            $deleteStarted = $false
            try {
                $current = (Invoke-BHERequest GET "/api/v2/saved-queries/$($query.id)").data
                if ([string]$current.id -ne [string]$query.id -or [string]$current.user_id -ine $OwnerUserId.ToString()) {
                    throw 'Query ID or ownership changed.'
                }
                foreach ($field in @('name','query','description','updated_at')) {
                    if ([string]$current.$field -cne [string]$query.$field) { throw "Query $field changed since backup." }
                }
                $permissions = Get-QueryPermissions ([string]$query.id)
                if ($Scope -eq 'Public' -and -not $permissions.public) { throw 'Query is no longer public.' }
                $deleteStarted = $true
                Invoke-BHERequest DELETE "/api/v2/saved-queries/$($query.id)"
                $result.Status = 'Deleted'
            } catch {
                $failed++
                $result.Status = if ($deleteStarted) { 'DeleteUnconfirmed' } else { 'Skipped' }
                $result.Detail = $_.Exception.Message
                # Record the failure before continuing; no retries of destructive requests.
            }
        }
        $writer.WriteLine((ConvertTo-Json -InputObject $result -Compress))
        [pscustomobject]$result
    }
} finally { $writer.Dispose(); $resultStream.Dispose() }
Write-Host "Results saved: $resultsPath"
if ($failed) { throw "$failed queries were skipped or their deletion could not be confirmed. Review $resultsPath." }

}

# Reinvoke in a fresh function scope: selected users, paths, and operation flags
# never leak from a cancelled operation into the next menu choice.
$invocation = @{}
foreach ($key in $PSBoundParameters.Keys) { $invocation[$key] = $PSBoundParameters[$key] }
while ($true) {
    try {
        Invoke-BHESavedQueryOperation @invocation
        break
    } catch {
        if (-not $_.Exception.Data.Contains('BHEReturnToMainMenu')) { throw }
        foreach ($key in @('OwnerUserId','Scope','BackupOnly','Delete','ImportPath','BackupPath','ResultsPath')) {
            $invocation.Remove($key)
        }
        Write-Host ''
        if ($_.Exception.Data.Contains('BHEFriendlyError')) {
            Write-Host ([string]$_.Exception.Data['BHEFriendlyError']) -ForegroundColor Yellow
        } else {
            Write-Host 'Returned to main menu. The pending action was cancelled.'
        }
    }
}
