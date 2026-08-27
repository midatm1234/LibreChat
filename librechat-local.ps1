[CmdletBinding()]
param(
  [ValidateSet('start', 'stop', 'restart', 'status')]
  [string] $Action = 'start'
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$RuntimeDirectory = Join-Path $Root '.local'
$LogDirectory = Join-Path $RuntimeDirectory 'logs'
$RunDirectory = Join-Path $RuntimeDirectory 'run'
$StatePath = Join-Path $RunDirectory 'librechat.json'
$MongoLog = Join-Path $LogDirectory 'mongodb.log'
$MongoErrorLog = Join-Path $LogDirectory 'mongodb.error.log'
$LibreChatLog = Join-Path $LogDirectory 'librechat.log'
$LibreChatErrorLog = Join-Path $LogDirectory 'librechat.error.log'

$BridgeDirectory = 'C:\Users\huikyole\Google_ADK\adk_agents'
$BridgeUvicorn = 'C:\Users\huikyole\AppData\Local\miniforge3\envs\google-adk\Scripts\uvicorn.exe'
$BridgePort = 8001
$BridgeLog = Join-Path $LogDirectory 'adk-bridge.log'
$BridgeErrorLog = Join-Path $LogDirectory 'adk-bridge.error.log'

# Compass OKF/workflow MCP server (compass-team-kickoff-aurora's
# src/compass_aurora/mcp/server.py; 31 tools: okf_*, workflow_*, merra2_*,
# era5_*, model_*), served over SSE so LibreChat can reach it at
# http://localhost:8000/sse (see mcpServers in librechat.yaml). Superseded
# the old D:\Compass\server.py 7-tool MERRA-2 prototype.
$CompassRepoRoot = 'D:\Compass\compass-team-kickoff-aurora'
$McpPython = 'C:\Users\huikyole\AppData\Local\miniforge3\envs\Prithvi\python.exe'
$McpScript = Join-Path $CompassRepoRoot 'src\compass_aurora\mcp\server.py'
$McpPort = 8000
$McpLog = Join-Path $LogDirectory 'mcp-compass-prithvi.log'
$McpErrorLog = Join-Path $LogDirectory 'mcp-compass-prithvi.error.log'
$McpEnv = @{
  COMPASS_SITE_PROFILE  = Join-Path $CompassRepoRoot 'configs\sites\windows-prithvi.yaml'
  COMPASS_KNOWLEDGE_ROOT = Join-Path $CompassRepoRoot 'knowledge'
  COMPASS_RUNS_ROOT      = Join-Path $CompassRepoRoot 'runs'
}

function Get-EnvFilePort {
  # LibreChat resolves its port from process.env.PORT (api/server/index.js), and
  # dotenv does not overwrite variables already present in the environment. Read
  # the same value .env declares so our readiness checks target the right port.
  $fallback = 3080
  $envFile = Join-Path $Root '.env'
  if (-not (Test-Path $envFile)) {
    return $fallback
  }
  $match = Select-String -Path $envFile -Pattern '^\s*PORT\s*=\s*(\d+)' | Select-Object -Last 1
  if ($null -eq $match) {
    return $fallback
  }
  return [int] $match.Matches[0].Groups[1].Value
}

$LibreChatPort = Get-EnvFilePort

function Get-ListenerProcessId {
  param([int] $Port)

  $connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $connection) {
    return $null
  }
  return [int] $connection.OwningProcess
}

function Wait-ForPort {
  param([int] $Port, [bool] $Open, [int] $TimeoutSeconds)

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    $isOpen = $null -ne (Get-ListenerProcessId -Port $Port)
    if ($isOpen -eq $Open) {
      return $true
    }
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  return $false
}

function Stop-ProcessTree {
  param([Nullable[int]] $ProcessId)

  if ($null -eq $ProcessId -or $ProcessId -le 0) {
    return
  }
  if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
    return
  }
  try {
    & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
  } catch {
  }
}

function Read-State {
  if (-not (Test-Path $StatePath)) {
    return $null
  }
  try {
    return Get-Content -Raw $StatePath | ConvertFrom-Json
  } catch {
    Write-Warning "Ignoring invalid state file: $StatePath"
    return $null
  }
}

function Show-Status {
  $mongoProcessId = Get-ListenerProcessId -Port 27017
  $libreChatProcessId = Get-ListenerProcessId -Port $LibreChatPort
  $bridgeProcessId = Get-ListenerProcessId -Port $BridgePort

  if ($null -ne $mongoProcessId) {
    Write-Host "MongoDB:  running on port 27017 (PID $mongoProcessId)" -ForegroundColor Green
  } else {
    Write-Host 'MongoDB:  stopped' -ForegroundColor DarkGray
  }
  if ($null -ne $libreChatProcessId) {
    Write-Host "LibreChat: running at http://localhost:$LibreChatPort (PID $libreChatProcessId)" -ForegroundColor Green
  } else {
    Write-Host 'LibreChat: stopped' -ForegroundColor DarkGray
  }
  if ($null -ne $bridgeProcessId) {
    Write-Host "ADK bridge: running at http://localhost:$BridgePort (PID $bridgeProcessId)" -ForegroundColor Green
  } else {
    Write-Host 'ADK bridge: stopped' -ForegroundColor DarkGray
  }
  $mcpProcessId = Get-ListenerProcessId -Port $McpPort
  if ($null -ne $mcpProcessId) {
    Write-Host "COMPASS-Prithvi MCP: running at http://localhost:$McpPort/sse (PID $mcpProcessId)" -ForegroundColor Green
  } else {
    Write-Host 'COMPASS-Prithvi MCP: stopped' -ForegroundColor DarkGray
  }
}

function Start-Bridge {
  if ($null -ne (Get-ListenerProcessId -Port $BridgePort)) {
    Write-Host "ADK bridge is already running on port $BridgePort." -ForegroundColor Yellow
    return $null
  }
  if (-not (Test-Path $BridgeUvicorn) -or -not (Test-Path $BridgeDirectory)) {
    Write-Warning "ADK bridge not found (expected $BridgeUvicorn in $BridgeDirectory). Skipping."
    return $null
  }

  Write-Host 'Starting ADK bridge...'
  $bridgeLauncher = Start-Process -FilePath $BridgeUvicorn `
    -ArgumentList @('bridge_server:app', '--host', '0.0.0.0', '--port', "$BridgePort") `
    -WorkingDirectory $BridgeDirectory -WindowStyle Hidden `
    -RedirectStandardOutput $BridgeLog -RedirectStandardError $BridgeErrorLog -PassThru
  if (-not (Wait-ForPort -Port $BridgePort -Open $true -TimeoutSeconds 30)) {
    Stop-ProcessTree -ProcessId $bridgeLauncher.Id
    throw "ADK bridge did not start. See $BridgeErrorLog"
  }
  return $bridgeLauncher
}

function Stop-Bridge {
  param([Nullable[int]] $LauncherProcessId, [Nullable[int]] $ProcessId)

  if (($null -eq $LauncherProcessId -or $LauncherProcessId -le 0) -and $null -eq (Get-ListenerProcessId -Port $BridgePort)) {
    return
  }
  Write-Host 'Stopping ADK bridge...'
  Stop-ProcessTree -ProcessId $LauncherProcessId
  Stop-ProcessTree -ProcessId $ProcessId
  Stop-ProcessTree -ProcessId (Get-ListenerProcessId -Port $BridgePort)
}

function Start-Mcp {
  if ($null -ne (Get-ListenerProcessId -Port $McpPort)) {
    Write-Host "COMPASS-Prithvi MCP server is already running on port $McpPort." -ForegroundColor Yellow
    return $null
  }
  if (-not (Test-Path $McpPython) -or -not (Test-Path $McpScript)) {
    Write-Warning "COMPASS-Prithvi MCP server not found (expected $McpScript run by $McpPython). Skipping."
    return $null
  }

  Write-Host 'Starting COMPASS-Prithvi MCP server...'
  # Start-Process inherits the current process's env block; stash/restore around
  # the call the same way $env:PORT is handled below for LibreChat itself.
  $previousMcpEnv = @{}
  foreach ($key in $McpEnv.Keys) {
    $previousMcpEnv[$key] = [System.Environment]::GetEnvironmentVariable($key)
    [System.Environment]::SetEnvironmentVariable($key, $McpEnv[$key])
  }
  try {
    $mcpLauncher = Start-Process -FilePath $McpPython `
      -ArgumentList @($McpScript, '--transport', 'sse', '--host', '0.0.0.0', '--port', "$McpPort") `
      -WorkingDirectory $CompassRepoRoot -WindowStyle Hidden `
      -RedirectStandardOutput $McpLog -RedirectStandardError $McpErrorLog -PassThru
  } finally {
    foreach ($key in $McpEnv.Keys) {
      [System.Environment]::SetEnvironmentVariable($key, $previousMcpEnv[$key])
    }
  }
  if (-not (Wait-ForPort -Port $McpPort -Open $true -TimeoutSeconds 60)) {
    Stop-ProcessTree -ProcessId $mcpLauncher.Id
    throw "COMPASS-Prithvi MCP server did not start. See $McpErrorLog"
  }
  return $mcpLauncher
}

function Stop-Mcp {
  param([Nullable[int]] $LauncherProcessId, [Nullable[int]] $ProcessId)

  if (($null -eq $LauncherProcessId -or $LauncherProcessId -le 0) -and $null -eq (Get-ListenerProcessId -Port $McpPort)) {
    return
  }
  Write-Host 'Stopping COMPASS-Prithvi MCP server...'
  Stop-ProcessTree -ProcessId $LauncherProcessId
  Stop-ProcessTree -ProcessId $ProcessId
  Stop-ProcessTree -ProcessId (Get-ListenerProcessId -Port $McpPort)
}

function Start-LibreChat {
  if ($null -ne (Get-ListenerProcessId -Port $LibreChatPort)) {
    Write-Host 'LibreChat is already running.' -ForegroundColor Yellow
    Show-Status
    return
  }

  $requiredPaths = @(
    (Join-Path $Root '.env'),
    (Join-Path $Root 'node_modules'),
    (Join-Path $Root 'client\dist\index.html'),
    (Join-Path $Root 'scripts\local-mongodb.cjs')
  )
  $missingPaths = $requiredPaths | Where-Object { -not (Test-Path $_) }
  if ($missingPaths.Count -gt 0) {
    throw "Local setup is incomplete. Missing: $($missingPaths -join ', '). Run 'npm run smart-reinstall' and create .env first."
  }

  New-Item -ItemType Directory -Force -Path $LogDirectory, $RunDirectory | Out-Null
  $mongoLauncher = $null
  $mongoProcessId = Get-ListenerProcessId -Port 27017
  if ($null -eq $mongoProcessId) {
    Write-Host 'Starting local MongoDB...'
    $mongoLauncher = Start-Process -FilePath 'node.exe' `
      -ArgumentList (Join-Path $Root 'scripts\local-mongodb.cjs') `
      -WorkingDirectory $Root -WindowStyle Hidden `
      -RedirectStandardOutput $MongoLog -RedirectStandardError $MongoErrorLog -PassThru
    if (-not (Wait-ForPort -Port 27017 -Open $true -TimeoutSeconds 120)) {
      Stop-ProcessTree -ProcessId $mongoLauncher.Id
      throw "MongoDB did not start. See $MongoErrorLog"
    }
    $mongoProcessId = Get-ListenerProcessId -Port 27017
  } else {
    Write-Host "Using MongoDB already listening on port 27017 (PID $mongoProcessId)."
  }

  $bridgeLauncher = Start-Bridge
  # Before LibreChat: it connects to configured mcpServers during startup, so the
  # MCP server has to be listening or the server registers as unavailable.
  $mcpLauncher = Start-Mcp

  Write-Host "Starting LibreChat on port $LibreChatPort..."
  $npm = (Get-Command npm.cmd -ErrorAction Stop).Source
  # Pin PORT for the child: process.env.PORT beats .env, so a stray PORT inherited
  # from the caller's session would otherwise bind a different port than we poll,
  # and the readiness check below would kill a healthy server.
  $previousPort = $env:PORT
  $env:PORT = "$LibreChatPort"
  try {
    $libreChatLauncher = Start-Process -FilePath $npm -ArgumentList @('run', 'backend') `
      -WorkingDirectory $Root -WindowStyle Hidden `
      -RedirectStandardOutput $LibreChatLog -RedirectStandardError $LibreChatErrorLog -PassThru
  } finally {
    if ($null -eq $previousPort) {
      Remove-Item Env:\PORT -ErrorAction SilentlyContinue
    } else {
      $env:PORT = $previousPort
    }
  }
  if (-not (Wait-ForPort -Port $LibreChatPort -Open $true -TimeoutSeconds 45)) {
    Stop-ProcessTree -ProcessId $libreChatLauncher.Id
    if ($null -ne $mongoLauncher) {
      Stop-ProcessTree -ProcessId $mongoLauncher.Id
    }
    if ($null -ne $bridgeLauncher) {
      Stop-ProcessTree -ProcessId $bridgeLauncher.Id
    }
    if ($null -ne $mcpLauncher) {
      Stop-ProcessTree -ProcessId $mcpLauncher.Id
    }
    throw "LibreChat did not start. See $LibreChatErrorLog and $LibreChatLog"
  }

  [ordered]@{
    mongoLauncherProcessId = if ($null -eq $mongoLauncher) { 0 } else { $mongoLauncher.Id }
    mongoProcessId = if ($null -eq $mongoLauncher) { 0 } else { $mongoProcessId }
    bridgeLauncherProcessId = if ($null -eq $bridgeLauncher) { 0 } else { $bridgeLauncher.Id }
    bridgeProcessId = if ($null -eq $bridgeLauncher) { 0 } else { Get-ListenerProcessId -Port $BridgePort }
    mcpLauncherProcessId = if ($null -eq $mcpLauncher) { 0 } else { $mcpLauncher.Id }
    mcpProcessId = if ($null -eq $mcpLauncher) { 0 } else { Get-ListenerProcessId -Port $McpPort }
    libreChatLauncherProcessId = $libreChatLauncher.Id
    libreChatProcessId = Get-ListenerProcessId -Port $LibreChatPort
    startedAt = (Get-Date).ToString('o')
  } | ConvertTo-Json | Set-Content -Path $StatePath
  Write-Host "LibreChat is ready at http://localhost:$LibreChatPort" -ForegroundColor Green
  Write-Host "COMPASS-Prithvi MCP tools at http://localhost:$McpPort/sse" -ForegroundColor Green
}

function Stop-LibreChat {
  $state = Read-State
  if ($null -eq $state) {
    Write-Host 'No launcher-managed LibreChat instance was found.' -ForegroundColor Yellow
    Show-Status
    return
  }

  Write-Host 'Stopping LibreChat...'
  Stop-ProcessTree -ProcessId $state.libreChatLauncherProcessId
  Stop-ProcessTree -ProcessId $state.libreChatProcessId
  Stop-Bridge -LauncherProcessId $state.bridgeLauncherProcessId -ProcessId $state.bridgeProcessId
  Stop-Mcp -LauncherProcessId $state.mcpLauncherProcessId -ProcessId $state.mcpProcessId
  if ($state.mongoLauncherProcessId -gt 0) {
    Write-Host 'Stopping local MongoDB...'
    Stop-ProcessTree -ProcessId $state.mongoLauncherProcessId
    Stop-ProcessTree -ProcessId $state.mongoProcessId
  }

  Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
  Wait-ForPort -Port $LibreChatPort -Open $false -TimeoutSeconds 10 | Out-Null
  Write-Host 'LibreChat stopped.' -ForegroundColor Green
}

switch ($Action) {
  'start' { Start-LibreChat }
  'stop' { Stop-LibreChat }
  'restart' {
    Stop-LibreChat
    Start-LibreChat
  }
  'status' { Show-Status }
}
