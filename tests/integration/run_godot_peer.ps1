param(
    [Parameter(Mandatory = $true)][string]$GodotBinary,
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [Parameter(Mandatory = $true)][string]$ScenePath,
    [Parameter(Mandatory = $true)][string]$Role,
    [Parameter(Mandatory = $true)][string]$BottomRole,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [Parameter(Mandatory = $true)][int]$LatencyMs,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$TracePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$PidPath,
    [switch]$Inspect
)

$nativeMethods = @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetErrorMode(uint mode);
"@
Add-Type -MemberDefinition $nativeMethods -Name NativeErrorMode -Namespace FrenslopTests

# Codex and some CI shells expose both Path and PATH. Windows PowerShell's
# Start-Process treats those as duplicate dictionary keys, so normalize them.
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
Remove-Item Env:Path -ErrorAction SilentlyContinue
$env:Path = "$machinePath;$userPath"
$env:NETFOX_NO_AUTOCONNECT = '1'

$previousErrorMode = [FrenslopTests.NativeErrorMode]::SetErrorMode(0x0002)
try {
    $arguments = @(
        '--disable-crash-handler',
        '--max-fps', '60',
        '--log-file', $OutputPath,
        '--path', $ProjectPath,
        $ScenePath,
        '--',
        "--integration-role=$Role",
        "--integration-bottom=$BottomRole",
        "--integration-scenario=$Scenario",
        "--integration-inspect=$($Inspect.IsPresent.ToString().ToLowerInvariant())",
        "--integration-port=$Port",
        "--integration-latency-ms=$LatencyMs",
        "--integration-result-file=$TracePath"
    )
    if (-not $Inspect.IsPresent) {
        $arguments = @('--headless') + $arguments
    }
    $startParameters = @{
        FilePath = $GodotBinary
        ArgumentList = $arguments
        PassThru = $true
        WindowStyle = 'Hidden'
    }
    if ($Inspect.IsPresent) {
        $startParameters.WindowStyle = 'Normal'
    }
    $godot = Start-Process @startParameters
    [IO.File]::WriteAllText($PidPath, [string]$godot.Id)

    $exited = $godot.WaitForExit(10000)
    if (-not $exited) {
        Stop-Process -Id $godot.Id -Force -ErrorAction SilentlyContinue
        $godot.WaitForExit()
        exit 124
    }
    if ($null -eq $godot.ExitCode) {
        exit 125
    }
    exit $godot.ExitCode
}
finally {
    [void][FrenslopTests.NativeErrorMode]::SetErrorMode($previousErrorMode)
}
