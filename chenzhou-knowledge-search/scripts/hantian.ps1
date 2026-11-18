#Requires -Version 7.0
<#
瀚天知识库连接器（MCP + OAuth 授权码/PKCE）

用法（输出一律为单行 JSON，便于上游解析）：
  .\hantian.ps1 -Action start                     生成授权链接，并在后台起本机回调监听（不自动打开浏览器）
  .\hantian.ps1 -Action status                    查询授权状态：connected / pending / denied / idle
  .\hantian.ps1 -Action call -Tool list_topics    调用知识库工具
  .\hantian.ps1 -Action call -Tool search_units -ArgsJson '{"query":"苏仙岭","limit":5}'
  .\hantian.ps1 -Action logout                    清除本地凭据
  .\hantian.ps1 -Action listen -Port 8765         内部使用：后台回调监听进程
#>

param(
  [ValidateSet('start', 'status', 'call', 'logout', 'listen')]
  [string]$Action = 'status',
  [string]$Tool = 'library_stats',
  [string]$ArgsJson = '{}',
  [int]$Port = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$StateDir = Join-Path $env:LOCALAPPDATA 'hantian-kb'
if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

$PendingFile   = Join-Path $StateDir 'pending.json'
$TokenFile     = Join-Path $StateDir 'token.json'
$CallbacksFile = Join-Path $StateDir 'callbacks.jsonl'
$ListenerFile  = Join-Path $StateDir 'listener.json'
$SessionFile   = Join-Path $StateDir 'mcp_session.txt'
$ErrorFile     = Join-Path $StateDir 'last_error.json'

$Endpoint  = 'https://www.ht-think.com/mcp'
$AuthBase  = 'https://www.ht-think.com'
$RechargeUrl = 'https://www.ht-think.com/portal/recharge'
$Scope     = 'library.read'
$PendingTtlMinutes = 20

function Out-Json($obj) { ($obj | ConvertTo-Json -Depth 12 -Compress) }

function Read-Json($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  return ($raw | ConvertFrom-Json)
}

function Write-JsonFile($path, $obj) {
  [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding $false))
}

function New-B64Url([byte[]]$bytes) {
  [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-PortOpen([int]$p) {
  try {
    $c = [System.Net.Sockets.TcpClient]::new()
    $ar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne(400)) { $c.Close(); return $false }
    $c.EndConnect($ar); $c.Close(); return $true
  } catch { return $false }
}

# ---------- 后台回调监听 ----------

function Start-Listener([int]$listenPort) {
  $meta = Read-Json $ListenerFile
  if ($meta -and $meta.pid -and $meta.port -eq $listenPort) {
    $proc = Get-Process -Id $meta.pid -ErrorAction SilentlyContinue
    if ($proc -and (Test-PortOpen $listenPort)) { return $meta }
  }

  # 用 Win32_Process 启动，完全脱离当前进程的句柄，避免调用方管道被监听进程挂住
  $self = $PSCommandPath
  $exe = (Get-Command pwsh -ErrorAction Stop).Source
  $cmdLine = '"' + $exe + '" -NoProfile -ExecutionPolicy Bypass -File "' + $self + '" -Action listen -Port ' + $listenPort
  $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine }
  if ($created.ReturnValue -ne 0) { throw "后台监听进程启动失败，ReturnValue=$($created.ReturnValue)" }
  $pidNew = [int]$created.ProcessId

  Start-Sleep -Milliseconds 900
  $meta = [ordered]@{ pid = $pidNew; port = $listenPort; started_at = (Get-Date).ToString('s') }
  Write-JsonFile $ListenerFile $meta
  return $meta
}

function Get-FreePort([int]$preferred) {
  if ($preferred -gt 0) { if (-not (Test-PortOpen $preferred)) { return $preferred } }
  foreach ($p in 8765..8800) { if (-not (Test-PortOpen $p)) { return $p } }
  throw '没有可用的本机端口'
}

# ---------- 授权 ----------

function Register-Client([string]$redirectUri) {
  $reg = @{
    client_name            = '瀚天知识库 hantian-zhishi'
    redirect_uris          = @($redirectUri)
    grant_types            = @('authorization_code', 'refresh_token')
    response_types         = @('code')
    token_endpoint_auth_method = 'none'
    scope                  = $Scope
  } | ConvertTo-Json -Compress
  $r = Invoke-WebRequest -Uri "$AuthBase/oauth/register" -Method Post -Body $reg -ContentType 'application/json' -TimeoutSec 30 -SkipHttpErrorCheck
  if ($r.StatusCode -notin 200, 201) { throw "客户端注册失败 HTTP $($r.StatusCode): $($r.Content)" }
  return ($r.Content | ConvertFrom-Json).client_id
}

function Invoke-TokenExchange($pending, [string]$code) {
  $form = @{
    grant_type    = 'authorization_code'
    code          = $code
    redirect_uri  = $pending.redirect_uri
    client_id     = $pending.client_id
    code_verifier = $pending.code_verifier
  }
  $body = ($form.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
  $r = Invoke-WebRequest -Uri "$AuthBase/oauth/token" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 -SkipHttpErrorCheck
  if ($r.StatusCode -ne 200) { throw "换取令牌失败 HTTP $($r.StatusCode): $($r.Content)" }
  $tok = $r.Content | ConvertFrom-Json
  $tok | Add-Member -NotePropertyName client_id -NotePropertyValue $pending.client_id -Force
  $tok | Add-Member -NotePropertyName issued_ms -NotePropertyValue ([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) -Force
  Write-JsonFile $TokenFile $tok
  Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $SessionFile -Force -ErrorAction SilentlyContinue
  return $tok
}

function Get-AccessToken {
  $tok = Read-Json $TokenFile
  if (-not $tok) { return $null }
  $now = [DateTimeOffset]::Now
  $expiresAt = if ($tok.issued_ms) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$tok.issued_ms) } else { $now.AddSeconds(-1) }
  if ($now -lt $expiresAt.AddSeconds(-60)) { return $tok.access_token }

  if (-not $tok.refresh_token) { return $null }
  $form = @{ grant_type = 'refresh_token'; refresh_token = $tok.refresh_token; client_id = $tok.client_id }
  $body = ($form.GetEnumerator() | ForEach-Object { "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
  $r = Invoke-WebRequest -Uri "$AuthBase/oauth/token" -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 -SkipHttpErrorCheck
  if ($r.StatusCode -ne 200) { Remove-Item -LiteralPath $TokenFile -Force -ErrorAction SilentlyContinue; return $null }
  $new = $r.Content | ConvertFrom-Json
  $new | Add-Member -NotePropertyName client_id -NotePropertyValue $tok.client_id -Force
  $new | Add-Member -NotePropertyName issued_ms -NotePropertyValue ([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) -Force
  Write-JsonFile $TokenFile $new
  return $new.access_token
}

# ---------- MCP ----------

function Send-Mcp($token, [string]$method, $params, [bool]$notification) {
  $msg = [ordered]@{ jsonrpc = '2.0' }
  if (-not $notification) { $msg.id = [int](Get-Random -Minimum 1 -Maximum 100000) }
  $msg.method = $method
  if ($null -ne $params) { $msg.params = $params }
  $body = $msg | ConvertTo-Json -Depth 12 -Compress

  $headers = @{ 'Authorization' = "Bearer $token"; 'Accept' = 'application/json, text/event-stream' }
  if (Test-Path -LiteralPath $SessionFile) {
    $sid = (Get-Content -LiteralPath $SessionFile -Raw -Encoding utf8).Trim()
    if ($sid) { $headers['Mcp-Session-Id'] = $sid }
  }
  $resp = Invoke-WebRequest -Uri $Endpoint -Method Post -Body $body -ContentType 'application/json' -Headers $headers -TimeoutSec 60 -SkipHttpErrorCheck
  $newSid = $resp.Headers['Mcp-Session-Id']
  if ($newSid) {
    $v = if ($newSid -is [array]) { $newSid[0] } else { $newSid }
    [IO.File]::WriteAllText($SessionFile, $v, (New-Object Text.UTF8Encoding $false))
  }
  return [pscustomobject]@{ Status = [int]$resp.StatusCode; Content = $resp.Content }
}

function Get-Rpc($content) {
  if ([string]::IsNullOrWhiteSpace($content)) { return $null }
  if ($content.TrimStart().StartsWith('{')) { return ($content | ConvertFrom-Json) }
  $last = $null
  foreach ($line in $content -split "`n") {
    $l = $line.TrimEnd()
    if ($l.StartsWith('data:')) { $p = $l.Substring(5).Trim(); if ($p) { $last = $p } }
  }
  if ($last) { return ($last | ConvertFrom-Json) }
  return $null
}

function Initialize-Mcp($token) {
  $params = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'doubao-desktop'; version = '1.0.0' } }
  $r = Send-Mcp $token 'initialize' $params $false
  if ($r.Status -ge 400) { return $r }
  Send-Mcp $token 'notifications/initialized' @{} $true | Out-Null
  return $r
}

function Classify-Failure([int]$httpStatus, $rpc, $text) {
  if ($httpStatus -eq 402) { return 'insufficient_credits' }
  if ($httpStatus -eq 401) { return 'unauthorized' }
  if ($httpStatus -eq 429) { return 'rate_limited' }
  $blob = ''
  if ($rpc -and $rpc.error) { $blob += ($rpc.error | ConvertTo-Json -Compress) }
  if ($text) { $blob += $text }
  if ($blob -match '余额不足|积分不足|额度不足|配额不足|欠费|insufficient|quota|credit|payment required') { return 'insufficient_credits' }
  if ($blob -match 'unauthorized|未授权|授权缺失|token') { return 'unauthorized' }
  return 'error'
}

# ---------- 动作分支 ----------

if ($Action -eq 'listen') {
  $listenPort = if ($Port -gt 0) { $Port } else { 8765 }
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $listenPort)
  $listener.Start()
  $deadline = (Get-Date).AddMinutes($PendingTtlMinutes + 10)
  while ((Get-Date) -lt $deadline) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
    try {
      $client = $listener.AcceptTcpClient()
      $stream = $client.GetStream()
      $stream.ReadTimeout = 5000
      $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII)
      $line = $reader.ReadLine()
      if ([string]::IsNullOrEmpty($line)) { $client.Close(); continue }
      $target = ($line.Split(' '))[1]

      if ($target -match '^/callback') {
        $query = if ($target.IndexOf('?') -ge 0) { $target.Substring($target.IndexOf('?') + 1) } else { '' }
        $params = @{}
        foreach ($kv in $query.Split('&')) {
          if ($kv -eq '') { continue }
          $k, $v = $kv.Split('=', 2)
          $params[[uri]::UnescapeDataString($k)] = if ($v) { [uri]::UnescapeDataString($v) } else { '' }
        }
        $rec = [ordered]@{
          code              = $params['code']
          state             = $params['state']
          error             = $params['error']
          error_description = $params['error_description']
          received_at       = (Get-Date).ToString('s')
        }
        Add-Content -LiteralPath $CallbacksFile -Value (Out-Json $rec) -Encoding utf8

        $html = '<!doctype html><meta charset="utf-8"><title>授权完成</title><body style="font-family:system-ui;padding:40px"><h2>授权已收到</h2><p>可以关闭此页面，回到对话继续。</p></body>'
        $b = [Text.Encoding]::UTF8.GetBytes($html)
        $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($b.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($h, 0, $h.Length); $stream.Write($b, 0, $b.Length); $stream.Flush()
      } else {
        $b = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
        $stream.Write($b, 0, $b.Length); $stream.Flush()
      }
      $client.Close()
    } catch {
      Add-Content -LiteralPath (Join-Path $StateDir 'listener_err.log') -Value "$([DateTime]::Now.ToString('s')) $($_.Exception.Message)" -Encoding utf8
    }
  }
  $listener.Stop()
  exit 0
}

if ($Action -eq 'start') {
  $statusNow = $null
  $token = Get-AccessToken
  if ($token) {
    $r = Initialize-Mcp $token
    if ($r.Status -lt 400) {
      Out-Json ([ordered]@{ ok = $true; status = 'connected'; already_connected = $true })
      exit 0
    }
  }

  $listenPort = Get-FreePort $Port
  $redirectUri = "http://127.0.0.1:$listenPort/callback"
  $clientId = Register-Client $redirectUri

  $rand = New-Object byte[] 48
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rand)
  $verifier = New-B64Url $rand
  $challenge = New-B64Url ([System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
  $stateRand = New-Object byte[] 16
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($stateRand)
  $state = New-B64Url $stateRand

  $authUrl = "$AuthBase/oauth/authorize?response_type=code" +
    "&client_id=$([uri]::EscapeDataString($clientId))" +
    "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
    "&scope=$([uri]::EscapeDataString($Scope))" +
    "&state=$([uri]::EscapeDataString($state))" +
    "&code_challenge=$([uri]::EscapeDataString($challenge))" +
    "&code_challenge_method=S256"

  $pending = [ordered]@{
    client_id     = $clientId
    redirect_uri  = $redirectUri
    code_verifier = $verifier
    state         = $state
    auth_url      = $authUrl
    port          = $listenPort
    created_at    = (Get-Date).ToString('s')
    expires_at    = (Get-Date).AddMinutes($PendingTtlMinutes).ToString('s')
  }
  Write-JsonFile $PendingFile $pending
  Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue

  $meta = Start-Listener $listenPort
  Out-Json ([ordered]@{
      ok            = $true
      status        = 'pending'
      auth_url      = $authUrl
      port          = $listenPort
      listener_pid  = $meta.pid
      expires_at    = $pending.expires_at
      hint          = '把 auth_url 以可点击链接形式发给用户，等他完成登录与授权；不要自动打开浏览器'
    })
  exit 0
}

if ($Action -eq 'status') {
  $token = Get-AccessToken
  if ($token) { Out-Json ([ordered]@{ ok = $true; status = 'connected' }); exit 0 }

  $pending = Read-Json $PendingFile
  if (-not $pending) {
    $err = Read-Json $ErrorFile
    if ($err) {
      Out-Json ([ordered]@{ ok = $false; status = 'denied'; error = $err.error; error_description = $err.error_description; hint = '重新执行 start 生成新的授权链接' })
    } else {
      Out-Json ([ordered]@{ ok = $false; status = 'idle'; hint = '执行 start 生成授权链接' })
    }
    exit 0
  }

  $callback = $null
  if (Test-Path -LiteralPath $CallbacksFile) {
    foreach ($line in (Get-Content -LiteralPath $CallbacksFile -Encoding utf8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $rec = $line | ConvertFrom-Json
      if ($rec.state -eq $pending.state) { $callback = $rec }
    }
  }

  if ($callback) {
    if ($callback.error) {
      Write-JsonFile $ErrorFile ([ordered]@{ error = $callback.error; error_description = $callback.error_description; at = (Get-Date).ToString('s') })
      Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
      Out-Json ([ordered]@{ ok = $false; status = 'denied'; error = $callback.error; error_description = $callback.error_description; hint = '用户点了拒绝或授权失败，重新执行 start 生成新链接' })
      exit 0
    }
    if ($callback.code) {
      try {
        Invoke-TokenExchange $pending $callback.code | Out-Null
      } catch {
        Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
        Out-Json ([ordered]@{ ok = $false; status = 'exchange_failed'; detail = $_.Exception.Message; hint = '授权码换取令牌失败，重新执行 start' })
        exit 0
      }
      $tok = Get-AccessToken
      $r = Initialize-Mcp $tok
      if ($r.Status -lt 400) {
        Out-Json ([ordered]@{ ok = $true; status = 'connected'; just_connected = $true })
      } else {
        Out-Json ([ordered]@{ ok = $true; status = 'token_saved_but_check_failed'; http = $r.Status; hint = '令牌已保存，但服务校验失败，稍后重试 status' })
      }
      exit 0
    }
  }

  $left = ([DateTime]::Parse($pending.expires_at) - (Get-Date)).TotalSeconds
  if ($left -le 0) {
    Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
    Out-Json ([ordered]@{ ok = $false; status = 'expired'; hint = '授权链接已过期，重新执行 start' })
    exit 0
  }
  Out-Json ([ordered]@{
      ok = $true; status = 'pending'; auth_url = $pending.auth_url
      port = $pending.port; seconds_left = [int]$left
      hint = '仍在等待用户在浏览器完成登录与授权'
    })
  exit 0
}

if ($Action -eq 'logout') {
  Remove-Item -LiteralPath $TokenFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $SessionFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $CallbacksFile -Force -ErrorAction SilentlyContinue
  Out-Json ([ordered]@{ ok = $true; status = 'logged_out' })
  exit 0
}

if ($Action -eq 'call') {
  $token = Get-AccessToken
  if (-not $token) {
    Out-Json ([ordered]@{ ok = $false; status = 'unauthorized'; hint = '尚未连接知识库，先执行 start 并把 auth_url 发给用户' })
    exit 0
  }

  if (-not (Test-Path -LiteralPath $SessionFile)) {
    $init = Initialize-Mcp $token
    if ($init.Status -ge 400) {
      $topic = Classify-Failure $init.Status (Get-Rpc $init.Content) ''
      Out-Json ([ordered]@{ ok = $false; status = $topic; http = $init.Status })
      exit 0
    }
  }

  $toolArgs = if ($ArgsJson -and $ArgsJson -ne '{}') { $ArgsJson | ConvertFrom-Json } else { @{} }
  $raw = Send-Mcp $token 'tools/call' @{ name = $Tool; arguments = $toolArgs } $false

  if ($raw.Status -in 400, 404) {
    Remove-Item -LiteralPath $SessionFile -Force -ErrorAction SilentlyContinue
    $init = Initialize-Mcp $token
    if ($init.Status -lt 400) {
      $raw = Send-Mcp $token 'tools/call' @{ name = $Tool; arguments = $toolArgs } $false
    }
  }

  $rpc = Get-Rpc $raw.Content
  $text = $null
  if ($rpc -and $rpc.result) {
    $text = ($rpc.result.content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text
  }

  $failed = ($raw.Status -ge 400) -or ($rpc -and $rpc.error) -or ($rpc -and $rpc.result -and $rpc.result.isError)
  if ($failed) {
    $topic = Classify-Failure $raw.Status $rpc $text
    $out = [ordered]@{
      ok     = $false
      status = $topic
      http   = $raw.Status
      tool   = $Tool
    }
    if ($topic -eq 'insufficient_credits') {
      $out.recharge_url = $RechargeUrl
      $out.hint = '额度不足：把 recharge_url 发给用户，告知充值后回复“已充值”，从暂停处继续'
    } elseif ($topic -eq 'unauthorized') {
      $out.hint = '授权失效：执行 start 重新授权'
    } elseif ($topic -eq 'rate_limited') {
      $out.hint = '调用过密：等几秒再重试，不要连续重发'
    } else {
      $out.detail = $text
      if ($rpc -and $rpc.error) { $out.error = $rpc.error }
      $out.hint = '服务返回异常，按 detail 判断是参数问题还是服务故障'
    }
    Out-Json $out
    exit 0
  }

  Out-Json ([ordered]@{ ok = $true; status = 'ok'; tool = $Tool; data = $text })
  exit 0
}
