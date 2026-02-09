@echo off
setlocal EnableExtensions

set "CONF=%~dp0jira-export-logwork.conf"
if not exist "%CONF%" (
  echo [ERROR] Missing config file: %CONF%
  echo Create jira-export-logwork.conf next to this .bat file.
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "& { param($confPath,$selfPath) " ^
  "  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
  "  $raw = Get-Content -LiteralPath $selfPath -Raw; " ^
  "  $m = [string]::Concat('__PS_','PAYLOAD_9F1A3B','__'); " ^
  "  $parts = $raw -split [regex]::Escape($m), 2; " ^
  "  if ($parts.Length -lt 2) { throw 'Embedded PowerShell block not found.' } " ^
  "  $code = $parts[1]; " ^
  "  & ([ScriptBlock]::Create($code)) -ConfPath $confPath; " ^
  "} " ^
  "%CONF%" "%~f0"

exit /b %ERRORLEVEL%

__PS_PAYLOAD_9F1A3B__
param([Parameter(Mandatory=$true)][string]$ConfPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-Conf([string]$path){
  $cfg = @{}
  $users = New-Object System.Collections.Generic.List[string]

  foreach($line in (Get-Content -LiteralPath $path)){
    $t = $line.Trim()
    if(!$t) { continue }
    if($t.StartsWith('#')) { continue }

    $i = $t.IndexOf('=')
    if($i -lt 1) { continue }

    $k = $t.Substring(0,$i).Trim()
    $v = $t.Substring($i+1).Trim()

    $hash = $v.IndexOf(' #')
    if($hash -gt 0){ $v = $v.Substring(0,$hash).Trim() }

    if($k -ieq 'USER'){
      if($v){ $users.Add($v) }
      continue
    }

    $cfg[$k.ToUpperInvariant()] = $v
  }

  if($cfg.ContainsKey('USERS') -and $cfg['USERS']){
    ($cfg['USERS'] -split '[;,]\s*') | ForEach-Object {
      $u = $_.Trim()
      if($u){ $users.Add($u) }
    }
  }

  $cfg['__USERS__'] = $users
  return $cfg
}

function BasicAuthHeader([string]$email, [string]$token){
  $pair = "$email`:$token"
  $b64  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
  return @{ Authorization="Basic $b64"; Accept="application/json" }
}

function Invoke-Jira([string]$Method, [string]$Url, $Headers, $BodyObj=$null){
  for($n=1; $n -le 6; $n++){
    try{
      if($Method -eq 'GET'){
        return Invoke-RestMethod -Method Get -Uri $Url -Headers $Headers
      } else {
        $json = $BodyObj | ConvertTo-Json -Depth 30 -Compress
        return Invoke-RestMethod -Method Post -Uri $Url -Headers $Headers -ContentType 'application/json' -Body $json
      }
    } catch {
      $resp = $_.Exception.Response
      if($resp){
        $code = [int]$resp.StatusCode
        if($code -eq 429 -or $code -ge 500){
          Start-Sleep -Seconds (2*$n)
          continue
        }
      }
      throw
    }
  }
  throw "$Method failed after retries: $Url"
}

function Resolve-AccountIdByEmail([string]$Base, $Headers, [string]$Email){
  $q = [Uri]::EscapeDataString($Email)
  $url = "$Base/rest/api/3/user/search?query=$q&maxResults=50"
  $users = Invoke-Jira -Method 'GET' -Url $url -Headers $Headers

  foreach($u in $users){
    if($u.PSObject.Properties.Match('emailAddress').Count -gt 0 -and $u.emailAddress -eq $Email){
      return $u.accountId
    }
  }

  if($users.Count -eq 1){ return $users[0].accountId }

  $cands = $users | ForEach-Object {
    $em = if($_.PSObject.Properties.Match('emailAddress').Count -gt 0){ $_.emailAddress } else { 'N/A' }
    "displayName=$($_.displayName) accountId=$($_.accountId) email=$em"
  }
  throw "Cannot resolve accountId for '$Email' (email may be hidden or multiple matches). Candidates:`n$($cands -join "`n")"
}

function Build-Jql([string]$AccountId, [string]$ScopeJql, [string]$From, [string]$To){
  $jql = "worklogAuthor in (""$AccountId"")"
  if($From){ $jql += " AND worklogDate >= ""$From""" }
  if($To){   $jql += " AND worklogDate <= ""$To""" }
  if($ScopeJql){ $jql = "($ScopeJql) AND ($jql)" }
  return "$jql ORDER BY key ASC"
}

function Search-Issues([string]$Base, $Headers, [string]$Jql){
  $url = "$Base/rest/api/3/search/jql"
  $next = $null
  $list = New-Object System.Collections.Generic.List[object]

  while($true){
    $body = @{ jql=$Jql; fields=@('summary'); maxResults=100 }
    if($next){ $body.nextPageToken = $next }

    $resp = Invoke-Jira -Method 'POST' -Url $url -Headers $Headers -BodyObj $body

    foreach($iss in $resp.issues){
      $sum = ($iss.fields.summary -replace "[`r`n`t]"," ").Trim()
      $list.Add([PSCustomObject]@{ Key=$iss.key; Summary=$sum })
    }

    if($resp.isLast -eq $true){ break }
    $next = $resp.nextPageToken
    if(-not $next){ break }
  }

  return $list
}

function Get-Worklogs([string]$Base, $Headers, [string]$IssueKey){
  $all = New-Object System.Collections.Generic.List[object]
  $startAt = 0
  $max = 100

  while($true){
    $url = "$Base/rest/api/3/issue/$IssueKey/worklog?startAt=$startAt&maxResults=$max"
    $resp = Invoke-Jira -Method 'GET' -Url $url -Headers $Headers
    foreach($w in $resp.worklogs){ $all.Add($w) }
    if($resp.worklogs.Count -lt $max){ break }
    $startAt += $max
  }

  return $all
}

function CsvEscape([string]$s){
  if($null -eq $s){ $s = '' }
  $s = $s -replace "`r","" -replace "`n","\n"
  $s = $s -replace '"','""'
  return '"' + $s + '"'
}

function ToB64([string]$s){
  if([string]::IsNullOrEmpty($s)){ return '' }
  return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))
}

# ---------------- MAIN ----------------
$cfg = Read-Conf $ConfPath

$domain    = $cfg['DOMAIN']
$authEmail = $cfg['AUTH_EMAIL']
$token     = $cfg['API_TOKEN']
$scopeJql  = $cfg['SCOPE_JQL']
$from      = $cfg['FROM']
$to        = $cfg['TO']
$outParent = $cfg['OUT_PARENT']
$users     = $cfg['__USERS__']

if(-not $domain -or -not $authEmail -or -not $token){
  throw "Config missing required keys: DOMAIN, AUTH_EMAIL, API_TOKEN"
}
if($users.Count -lt 1){
  throw "No target users. Set USERS=... or multiple USER=... lines in .conf"
}

$base = "https://$domain"
$headers = BasicAuthHeader $authEmail $token

if(-not $outParent -or [string]::IsNullOrWhiteSpace($outParent)){
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $here = Split-Path -Parent $ConfPath
  $outParent = Join-Path $here ("jira_worklogs_export_$stamp")
}
New-Item -ItemType Directory -Force -Path $outParent | Out-Null

Write-Host "Output parent: $outParent"
Write-Host "Users: $($users -join ', ')"

foreach($userEmail in $users){
  Write-Host ""
  Write-Host "=== Processing user: $userEmail ==="

  $safeUser = ($userEmail -replace '[\\/:*?"<>|]','_') -replace '[@.]','_'
  $userDir = Join-Path $outParent $safeUser
  New-Item -ItemType Directory -Force -Path $userDir | Out-Null

  $summaryPath = Join-Path $userDir "summary.csv"
  $detailPath  = Join-Path $userDir "detail.csv"

  "IssueKey,IssueSummary,TotalSeconds,TotalHours" | Set-Content -Encoding UTF8 -LiteralPath $summaryPath

  "IssueKey,IssueSummary,WorklogId,Author,AccountId,Started,TimeSpentSeconds,TimeSpentHours,Created,Updated,CommentB64" | Set-Content -Encoding UTF8 -LiteralPath $detailPath

  try {
    $accountId = Resolve-AccountIdByEmail -Base $base -Headers $headers -Email $userEmail
  } catch {
    Write-Warning $_.Exception.Message
    continue
  }

  $jql = Build-Jql -AccountId $accountId -ScopeJql $scopeJql -From $from -To $to
  Write-Host "JQL: $jql"

  $issues = Search-Issues -Base $base -Headers $headers -Jql $jql
  Write-Host "Issues: $($issues.Count)"

  $grandSeconds = 0

  foreach($iss in $issues){
    $key = $iss.Key
    $sum = $iss.Summary
    $issueTotalSeconds = 0

    $worklogs = Get-Worklogs -Base $base -Headers $headers -IssueKey $key
    foreach($w in $worklogs){
      if($w.author.accountId -ne $accountId){ continue }

      $started = [string]$w.started
      $startedDay = if($started.Length -ge 10){ $started.Substring(0,10) } else { $started }

      if($from -and ($startedDay -lt $from)){ continue }
      if($to   -and ($startedDay -gt $to)){ continue }

      $secs = [int]$w.timeSpentSeconds
      $issueTotalSeconds += $secs
      $grandSeconds += $secs

      $hrs = [math]::Round(($secs/3600), 4)

      $commentText = ""
      if($w.PSObject.Properties.Match('comment').Count -gt 0 -and $null -ne $w.comment){
        if($w.comment -is [string]){
          $commentText = $w.comment
        } else {
          $commentText = ($w.comment | ConvertTo-Json -Depth 30 -Compress)
        }
        $commentText = $commentText -replace "[`r`n`t]"," "
      }
      $commentB64 = ToB64 $commentText

      $fields = @(
        $key,
        $sum,
        [string]$w.id,
        [string]$w.author.displayName,
        [string]$w.author.accountId,
        $started,
        [string]$secs,
        [string]$hrs,
        [string]$w.created,
        [string]$w.updated,
        $commentB64
      )

      $line = ($fields | ForEach-Object { CsvEscape $_ }) -join ','
      Add-Content -Encoding UTF8 -LiteralPath $detailPath -Value $line
    }

    $issueHours = [math]::Round(($issueTotalSeconds/3600), 4)

    $sumFields = @(
      $key,
      $sum,
      [string]$issueTotalSeconds,
      [string]$issueHours
    )

    $sumLine = ($sumFields | ForEach-Object { CsvEscape $_ }) -join ','
    Add-Content -Encoding UTF8 -LiteralPath $summaryPath -Value $sumLine
  }

  $grandHours = [math]::Round(($grandSeconds/3600), 4)
  $summarySumFields = @(
    'SUM',
    'All issues',
    [string]$grandSeconds,
    [string]$grandHours
  )
  $summarySumLine = ($summarySumFields | ForEach-Object { CsvEscape $_ }) -join ','
  Add-Content -Encoding UTF8 -LiteralPath $summaryPath -Value $summarySumLine

  $detailSumFields = @(
    'SUM',
    'All worklogs',
    '',
    '',
    '',
    '',
    [string]$grandSeconds,
    [string]$grandHours,
    '',
    '',
    ''
  )
  $detailSumLine = ($detailSumFields | ForEach-Object { CsvEscape $_ }) -join ','
  Add-Content -Encoding UTF8 -LiteralPath $detailPath -Value $detailSumLine

  Write-Host "Done user -> $userDir"
}

Write-Host ""
Write-Host "ALL DONE. Parent folder: $outParent"
