param(
    [string]$GodotBinary = $env:GODOT_BIN,
    [string]$PythonBinary = 'python'
)

if ([string]::IsNullOrWhiteSpace($GodotBinary) -or -not (Test-Path -LiteralPath $GodotBinary)) {
    Write-Error 'Set GODOT_BIN or pass -GodotBinary with the concrete Godot tools executable.'
    exit 2
}

$env:GODOT_BIN = $GodotBinary
& $PythonBinary -m pytest (Join-Path $PSScriptRoot 'integration\test_godot_regressions.py')
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $PythonBinary -m pytest (Join-Path $PSScriptRoot 'integration\test_network_rollback_riding.py')
exit $LASTEXITCODE
