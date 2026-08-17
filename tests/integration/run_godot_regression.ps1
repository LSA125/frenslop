param(
    [Parameter(Mandatory = $true)][string]$GodotBinary,
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet('riding', 'rapier_manual', 'carrier_velocity', 'equip_combat')]
    [string]$Regression,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$PidPath
)

$nativeMethods = @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetErrorMode(uint mode);
"@
Add-Type -MemberDefinition $nativeMethods -Name NativeErrorMode -Namespace FrenslopTests

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
Remove-Item Env:Path -ErrorAction SilentlyContinue
$env:Path = "$machinePath;$userPath"
$env:NETFOX_NO_AUTOCONNECT = '1'

$scenePath = switch ($Regression) {
    'riding' { 'res://tests/rollback_riding_regression.tscn' }
    'rapier_manual' { 'res://tests/rapier_collision_regression.tscn' }
    'carrier_velocity' { 'res://tests/carrier_velocity_regression.tscn' }
    'equip_combat' { 'res://tests/equip_combat_regression.tscn' }
}

$arguments = @(
    '--headless',
    '--disable-crash-handler',
    '--log-file', $OutputPath,
    '--path', $ProjectPath,
    $scenePath
)
if ($Regression -eq 'rapier_manual') {
    $arguments += @('--', '--manual-driver')
}

$previousErrorMode = [FrenslopTests.NativeErrorMode]::SetErrorMode(0x0002)
try {
    $godot = Start-Process `
        -FilePath $GodotBinary `
        -ArgumentList $arguments `
        -PassThru `
        -WindowStyle Hidden
    [IO.File]::WriteAllText($PidPath, [string]$godot.Id)

    $exited = $godot.WaitForExit(10000)
    if (-not $exited) {
        Stop-Process -Id $godot.Id -Force -ErrorAction SilentlyContinue
        $godot.WaitForExit()
        exit 124
    }
    exit $godot.ExitCode
}
finally {
    [void][FrenslopTests.NativeErrorMode]::SetErrorMode($previousErrorMode)
}
