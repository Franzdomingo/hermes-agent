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
# Explorer/Start-menu launch is in no such job, so a desktop checkpoint runs from a
# context outside it, with this step's environment, cwd and arguments replayed from a
# spec file. Candidate contexts: a one-shot interactive Scheduled Task, a WMI
# Win32_Process.Create child, and a child reparented under the user's explorer.exe.
# Find-BreakawayLaunch probes each with the same CreateProcess call the gateway makes
# and picks the first that permits it.
$script:BreakawayProbe = @'
import ctypes, json, subprocess
from ctypes import wintypes as w
k = ctypes.WinDLL('kernel32', use_last_error=True)
k.GetCurrentProcess.restype = w.HANDLE
k.IsProcessInJob.argtypes = [w.HANDLE, w.HANDLE, ctypes.POINTER(w.BOOL)]
k.IsProcessInJob.restype = w.BOOL
k.QueryInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD)]
k.QueryInformationJobObject.restype = w.BOOL
class Basic(ctypes.Structure):
    _fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64), ('PerJobUserTimeLimit', ctypes.c_int64),
                ('LimitFlags', w.DWORD), ('MinimumWorkingSetSize', ctypes.c_size_t),
                ('MaximumWorkingSetSize', ctypes.c_size_t), ('ActiveProcessLimit', w.DWORD),
                ('Affinity', ctypes.c_size_t), ('PriorityClass', w.DWORD), ('SchedulingClass', w.DWORD)]
result = {}
in_job = w.BOOL()
if k.IsProcessInJob(k.GetCurrentProcess(), None, ctypes.byref(in_job)):
    result['in_job'] = bool(in_job.value)
else:
    result['in_job'] = 'error %d' % ctypes.get_last_error()
if in_job.value:
    info = Basic()
    if k.QueryInformationJobObject(None, 2, ctypes.byref(info), ctypes.sizeof(info), None):
        flags = info.LimitFlags
        result['limit_flags'] = '0x%08X' % flags
        result['breakaway_ok'] = bool(flags & 0x800)
        result['silent_breakaway_ok'] = bool(flags & 0x1000)
    else:
        result['limit_flags'] = 'error %d' % ctypes.get_last_error()
try:
    # CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, as the gateway spawn.
    subprocess.Popen(['cmd.exe', '/c', 'exit', '0'], creationflags=0x01000000 | 0x08000000 | 0x00000200).wait(30)
    result['breakaway_spawn'] = 'ok'
except OSError as exc:
    result['breakaway_spawn'] = '%s winerror=%s' % (type(exc).__name__, getattr(exc, 'winerror', None))
import sys
result['exe'] = sys.executable
print('BREAKAWAY-PROBE ' + json.dumps(result))
'@

$script:OutsideJobWrapper = @'
param([string]$SpecPath)
$ErrorActionPreference = 'Continue'
$code = 99
$spec = Get-Content -LiteralPath $SpecPath -Raw | ConvertFrom-Json
# Node writes UTF-8 into a pipe; decode it as such, not as the OEM code page. Cosmetic,
# and a session without a console rejects it, so a failure here must not fail the run.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
try {
    $chain = @()
    $id = $PID
    for ($i = 0; $i -lt 8 -and $id; $i++) {
        $row = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue
        if (-not $row) { $chain += "?[$id]"; break }
        $chain += "$($row.Name)[$id]"
        $id = $row.ParentProcessId
    }
    "outside-job context: session $((Get-Process -Id $PID).SessionId); chain $($chain -join ' <- ')" |
        Set-Content -LiteralPath $spec.log -Encoding UTF8
    foreach ($entry in $spec.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($entry.Name, [string]$entry.Value, 'Process') }
    Set-Location -LiteralPath $spec.cwd
    & $spec.exe @($spec.args) 2>&1 | ForEach-Object { "$_" } | Add-Content -LiteralPath $spec.log -Encoding UTF8
    $code = $LASTEXITCODE
} catch {
    "outside-job wrapper failed: $_" | Add-Content -LiteralPath $spec.log -Encoding UTF8
} finally {
    Set-Content -LiteralPath $spec.exit -Value $code -Encoding ascii
}
'@

$script:ReparentSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class HermesE2EReparent {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
        IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    public static int Start(int parentPid, string commandLine, string cwd) {
        IntPtr parent = OpenProcess(0x0080 /* PROCESS_CREATE_PROCESS */, false, parentPid);
        if (parent == IntPtr.Zero) throw new Win32Exception();
        IntPtr size = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        IntPtr list = Marshal.AllocHGlobal(size);
        IntPtr value = Marshal.AllocHGlobal(IntPtr.Size);
        try {
            if (!InitializeProcThreadAttributeList(list, 1, 0, ref size)) throw new Win32Exception();
            Marshal.WriteIntPtr(value, parent);
            // PROC_THREAD_ATTRIBUTE_PARENT_PROCESS
            if (!UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020000, value, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception();
            STARTUPINFOEX si = new STARTUPINFOEX();
            si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            si.lpAttributeList = list;
            PROCESS_INFORMATION pi;
            // EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW
            if (!CreateProcessW(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false,
                    0x00080000 | 0x08000000, IntPtr.Zero, cwd, ref si, out pi))
                throw new Win32Exception();
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return pi.dwProcessId;
        } finally {
            DeleteProcThreadAttributeList(list);
            Marshal.FreeHGlobal(list);
            Marshal.FreeHGlobal(value);
            CloseHandle(parent);
        }
    }
}
'@

function Start-OutsideJobProcess([string]$Via, [string]$Name, [string]$Exe, [string]$Arguments, [string]$Cwd, [int]$TimeoutMinutes) {
    # Returns @{ task = <name> } or @{ pid = <id> } for Wait-OutsideJob.
    $commandLine = "`"$Exe`" $Arguments"
    switch ($Via) {
        'task' {
            $taskName = 'HermesE2E-{0}-{1}' -f ($Name -replace '[^A-Za-z0-9_.-]', '-'), $PID
            $action = New-ScheduledTaskAction -Execute $Exe -Argument $Arguments -WorkingDirectory $Cwd
            # Interactive, as Hermes's own gateway task; Task Scheduler starts it outside the runner's job.
            $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($TimeoutMinutes + 5)) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName | Out-Null
            return @{ task = $taskName }
        }
        'wmi' {
            $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $Cwd }
            if ($created.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($created.ReturnValue)" }
            return @{ pid = [int]$created.ProcessId }
        }
        'explorer' {
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $explorer = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object {
                $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
                "$($owner.Domain)\$($owner.User)" -ieq $me
            }) | Select-Object -First 1
            if (-not $explorer) { throw "no explorer.exe owned by $me" }
            if (-not ('HermesE2EReparent' -as [type])) { Add-Type -TypeDefinition $script:ReparentSource }
            return @{ pid = [HermesE2EReparent]::Start([int]$explorer.ProcessId, $commandLine, $Cwd) }
        }
        default { throw "unknown outside-job launch '$Via'" }
    }
}

function Wait-OutsideJob($Handle, [string]$Name, [string]$ExitFile, [int]$TimeoutMinutes) {
    $started = Get-Date
    $deadline = $started.AddMinutes($TimeoutMinutes)
    while (-not (Test-Path -LiteralPath $ExitFile)) {
        if ((Get-Date) -ge $deadline) {
            if ($Handle.task) { Stop-ScheduledTask -TaskName $Handle.task -ErrorAction SilentlyContinue }
            else { Stop-Process -Id $Handle.pid -Force -ErrorAction SilentlyContinue }
            throw "Outside-job run '$Name' did not finish within $TimeoutMinutes minutes"
        }
        # A wrapper that never started or died leaves no exit file; fail now, not at the deadline.
        if ($Handle.task) {
            $task = Get-ScheduledTask -TaskName $Handle.task
            $gone = $task.State -notin @('Running', 'Queued') -and (Get-Date) -ge $started.AddSeconds(30)
            $why = { "task state {0}, last result 0x{1:X8}" -f $task.State, (Get-ScheduledTaskInfo -TaskName $Handle.task).LastTaskResult }
        } else {
            $gone = -not (Get-Process -Id $Handle.pid -ErrorAction SilentlyContinue)
            $why = { "wrapper pid $($Handle.pid) exited" }
        }
        if ($gone) {
            Start-Sleep -Seconds 2
            if (-not (Test-Path -LiteralPath $ExitFile)) { throw "Outside-job run '$Name' ended without an exit code ($(& $why))" }
        }
        Start-Sleep -Seconds 2
    }
}

function Invoke-OutsideRunnerJob([string]$Name, [string]$Work, [string]$Exe, [string[]]$Arguments, [int]$TimeoutMinutes = 45, [string]$Via = 'task', [switch]$Quiet) {
    $dir = Join-Path $Work "outside-job-$Name"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $spec = Join-Path $dir 'spec.json'
    $log = Join-Path $dir 'output.log'
    $exitFile = Join-Path $dir 'exit-code'
    Remove-Item -LiteralPath $log, $exitFile -Force -ErrorAction SilentlyContinue
    $environment = [ordered]@{}
    Get-ChildItem Env: | ForEach-Object { $environment[$_.Name] = $_.Value }
    $cwd = (Get-Location).ProviderPath
    # ConvertTo-Json -InputObject keeps a one-element args list an array.
    ConvertTo-Json -Depth 4 -InputObject ([ordered]@{ exe = $Exe; args = [object[]]@($Arguments); cwd = $cwd; env = $environment; log = $log; exit = $exitFile }) |
        Set-Content -LiteralPath $spec -Encoding UTF8
    $wrapper = Join-Path $dir 'run.ps1'
    $script:OutsideJobWrapper | Set-Content -LiteralPath $wrapper -Encoding UTF8
    # The same PowerShell as this step, so native argument passing matches a direct call.
    $shell = (Get-Process -Id $PID).Path
    $shellArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$wrapper`" -SpecPath `"$spec`""
    $handle = $null
    try {
        $handle = Start-OutsideJobProcess $Via $Name $shell $shellArgs $cwd $TimeoutMinutes
        Wait-OutsideJob $handle $Name $exitFile $TimeoutMinutes
    } finally {
        if (-not $Quiet) {
            Write-Host "--- outside-job '$Name' via $Via output ($log) ---"
            if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Encoding UTF8 | ForEach-Object { Write-Host $_ } }
            Write-Host "--- end outside-job '$Name' output ---"
        }
        if ($handle -and $handle.task) { Unregister-ScheduledTask -TaskName $handle.task -Confirm:$false -ErrorAction SilentlyContinue }
        # The spec replays this step's environment, runner tokens included.
        Remove-Item -LiteralPath $spec -Force -ErrorAction SilentlyContinue
    }
    $text = (Get-Content -LiteralPath $exitFile -Raw).Trim()
    if ($text -notmatch '^-?\d+$') { throw "Outside-job run '$Name' wrote no exit code ('$text')" }
    return [int]$text
}

function Find-BreakawayLaunch([string]$Work, [string]$Python) {
    # Probe once per journey; every context's verdict is logged so a failing leg shows which held.
    if ($script:BreakawayLaunch) { return $script:BreakawayLaunch }
    $probe = Join-Path $Work 'breakaway-probe.py'
    $script:BreakawayProbe | Set-Content -LiteralPath $probe -Encoding ascii
    # A venv python.exe is a launcher that holds the real interpreter in its own job
    # (KILL_ON_JOB_CLOSE | SILENT_BREAKAWAY_OK), and breakaway is judged against the
    # immediate job only. The gateway's python sits directly in the context's job
    # (libuv's jobs are silent-breakaway too), so probe with the real interpreter.
    $real = (& $Python -c "import sys; print(getattr(sys, '_base_executable', sys.executable))" | Select-Object -Last 1).Trim()
    Write-Host "breakaway probe interpreter: $real (from $Python)"
    $verdicts = [ordered]@{}
    $verdicts['step-launcher'] = (& $Python $probe 2>&1 | ForEach-Object { "$_" }) -join ' '
    $verdicts['step'] = (& $real $probe 2>&1 | ForEach-Object { "$_" }) -join ' '
    foreach ($via in @('task', 'wmi', 'explorer')) {
        try {
            Invoke-OutsideRunnerJob "probe-$via" $Work $real @($probe) -TimeoutMinutes 2 -Via $via -Quiet | Out-Null
            $verdicts[$via] = (Get-Content -LiteralPath (Join-Path $Work "outside-job-probe-$via\output.log") -Encoding UTF8) -join ' | '
        } catch {
            $verdicts[$via] = "launch failed: $_"
        }
    }
    $chosen = 'step'
    foreach ($via in @('task', 'wmi', 'explorer')) {
        if ($verdicts[$via] -match '"breakaway_spawn": "ok"') { $chosen = $via; break }
    }
    foreach ($via in $verdicts.Keys) { Write-Host "breakaway probe [$via]: $($verdicts[$via])" }
    Write-Host "desktop checkpoints launch via: $chosen"
    $script:BreakawayLaunch = $chosen
    return $chosen
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
