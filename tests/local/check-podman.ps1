# check-podman.ps1 - read-only report on the local Podman / Kubernetes tooling (Windows).
#
# Installs nothing, changes nothing. From the project folder, in PowerShell:
#
#   powershell -ExecutionPolicy Bypass -File tests\local\check-podman.ps1
#
# The report is printed and saved to tests\local\out\podman-check.txt (git-ignored).

$ErrorActionPreference = 'Continue'
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$report = Join-Path $out 'podman-check.txt'

function Run-Step([string]$title, [scriptblock]$cmd) {
    "== $title =="
    try { & $cmd 2>&1 | Out-String -Width 200 } catch { "ERROR: $($_.Exception.Message)" }
    ""
}

$lines = @()
$lines += "date: $(Get-Date -Format s)"
$lines += Run-Step 'Windows'          { (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version | Format-List | Out-String).Trim() }
$lines += Run-Step 'CPU / memory'     { "logical CPUs: $env:NUMBER_OF_PROCESSORS"; "memory GiB: " + [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) }
$lines += Run-Step 'WSL'              { wsl --status; wsl -l -v }
$lines += Run-Step 'podman version'   { podman version }
$lines += Run-Step 'podman machines'  { podman machine list }
$lines += Run-Step 'podman machine inspect' { podman machine inspect --format "{{.Name}} cpus={{.Resources.CPUs}} memMiB={{.Resources.Memory}} diskGiB={{.Resources.DiskSize}} rootful={{.Rootful}} state={{.State}}" }
$lines += Run-Step 'podman info (host)' { podman info --format "os={{.Host.OS}} kernel={{.Host.Kernel}} cgroups={{.Host.CgroupsVersion}} rootless={{.Host.Security.Rootless}}" }
$lines += Run-Step 'test pull from Docker Hub' { podman pull docker.io/library/busybox:1.36 }
$lines += Run-Step 'kind'             { kind version }
$lines += Run-Step 'kubectl'          { kubectl version --client }
$lines += Run-Step 'helm'             { helm version --short }
$lines += Run-Step 'git'              { git --version }

$lines | Tee-Object -FilePath $report
"Report saved to: $report"
