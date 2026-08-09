param(
    [string]$GodotBinary = $env:GODOT_BIN,
    [ValidateSet('host', 'client')][string]$BottomRole = 'client',
    [ValidateSet('stationary', 'bottom_jump', 'platform_ride_up')][string]$Scenario = 'stationary',
    [ValidateRange(0, 1000)][int]$LatencyMs = 50
)

if ([string]::IsNullOrWhiteSpace($GodotBinary) -or -not (Test-Path -LiteralPath $GodotBinary)) {
    Write-Error 'Set GODOT_BIN or pass -GodotBinary with the concrete Godot tools executable.'
    exit 2
}

$peerRunner = Join-Path $PSScriptRoot 'integration\run_godot_peer.ps1'
$projectPath = Split-Path -Parent $PSScriptRoot
$scenePath = 'res://tests/production_e2e_bootstrap.tscn'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$firstSocket = [System.Net.Sockets.UdpClient]::new(0)
$port = ([System.Net.IPEndPoint]$firstSocket.Client.LocalEndPoint).Port
$firstSocket.Dispose()
if ($port -ge 65535) {
    Write-Error 'Could not reserve a usable adjacent UDP port pair.'
    exit 2
}

$runId = "$PID-$port"
$tempPath = [IO.Path]::GetTempPath()
$hostLog = Join-Path $tempPath "frenslop-inspect-host-$runId.log"
$hostTrace = Join-Path $tempPath "frenslop-inspect-host-$runId.trace"
$hostPid = Join-Path $tempPath "frenslop-inspect-host-$runId.pid"
$clientLog = Join-Path $tempPath "frenslop-inspect-client-$runId.log"
$clientTrace = Join-Path $tempPath "frenslop-inspect-client-$runId.trace"
$clientPid = Join-Path $tempPath "frenslop-inspect-client-$runId.pid"
$artifacts = @($hostLog, $hostTrace, $hostPid, $clientLog, $clientTrace, $clientPid)
foreach ($artifact in $artifacts) {
    Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
}

function New-PeerArguments {
    param(
        [string]$Role,
        [string]$LogPath,
        [string]$TracePath,
        [string]$PidPath
    )
    return @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $peerRunner),
        '-GodotBinary', ('"{0}"' -f $GodotBinary),
        '-ProjectPath', ('"{0}"' -f $projectPath),
        '-ScenePath', $scenePath,
        '-Role', $Role,
        '-BottomRole', $BottomRole,
        '-Scenario', $Scenario,
        '-LatencyMs', [string]$LatencyMs,
        '-Port', [string]$port,
        '-TracePath', ('"{0}"' -f $TracePath),
        '-OutputPath', ('"{0}"' -f $LogPath),
        '-PidPath', ('"{0}"' -f $PidPath),
        '-Inspect'
    )
}

function Stop-ExactPeer {
    param(
        [System.Diagnostics.Process]$Wrapper,
        [string]$PidPath
    )
    if (Test-Path -LiteralPath $PidPath) {
        $godotPid = 0
        [void][int]::TryParse((Get-Content -Raw -LiteralPath $PidPath).Trim(), [ref]$godotPid)
        if ($godotPid -gt 0 -and (Get-Process -Id $godotPid -ErrorAction SilentlyContinue)) {
            $godotProcess = Get-Process -Id $godotPid -ErrorAction SilentlyContinue
            Stop-Process -Id $godotPid -Force -ErrorAction SilentlyContinue
            if ($null -ne $godotProcess) {
                [void]$godotProcess.WaitForExit(1000)
            }
        }
    }
    if ($null -ne $Wrapper -and -not $Wrapper.HasExited) {
        Stop-Process -Id $Wrapper.Id -Force -ErrorAction SilentlyContinue
        $Wrapper.WaitForExit()
    }
}

$hostWrapper = $null
$clientWrapper = $null
try {
    Write-Host "Launching visible $Scenario inspection: bottom=$BottomRole, latency=${LatencyMs}ms one-way"
    $hostWrapper = Start-Process `
        -FilePath $powershell `
        -ArgumentList (New-PeerArguments 'host' $hostLog $hostTrace $hostPid) `
        -PassThru `
        -WindowStyle Hidden

    $readyDeadline = [DateTime]::UtcNow.AddSeconds(3)
    while ([DateTime]::UtcNow -lt $readyDeadline) {
        if ((Test-Path -LiteralPath $hostTrace) -and
            ((Get-Content -Raw -LiteralPath $hostTrace) -match 'PEER_READY')) {
            break
        }
        if ($hostWrapper.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if ($hostWrapper.HasExited -or -not (Test-Path -LiteralPath $hostTrace) -or
        -not ((Get-Content -Raw -LiteralPath $hostTrace) -match 'PEER_READY')) {
        throw 'Host did not become ready for visual inspection.'
    }

    $clientWrapper = Start-Process `
        -FilePath $powershell `
        -ArgumentList (New-PeerArguments 'client' $clientLog $clientTrace $clientPid) `
        -PassThru `
        -WindowStyle Hidden

    $deadline = [DateTime]::UtcNow.AddSeconds(11)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($hostWrapper.HasExited -and $clientWrapper.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if (-not $hostWrapper.HasExited -or -not $clientWrapper.HasExited) {
        throw 'Visible integration inspection exceeded its bounded runtime.'
    }

    Write-Host 'Host trace:'
    Get-Content -LiteralPath $hostTrace -ErrorAction SilentlyContinue
    if ($hostWrapper.ExitCode -ne 0 -or $clientWrapper.ExitCode -ne 0) {
        Write-Host 'Host log:'
        Get-Content -LiteralPath $hostLog -ErrorAction SilentlyContinue
        Write-Host 'Client log:'
        Get-Content -LiteralPath $clientLog -ErrorAction SilentlyContinue
        exit 1
    }
}
catch {
    Write-Error $_
    exit 1
}
finally {
    Stop-ExactPeer $hostWrapper $hostPid
    Stop-ExactPeer $clientWrapper $clientPid
    foreach ($artifact in $artifacts) {
        Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
    }
}
