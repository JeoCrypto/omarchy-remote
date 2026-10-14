# omarchy-remote: developed by JeoCrypto
# Keeps this PC reachable while it is plugged in:
#   - Tailscale "Run unattended" (stays on Tailscale even when nobody is signed in)
#   - no sleep and no hibernate on AC power (battery settings are left alone)
# The original timeouts are saved in %USERPROFILE%\.omarchy-remote-power-original.txt
# To undo the power part:  powercfg /change standby-timeout-ac <minutes>; powercfg /change hibernate-timeout-ac <minutes>
$ErrorActionPreference = 'Stop'

$ts = (Get-Command tailscale -ErrorAction SilentlyContinue).Source
if (-not $ts) { $ts = 'C:\Program Files\Tailscale\tailscale.exe' }
if (Test-Path $ts) {
  if (-not ((& $ts debug prefs | ConvertFrom-Json).ForceDaemon)) { & $ts set --unattended | Out-Null }
  "Tailscale unattended : $((& $ts debug prefs | ConvertFrom-Json).ForceDaemon)"
} else { "Tailscale not found, skipped" }

# AC timeout in seconds, read without depending on the Windows language
function Get-AcSeconds($setting) {
  $hex = powercfg /q SCHEME_CURRENT SUB_SLEEP $setting | Select-String '0x[0-9a-fA-F]{8}\s*$' | ForEach-Object { $_.Matches[0].Value.Trim() }
  if ($hex.Count -ge 2) { [Convert]::ToInt32($hex[$hex.Count - 2].Substring(2), 16) } else { -1 }
}
$stand = Get-AcSeconds STANDBYIDLE
$hib   = Get-AcSeconds HIBERNATEIDLE
$backup = Join-Path $env:USERPROFILE '.omarchy-remote-power-original.txt'
if (-not (Test-Path $backup)) { "standby_ac_seconds=$stand`nhibernate_ac_seconds=$hib" | Set-Content $backup }
"Before (AC, seconds)  : sleep=$stand hibernate=$hib   (0 = never)"

powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0   | Out-Null
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
powercfg /setactive SCHEME_CURRENT | Out-Null

"After  (AC, seconds)  : sleep=$(Get-AcSeconds STANDBYIDLE) hibernate=$(Get-AcSeconds HIBERNATEIDLE)"
"Battery settings      : unchanged"
"Original values saved : $backup"
