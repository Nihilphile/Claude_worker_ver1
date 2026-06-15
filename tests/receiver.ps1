# Receiver: logs all received arguments for fidelity testing
$logPath = Join-Path $PSScriptRoot "receiver-args.txt"
$timestamp = Get-Date -Format "o"
$argDump = @()
$argDump += "=== $timestamp ==="
$argDump += "ArgCount: $($args.Count)"
for ($i = 0; $i -lt $args.Count; $i++) {
    $argDump += "  [$i]: [$($args[$i])]"
}
$argDump -join "`n" | Out-File $logPath -Encoding UTF8
