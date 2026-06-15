# Source-invariant static verification for ClaudeTui.ps1 transaction repair.
# Reads the source file and verifies code patterns. Does NOT execute any function.
# Does NOT mutate agents.json or start any process.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ver2 = "F:\AI_project\Claude_worker_ver2"
$tuiScript = Join-Path $ver2 "scripts\ClaudeTui.ps1"
$schemaPath = Join-Path $ver2 "docs\agents-json-schema.md"

$script:FailCount = 0

function Write-Pass($Msg) { Write-Host "  PASS: $Msg" -ForegroundColor Green }
function Write-Fail($Msg) { Write-Host "  FAIL: $Msg" -ForegroundColor Red; $script:FailCount++ }
function Write-Header($N) { Write-Host "`n==== TEST: $N ====" -ForegroundColor Cyan }

$src = Get-Content $tuiScript -Raw
Write-Host "Source-invariant verification of ClaudeTui.ps1 ($($src.Length) chars)"

# =====================================================================
# TEST 1: No Save-Agents before _DoLaunch in Invoke-Send new-agent path
# =====================================================================
Write-Header "1: Invoke-Send new-agent path - no Save-Agents before _DoLaunch"
$block = ""
if ($src -match 'function Invoke-Send \{([\s\S]*?)\n\}(?=\s*\nfunction|\s*\n#|\s*\Z)') { $block = $Matches[1] }
if ($block -match 'if \(-not \$found\)\s*\{([^}]*)_DoLaunch') {
  if ($Matches[1] -notmatch 'Save-Agents') { Write-Pass "no Save-Agents before _DoLaunch" }
  else { Write-Fail "Save-Agents found before _DoLaunch" }
} else { Write-Fail "could not extract code path" }

# =====================================================================
# TEST 2: No Save-Agents before _DoLaunch in Invoke-SendInternal new-agent path
# =====================================================================
Write-Header "2: Invoke-SendInternal new-agent path - no Save-Agents before _DoLaunch"
$block2 = ""
if ($src -match 'function Invoke-SendInternal \{([\s\S]*?)\n\}(?=\s*\nfunction|\s*\n#|\s*\Z)') { $block2 = $Matches[1] }
if ($block2 -match 'if \(-not \$found\)\s*\{([^}]*)_DoLaunch') {
  if ($Matches[1] -notmatch 'Save-Agents') { Write-Pass "no Save-Agents before _DoLaunch" }
  else { Write-Fail "Save-Agents found before _DoLaunch" }
} else { Write-Fail "could not extract code path" }

# =====================================================================
# TEST 3: _DoLaunch uses throw (not exit) for launch failures
# =====================================================================
Write-Header "3: _DoLaunch uses throw (not exit) for launch failures"
if ($src -match 'throw "Send-ClaudeCommand failed') { Write-Pass "Send-ClaudeCommand non-zero -> throw" }
else { Write-Fail "Send-ClaudeCommand non-zero exit should throw" }
if ($src -match 'throw "Failed to parse launch JSON') { Write-Pass "JSON parse failure -> throw" }
else { Write-Fail "JSON parse failure should throw" }
if ($src -match 'Write-Host \$outStr; exit') { Write-Fail "bare exit still present in error paths" }
else { Write-Pass "no bare exit in error paths" }

# =====================================================================
# TEST 4: _DoLaunch atomic single Save-Agents
# =====================================================================
Write-Header "4: _DoLaunch - single atomic Save-Agents after setting all fields"
$dlBlock = ""
if ($src -match 'function _DoLaunch \{([\s\S]*?)\n\}(?=\s*\nfunction|\s*\n#|\s*\Z)') { $dlBlock = $Matches[1] }
if ($dlBlock) {
  $saveCount = ([regex]::Matches($dlBlock, 'Save-Agents')).Count
  if ($saveCount -eq 1) { Write-Pass "exactly 1 Save-Agents in _DoLaunch" }
  else { Write-Fail "$saveCount Save-Agents calls (expected 1)" }
} else { Write-Fail "could not extract _DoLaunch" }

# =====================================================================
# TEST 5: pending_task preserves inject_normal
# =====================================================================
Write-Header "5: pending_task includes inject_normal"
if ($src -match 'inject_normal = if \(\$InjectNormal\) \{ \$InjectNormal \} else \{ "" \}') {
  Write-Pass "busy path writes inject_normal to pending_task"
} else { Write-Fail "busy path missing inject_normal" }
if ($src -match 'inject_normal\s*=\s*if\s*\(\s*\$InjectNormal\s*\)') {
  Write-Pass "W-branch writes inject_normal to pending_task"
} else { Write-Fail "W-branch missing inject_normal" }

# =====================================================================
# TEST 6: Sync-DoneToManager reads inject_normal
# =====================================================================
Write-Header "6: Sync-DoneToManager reads and passes inject_normal"
if ($src -match 'pendingInjectNormal') { Write-Pass "reads inject_normal from pending_task" }
else { Write-Fail "missing inject_normal read" }
if ($src -match '-InjectNormal\s+\$pendingInjectNormal') { Write-Pass "passes -InjectNormal to Invoke-SendInternal" }
else { Write-Fail "missing -InjectNormal pass" }

# =====================================================================
# TEST 7: Auto-continue defers pending_task clear until AFTER launch success
# =====================================================================
Write-Header "7: Auto-continue defers pending_task clear until after launch success"
$sdmBlock = ""
if ($src -match 'function Sync-DoneToManager \{([\s\S]*?)\n\}(?=\s*\nfunction|\s*\n#|\s*\Z)') { $sdmBlock = $Matches[1] }
$acBlock = ""
if ($sdmBlock -match 'foreach \(\$as in \$autoStarts\) \{([\s\S]*?)\n    \}(?=\s*\n\}|\s*\Z)') { $acBlock = $Matches[1] }
if (-not $acBlock -and $sdmBlock -match 'foreach.*autoStarts.*\{([\s\S]*?)\}\s*\n\}') { $acBlock = $Matches[1] }
if ($acBlock) {
  $invokePos = $acBlock.IndexOf('Invoke-SendInternal')
  $clearPos  = $acBlock.IndexOf('pending_task = $null')
  if ($invokePos -ge 0) {
    if ($clearPos -lt 0 -or $clearPos -gt $invokePos) {
      Write-Pass "pending_task cleared only AFTER Invoke-SendInternal returns"
    } else { Write-Fail "pending_task cleared BEFORE Invoke-SendInternal (race hazard)" }
  } else { Write-Fail "Invoke-SendInternal call not found in auto-continue loop" }
} else { Write-Fail "could not extract auto-continue foreach block" }

# =====================================================================
# TEST 8: Auto-continue catch block preserves pending_task on failure
# =====================================================================
Write-Header "8: Auto-continue failure preserves pending_task (catch block)"
if ($src -match 'pending_task preserved') { Write-Pass "catch block logs pending_task preserved" }
else { Write-Fail "catch block missing preservation log" }
if ($src -match 'pending_task_error') { Write-Pass "records pending_task_error on failure" }
else { Write-Fail "missing pending_task_error diagnostic" }

# =====================================================================
# TEST 9: Invoke-AgentDetail uses ConvertTo-Json for pending_task
# =====================================================================
Write-Header "9: Invoke-AgentDetail displays pending_task via ConvertTo-Json"
if ($src -match 'pending_task \| ConvertTo-Json') { Write-Pass "pending_task uses ConvertTo-Json" }
else { Write-Fail "pending_task not using ConvertTo-Json" }
if ($src -match 'current_task \| ConvertTo-Json') { Write-Pass "current_task also uses ConvertTo-Json" }
else { Write-Fail "current_task missing ConvertTo-Json" }

# =====================================================================
# TEST 10: No unused mock files in tests/
# =====================================================================
Write-Header "10: tests/ directory - no unused mock files"
$testsDir = Join-Path $ver2 "tests"
$allFiles = @(Get-ChildItem $testsDir -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$mockFiles = @($allFiles | Where-Object { $_ -match '^mock-(fail|success)' })
if ($mockFiles.Count -eq 0) { Write-Pass "no unused mock scripts (mock-fail-*, mock-success-* removed)" }
else { Write-Fail "found unused mock files: $($mockFiles -join ', ')" }

# =====================================================================
# TEST 11: No missing-newline }function formatting issue
# =====================================================================
Write-Header "11: No }function missing-newline formatting issue"
if ($src -match '}function') { Write-Fail "found }function (missing newline)" }
else { Write-Pass "no }function formatting issue" }

# =====================================================================
# TEST 12: Explicit InjectNormal parameter flow
# =====================================================================
Write-Header "12: _DoLaunch + Invoke-SendInternal have explicit InjectNormal params"
$isiBlock = ""
if ($src -match 'function Invoke-SendInternal \{([\s\S]*?)\n\}(?=\s*\nfunction|\s*\n#|\s*\Z)') { $isiBlock = $Matches[1] }
if ($isiBlock -match 'string\]\s*\$InjectNormal') { Write-Pass "Invoke-SendInternal has InjectNormal parameter" }
else { Write-Fail "Invoke-SendInternal missing InjectNormal parameter" }
if ($dlBlock -and $dlBlock -match '\$InjectNormal') { Write-Pass "_DoLaunch references InjectNormal parameter" }
else { Write-Fail "_DoLaunch missing InjectNormal references" }
$dlCallCount = ([regex]::Matches($src, '_DoLaunch -AgentId')).Count
$dlInjectCount = ([regex]::Matches($src, '_DoLaunch[\s\S]{0,200}?-InjectNormal')).Count
if ($dlCallCount -eq $dlInjectCount) { Write-Pass "All $dlCallCount _DoLaunch calls pass -InjectNormal" }
else { Write-Fail "_DoLaunch: $dlCallCount calls, $dlInjectCount pass -InjectNormal" }

# =====================================================================
# TEST 13: current_task records inject_normal
# =====================================================================
Write-Header "13: current_task records inject_normal for diagnostics"
if ($src -match 'current_task = \[ordered\]@\{[\s\S]{0,300}inject_normal') { Write-Pass "current_task includes inject_normal" }
else { Write-Fail "current_task missing inject_normal" }

# =====================================================================
# TEST 14: schema doc synchronized
# =====================================================================
Write-Header "14: agents-json-schema.md synchronized"
$schemaContent = Get-Content $schemaPath -Raw
if ($schemaContent -match 'pending_task.*inject_normal') { Write-Pass "pending_task schema: inject_normal present" }
else { Write-Fail "pending_task schema: inject_normal missing" }
if ($schemaContent -match 'Transaction Rules') { Write-Pass "Transaction Rules section present" }
else { Write-Fail "Transaction Rules section missing" }
if ($schemaContent -match 'InjectNormal Queue Preservation') { Write-Pass "InjectNormal Queue Preservation section present" }
else { Write-Fail "InjectNormal Queue Preservation section missing" }

# =====================================================================
# TEST 15: Send-ClaudeCommand.ps1 has top-level InjectNormal parameter
# =====================================================================
Write-Header "15: Send-ClaudeCommand.ps1 declares InjectNormal parameter"
$sendSrc = Get-Content (Join-Path $ver2 "scripts\Send-ClaudeCommand.ps1") -Raw
if ($sendSrc -match '\[string\]\$InjectNormal\s*=\s*""') { Write-Pass "Send-ClaudeCommand.ps1 has InjectNormal param at top level" }
else { Write-Fail "Send-ClaudeCommand.ps1 missing InjectNormal param" }

# =====================================================================
# TEST 16: Build-WorkerPrompt reads and injects normal_prompt content
# =====================================================================
Write-Header "16: Build-WorkerPrompt injects normal_prompt when InjectNormal non-empty"
if ($sendSrc -match 'INJECTED NORMAL PROMPT:') { Write-Pass "InjectNormal marker present in Build-WorkerPrompt" }
else { Write-Fail "missing InjectNormal marker in Build-WorkerPrompt" }
if ($sendSrc -match 'prompt_templates\\role\\\$Role\\normal_prompt\\\$InjectNormal') { Write-Pass "normal_prompt path constructed correctly" }
else { Write-Fail "normal_prompt path not constructed" }
if ($sendSrc -match 'throw "InjectNormal error:') { Write-Pass "throws on missing normal prompt file" }
else { Write-Fail "missing throw for absent normal prompt" }
if ($sendSrc -match '\$injectBlock') { Write-Pass "injectBlock variable used for controlled injection" }
else { Write-Fail "missing injectBlock variable" }

# =====================================================================
# TEST 17: Build-WorkerPrompt no-op when InjectNormal is empty
# =====================================================================
Write-Header "17: Build-WorkerPrompt does not inject when InjectNormal is empty"
if ($sendSrc -match 'if \(\$InjectNormal\) \{') { Write-Pass "InjectNormal gated behind if-condition" }
else { Write-Fail "InjectNormal not conditionally gated" }

# =====================================================================
# TEST 18: Invoke-AgentDetail displays pending_task_error
# =====================================================================
Write-Header "18: Invoke-AgentDetail displays pending_task_error"
if ($src -match '--- Pending Task Error ---') { Write-Pass "pending_task_error section header present" }
else { Write-Fail "pending_task_error section header missing" }
# Verify the display code immediately follows the section header
$iadBlock = ""
if ($src -match 'function Invoke-AgentDetail \{([\s\S]*?)\n\}(?=\s*\nfunction|\s*\n#|\s*\Z)') { $iadBlock = $Matches[1] }
if ($iadBlock -match 'pending_task_error') {
    if ($iadBlock -match 'Write-Host.*pending_task_error') { Write-Pass "pending_task_error value written via Write-Host" }
    else { Write-Fail "pending_task_error Write-Host block missing" }
} else { Write-Fail "pending_task_error block not found in Invoke-AgentDetail" }

# =====================================================================
# TEST 19: Normalize-AgentEntry includes pending_task_error
# =====================================================================
Write-Header "19: Normalize-AgentEntry normalizes pending_task_error"
if ($src -match 'Ensure-EntryProp.*pending_task_error') { Write-Pass "pending_task_error normalized" }
else { Write-Fail "pending_task_error not in Normalize-AgentEntry" }

# =====================================================================
# Summary
# =====================================================================
Write-Host "`n========================================" -ForegroundColor Cyan
if ($script:FailCount -gt 0) {
  Write-Host "  RESULT: $($script:FailCount) FAILURE(S)" -ForegroundColor Red
} else {
  Write-Host "  RESULT: ALL PASS" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Cyan

exit $script:FailCount