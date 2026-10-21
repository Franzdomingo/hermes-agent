# Journey-owned mock and ordinary window close, shared by source and MSIX drivers.
# Callers supply a checkout-provisioned Node; never resolve tooling from OLD.
function Start-DesktopJourneyMock([string]$Node, [string]$Assets, [string]$Work, [string]$HermesHome, [string]$Out) {
    New-Item -ItemType Directory -Path $Out -Force | Out-Null
    $urlFile = Join-Path $Work 'chat-mock-url'
    # An earlier step's mock died with that step; the detached gateway did not, and it
    # kept the provider URL it read at boot. Rebind that URL's port (see mock-provider.mjs).
    $priorUrl = if (Test-Path -LiteralPath $urlFile) { (Get-Content -LiteralPath $urlFile -Raw).Trim() } else { '' }
    Remove-Item -LiteralPath $urlFile -Force -ErrorAction SilentlyContinue
    $mockArgs = @(('"' + (Join-Path $Assets 'mock-provider.mjs') + '"'), ('"' + $urlFile + '"'))
    if ($priorUrl) { $mockArgs += ('"' + $priorUrl + '"') }
    $mock = Start-Process -FilePath $Node -ArgumentList $mockArgs `
        -PassThru -RedirectStandardOutput (Join-Path $Out 'chat-mock.log') -RedirectStandardError (Join-Path $Out 'chat-mock-error.log')
    try {
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $urlFile)) {
            if ($mock.HasExited -or (Get-Date) -ge $deadline) { throw 'Desktop mock did not become ready' }
            Start-Sleep -Milliseconds 200
        }
        $env:HERMES_E2E_MOCK_URL = (Get-Content -LiteralPath $urlFile -Raw).Trim()
        Invoke-RestMethod -Uri "$env:HERMES_E2E_MOCK_URL/__e2e__/prompts" -TimeoutSec 5 | Out-Null
        $configWriter = [IO.Path]::GetFullPath((Join-Path $Assets '..\..\..\tests-js\scripts\mock-provider-config.ts'))
        & $Node $configWriter $HermesHome $env:HERMES_E2E_MOCK_URL
        if ($LASTEXITCODE -ne 0) { throw 'Desktop mock configuration failed' }
        return $mock
    } catch {
        if (-not $mock.HasExited) { Stop-Process -Id $mock.Id -ErrorAction SilentlyContinue }
        throw
    }
}

# The Actions runner holds every step process in a job object that refuses
# CREATE_BREAKAWAY_FROM_JOB, and Hermes deliberately refuses to start a gateway it
# cannot detach (gateway_runtime_start.py::spawn_unmanaged_gateway). A user's
# Explorer/Start-menu launch is in no such job, so a desktop checkpoint runs the way
# that launch does: from a one-shot interactive Scheduled Task (Task Scheduler starts
# it outside the runner's job, as it does Hermes's own gateway task), with this
# step's environment, cwd and arguments replayed from a spec file. Returns the exit code.
function Invoke-OutsideRunnerJob([string]$Name, [string]$Work, [string]$Exe, [string[]]$Arguments, [int]$TimeoutMinutes = 45) {
    $dir = Join-Path $Work "outside-job-$Name"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $spec = Join-Path $dir 'spec.json'
    $log = Join-Path $dir 'output.log'
    $exitFile = Join-Path $dir 'exit-code'
    Remove-Item -LiteralPath $log, $exitFile -Force -ErrorAction SilentlyContinue
    $environment = [ordered]@{}
    Get-ChildItem Env: | ForEach-Object { $environment[$_.Name] = $_.Value }
    [ordered]@{ exe = $Exe; args = @($Arguments); cwd = (Get-Location).ProviderPath; env = $environment; log = $log; exit = $exitFile } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $spec -Encoding UTF8
    $wrapper = Join-Path $dir 'run.ps1'
    @'
param([string]$SpecPath)
$ErrorActionPreference = 'Continue'
$code = 99
$spec = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json
# Node writes UTF-8 into a pipe; decode it as such, not as the OEM code page. Cosmetic,
# and a session without a console rejects it, so a failure here must not fail the run.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
try {
    foreach ($entry in $spec.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, 'Process') }
    Set-Location -LiteralPath $spec.cwd
    & $spec.exe @($spec.args) 2>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $spec.log -Encoding UTF8
    $code = $LASTEXITCODE
} catch {
    "outside-job wrapper failed: $_" | Add-Content -LiteralPath $spec.log -Encoding UTF8
} finally {
    Set-Content -LiteralPath $spec.exit -Value $code -Encoding ascii
}
'@ | Set-Content -LiteralPath $wrapper -Encoding UTF8
    # The same PowerShell as this step, so native argument passing matches a direct call.
    $shell = (Get-Process -Id $PID).Path
    $taskName = 'HermesE2E-{0}-{1}' -f ($Name -replace '[^A-Za-z0-9_.-]', '-'), $PID
    $action = New-ScheduledTaskAction -Execute $shell `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`" -SpecPath `"$spec`""
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($TimeoutMinutes + 5)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName | Out-Null
        $started = Get-Date
        $deadline = $started.AddMinutes($TimeoutMinutes)
        while (-not (Test-Path -LiteralPath $exitFile)) {
            if ((Get-Date) -ge $deadline) {
                Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                throw "Outside-job run '$Name' did not finish within $TimeoutMinutes minutes"
            }
            # A wrapper that never started (bad principal, no session) leaves no exit file; fail now, not at the deadline.
            $task = Get-ScheduledTask -TaskName $taskName
            if ($task.State -notin @('Running', 'Queued') -and (Get-Date) -ge $started.AddSeconds(30) -and -not (Test-Path -LiteralPath $exitFile)) {
                $result = (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
                throw ("Outside-job run '{0}' ended without an exit code (task state {1}, last result 0x{2:X8})" -f $Name, $task.State, $result)
            }
            Start-Sleep -Seconds 2
        }
    } finally {
        Write-Host "--- outside-job '$Name' output ($log) ---"
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Encoding UTF8 | ForEach-Object { Write-Host $_ } }
        Write-Host "--- end outside-job '$Name' output ---"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        # The spec replays this step's environment, runner tokens included.
        Remove-Item -LiteralPath $spec -Force -ErrorAction SilentlyContinue
    }
    $text = (Get-Content -LiteralPath $exitFile -Raw).Trim()
    if ($text -notmatch '^-?\d+$') { throw "Outside-job run '$Name' wrote no exit code ('$text')" }
    return [int]$text
}

function Get-VerifiedDesktopWindows([string]$Exe) {
    # The detached updater canonicalizes the WorkRoot path while the driver can
    # retain ``..`` segments. Compare executable identity, not path spelling.
    $expectedExe = [IO.Path]::GetFullPath($Exe)
    $rows = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $expectedExe
    })
    return @($rows | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } | Where-Object { $_.MainWindowHandle -ne 0 })
}

function Close-VerifiedDesktop([string]$Exe, [int]$ProcessId = 0) {
    $windows = @(Get-VerifiedDesktopWindows $Exe)
    if ($ProcessId) { $windows = @($windows | Where-Object { $_.Id -eq $ProcessId }) }
    if ($windows.Count -ne 1) { throw 'Cannot identify exactly one verified desktop window to close normally' }
    $window = $windows[0]
    if (-not $window.CloseMainWindow()) { throw 'Verified desktop refused a normal window close' }
    if (-not $window.WaitForExit(30000)) { throw 'Verified desktop did not exit normally; no force-kill or smoke relaunch attempted' }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $remaining = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $Exe })
        if (-not $remaining.Count) { return }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    throw 'Verified desktop children did not exit normally; no smoke relaunch attempted'
}

function Main-Processes([string]$Exe) {
    # Prevent the function output pipeline from unrolling zero/one process arrays.
    return ,@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -ieq $Exe -and $_.CommandLine -notmatch '(?:^|\s)--type(?:=|\s)' })
}
