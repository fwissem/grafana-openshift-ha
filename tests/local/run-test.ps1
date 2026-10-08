<#
.SYNOPSIS
  Local functional test of the HA Grafana + PostgreSQL deployment on kind (Podman).

.DESCRIPTION
  Creates (or reuses) a kind cluster "grafana-ha" laid out like production:
  two data zones (zone-a, zone-b) with two workers each and one quorum zone
  (zone-c) with one worker. Deploys PostgreSQL (manifests/overlays/kind) and
  Grafana (Helm chart from charts\grafana), then checks:

    T01  4 Grafana replicas ready
    T02  2 replicas per data zone, nothing in the quorum zone (PostgreSQL included)
    T03  Grafana uses PostgreSQL, no PVC on Grafana
    T04  unified alerting cluster sees all replicas
    T05  test content created (folders, dashboards, user, folder permissions)
    T06  anonymous user: shared folder visible, restricted folder hidden
    T07  every replica serves the same content
    T08  delete ALL Grafana pods: nothing lost
    T09  add a datasource (helm upgrade): pods rolled, nothing lost
    T10  kill one pod under load: no failed request
    T11  drain a whole data zone under load: service continues, quorum zone unused
    T12  NetworkPolicy: only labelled clients reach PostgreSQL
    T13  backup, simulated loss, restore: dashboard is back
    T14  no pod of the namespace (jobs and test pods included) in the quorum zone

  Everything it creates lives in the kind cluster. It changes nothing else.
  Results: tests\local\out\results.txt   Full log: tests\local\out\run-test.log
  Diagnostics (pods, events, logs): tests\local\out\diag.txt

.PARAMETER Recreate
  Delete the kind cluster first and start from scratch.
.PARAMETER Destroy
  Delete the kind cluster and exit.
.PARAMETER SkipDeploy
  Run the tests only, against what is already deployed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\run-test.ps1
#>
param(
    [switch]$Recreate,
    [switch]$Destroy,
    [switch]$SkipDeploy
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# --- Settings ----------------------------------------------------------------
$Root         = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Out          = Join-Path $PSScriptRoot 'out'
$Cluster      = 'grafana-ha'
$Ctx          = "kind-$Cluster"
$Ns           = 'grafana'
$Release      = 'grafana'
$ChartDir     = Join-Path $Root 'charts\grafana'
$ChartVersion = '13.3.1'
$PortUrl      = 'http://localhost:3300'
$Selector     = 'app.kubernetes.io/name=grafana,app.kubernetes.io/instance=grafana'
$Replicas     = 4
$ApiPort      = 6445   # kind-config.yaml networking.apiServerPort
$DataZones    = @('zone-a', 'zone-b')
$QuorumZone   = 'zone-c'
$env:KIND_EXPERIMENTAL_PROVIDER = 'podman'

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$LogFile     = Join-Path $Out 'run-test.log'
$ResultsFile = Join-Path $Out 'results.txt'
$DiagFile    = Join-Path $Out 'diag.txt'
Set-Content -Path $LogFile -Value "run-test started $(Get-Date -Format s)" -Encoding UTF8

$script:BaseUrl = $PortUrl
$script:AuthB64 = ''
$script:PortForward = $null
$Results = New-Object System.Collections.ArrayList

# --- Helpers -----------------------------------------------------------------
function Log([string]$Msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# Run a native command, log its output, return exit code + text.
function Exec([string]$Exe, [string[]]$ArgList) {
    $text = (& $Exe @ArgList 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $code = $LASTEXITCODE
    Add-Content -Path $LogFile -Value ("> {0} {1}`n{2}`n[rc={3}]" -f $Exe, ($ArgList -join ' '), $text, $code) -Encoding UTF8
    return [pscustomobject]@{ Code = $code; Out = $text }
}

function K([string[]]$ArgList) { return Exec 'kubectl' (@('--context', $Ctx, '-n', $Ns) + $ArgList) }

# kubectl ... -o json, stderr discarded so warnings do not break the JSON.
function KJson([string[]]$ArgList) {
    $text = (& kubectl --context $Ctx -n $Ns @ArgList -o json 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $text) { return $null }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Result([string]$Id, [string]$Name, [string]$Status, [string]$Detail) {
    [void]$Results.Add([pscustomobject]@{ Id = $Id; Test = $Name; Status = $Status; Detail = $Detail })
    Log ('{0,-4} {1} {2} - {3}' -f $Status, $Id, $Name, $Detail)
}

function Wait-Until([scriptblock]$Cond, [int]$TimeoutSec, [string]$What) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (& $Cond) { return $true }
        Start-Sleep -Seconds 3
    }
    Log "timeout after ${TimeoutSec}s waiting for: $What"
    return $false
}

# Grafana HTTP API. Returns Status (0 = no answer), Json, Raw.
function Api([string]$Method, [string]$Path, $Body = $null, [switch]$Anonymous) {
    $headers = @{}
    if (-not $Anonymous) { $headers['Authorization'] = "Basic $script:AuthB64" }
    $params = @{ Uri = "$script:BaseUrl$Path"; Method = $Method; Headers = $headers;
                 UseBasicParsing = $true; TimeoutSec = 20; DisableKeepAlive = $true }
    if ($null -ne $Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $params['ContentType'] = 'application/json'
    }
    try {
        $r = Invoke-WebRequest @params
        $j = $null; try { $j = $r.Content | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Json = $j; Raw = $r.Content }
    } catch {
        $code = 0; $raw = $_.Exception.Message
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try { $raw = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
        }
        return [pscustomobject]@{ Status = $code; Json = $null; Raw = $raw }
    }
}

function Get-GrafanaPods {
    $j = KJson @('get', 'pods', '-l', $Selector)
    if ($null -eq $j) { return @() }
    return @($j.items)
}

function Get-ReadyGrafanaPods {
    return @(Get-GrafanaPods | Where-Object {
        $null -eq $_.metadata.deletionTimestamp -and
        @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
    })
}

function Wait-GrafanaReady([int]$Count, [int]$TimeoutSec = 600) {
    $ok = Wait-Until { (Get-ReadyGrafanaPods).Count -eq $Count -and (Get-GrafanaPods).Count -eq $Count } $TimeoutSec "$Count Grafana pods ready"
    if (-not $ok) { return $false }
    return (Wait-Until { (Api 'GET' '/api/health' -Anonymous).Status -eq 200 } 180 'Grafana API answering')
}

function Get-SecretValue([string]$Name, [string]$Key) {
    $j = KJson @('get', 'secret', $Name)
    if ($null -eq $j) { return $null }
    $b64 = $j.data.$Key
    if (-not $b64) { return $null }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

function New-Password { return ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N').Substring(0, 8)) }

function Ensure-Secret([string]$Name, [hashtable]$Data) {
    $a = @('create', 'secret', 'generic', $Name)
    foreach ($k in $Data.Keys) { $a += "--from-literal=$k=$($Data[$k])" }
    $yaml = (& kubectl --context $Ctx -n $Ns @a --dry-run=client -o yaml 2>&1) -join "`n"
    $r = ($yaml | & kubectl --context $Ctx -n $Ns apply -f - 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $code = $LASTEXITCODE
    Add-Content -Path $LogFile -Value "> secret $Name : $r [rc=$code]" -Encoding UTF8
    if ($code -ne 0) { Log "ERROR: could not create secret $Name : $r"; Collect-Diagnostics; exit 1 }
}

function Helm-Deploy([string]$DatasourceFile) {
    $a = @('upgrade', '--install', $Release, $ChartDir,
           '--kube-context', $Ctx, '--namespace', $Ns,
           '-f', (Join-Path $Root 'values\values.yaml'),
           '-f', (Join-Path $PSScriptRoot 'values-kind.yaml'),
           '-f', (Join-Path $PSScriptRoot $DatasourceFile),
           '--wait', '--timeout', '15m')
    return Exec 'helm' $a
}

function Collect-Diagnostics {
    $lines = @("diagnostics $(Get-Date -Format s)")
    foreach ($a in @(
            @('get', 'pods,svc,pvc,endpoints,networkpolicy,pdb', '-o', 'wide'),
            @('get', 'events', '--sort-by=.lastTimestamp'))) {
        $lines += "===== kubectl $($a -join ' ')"
        $lines += (& kubectl --context $Ctx -n $Ns @a 2>&1 | ForEach-Object { "$_" })
    }
    $lines += '===== nodes'
    $lines += (& kubectl --context $Ctx get nodes -L topology.kubernetes.io/zone -o wide 2>&1 | ForEach-Object { "$_" })
    foreach ($p in (Get-GrafanaPods)) {
        $lines += "===== logs $($p.metadata.name) (last 80 lines)"
        $lines += (& kubectl --context $Ctx -n $Ns logs $p.metadata.name -c grafana --tail=80 2>&1 | ForEach-Object { "$_" })
    }
    $lines += '===== logs grafana-postgresql-0 (last 60 lines)'
    $lines += (& kubectl --context $Ctx -n $Ns logs grafana-postgresql-0 --tail=60 2>&1 | ForEach-Object { "$_" })
    $lines | Out-File -FilePath $DiagFile -Encoding utf8
}

function Write-Summary {
    $pass = @($Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $warn = @($Results | Where-Object { $_.Status -eq 'WARN' }).Count
    $fail = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $text = @("Local functional test - $(Get-Date -Format s)",
              "Chart $ChartVersion, cluster $Cluster, namespace $Ns, URL $script:BaseUrl",
              "PASS $pass   WARN $warn   FAIL $fail", '')
    foreach ($r in $Results) { $text += ('{0,-4} {1} {2}: {3}' -f $r.Status, $r.Id, $r.Test, $r.Detail) }
    $text | Out-File -FilePath $ResultsFile -Encoding utf8
    Write-Host ''
    $text | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "Results : $ResultsFile"
    Write-Host "Log     : $LogFile"
    Write-Host "Diag    : $DiagFile"
}

function Stop-PortForward {
    if ($script:PortForward -and -not $script:PortForward.HasExited) {
        Stop-Process -Id $script:PortForward.Id -Force -ErrorAction SilentlyContinue
    }
}

# SSH tunnel Windows -> Podman machine. Rootful Podman on WSL publishes ports
# with firewall redirects only (no listening socket), so WSL cannot forward them
# to Windows. The tunnel uses Podman's own machine SSH key and port.
$TunnelPidFile = Join-Path $Out 'tunnel.pid'
function Stop-Tunnel {
    if (Test-Path $TunnelPidFile) {
        $tp = Get-Content $TunnelPidFile -ErrorAction SilentlyContinue
        if ($tp) { Stop-Process -Id ([int]$tp) -Force -ErrorAction SilentlyContinue }
        Remove-Item $TunnelPidFile -Force -ErrorAction SilentlyContinue
    }
}
function Start-Tunnel {
    Stop-Tunnel
    $info = (Exec 'podman' @('machine', 'inspect', '--format', '{{.SSHConfig.IdentityPath}}|{{.SSHConfig.Port}}|{{.SSHConfig.RemoteUsername}}|{{.Rootful}}')).Out.Trim()
    $parts = $info -split '\|'
    if ($parts.Count -lt 4) { Log "ERROR: cannot read the Podman machine SSH settings: $info"; return $false }
    $key = $parts[0]; $port = $parts[1]; $user = $parts[2]
    if ($parts[3] -eq 'true') { $user = 'root' }
    $sshArgs = @('-N', '-i', "`"$key`"", '-p', $port,
              '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
              '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30', '-o', 'LogLevel=ERROR',
              '-L', "127.0.0.1:${ApiPort}:127.0.0.1:${ApiPort}",
              '-L', '127.0.0.1:3300:127.0.0.1:3300',
              "$user@127.0.0.1")
    Add-Content -Path $LogFile -Value "> ssh $($sshArgs -join ' ')" -Encoding UTF8
    $proc = Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -WindowStyle Hidden -PassThru
    Set-Content -Path $TunnelPidFile -Value $proc.Id
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { Log "ERROR: SSH tunnel to the Podman machine exited (code $($proc.ExitCode))."; return $false }
    Log "SSH tunnel to the Podman machine started (pid $($proc.Id)): 127.0.0.1:$ApiPort and 127.0.0.1:3300"
    return $true
}

# --- 0. Prerequisites ----------------------------------------------------------
foreach ($tool in @('podman', 'kind', 'kubectl', 'helm', 'ssh')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Log "ERROR: '$tool' not found in PATH. Open a new PowerShell window after installing it."
        exit 2
    }
}

if ($Destroy) {
    Log "Deleting kind cluster $Cluster"
    Stop-Tunnel
    Exec 'kind' @('delete', 'cluster', '--name', $Cluster) | Out-Null
    Log 'Done.'
    exit 0
}

$pi = Exec 'podman' @('info')
if ($pi.Code -ne 0) {
    Log 'ERROR: the Podman machine is not running. Start it in Podman Desktop (Settings > Resources) and retry.'
    exit 2
}

$chartYaml = Join-Path $ChartDir 'Chart.yaml'
if (-not (Test-Path $chartYaml) -or -not (Select-String -Path $chartYaml -Pattern "^version:\s*$([regex]::Escape($ChartVersion))\s*$" -Quiet)) {
    Log "ERROR: Grafana chart $ChartVersion not found in $ChartDir"
    Log 'Download it by hand, then run this script again:'
    Log '  helm repo add grafana-community https://grafana-community.github.io/helm-charts'
    Log '  helm repo update grafana-community'
    Log "  helm pull grafana-community/grafana --version $ChartVersion --untar --untardir $(Join-Path $Root 'charts')"
    exit 2
}

# --- 1. Cluster ----------------------------------------------------------------
if (-not $SkipDeploy) {
    $clusters = (Exec 'kind' @('get', 'clusters')).Out
    $exists = ($clusters -split "`n" | ForEach-Object { $_.Trim() }) -contains $Cluster
    if ($exists -and $Recreate) {
        Log "Deleting existing kind cluster $Cluster (-Recreate)"
        Exec 'kind' @('delete', 'cluster', '--name', $Cluster) | Out-Null
        $exists = $false
    }
    if (-not $exists) {
        # kind runs Kubernetes inside node containers; the kubelets need more
        # inotify instances than the Podman VM default. Applies to the Podman
        # machine only, until its next restart.
        Exec 'podman' @('machine', 'ssh', 'sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288') | Out-Null

        # kind starts all node containers in parallel. On the WSL Podman machine
        # the Podman service runs outside systemd's tree (/sys/fs/cgroup/non-systemd,
        # a group holding processes, so it cannot pass controllers to children).
        # With cgroup_manager=systemd, some parallel creations fall back to that
        # group and fail ("controller pids is not available", "conmon bytes").
        # Fix: let Podman manage cgroups itself (cgroupfs). Containers then go
        # under /libpod_parent at the cgroup root, which has every controller.
        # One file in the Podman machine; remove it to revert:
        #   podman machine ssh sudo rm /etc/containers/containers.conf.d/90-kind-cgroupfs.conf
        $mgr = (Exec 'podman' @('info', '--format', '{{.Host.CgroupManager}}')).Out.Trim()
        Log "Podman cgroup manager: $mgr"
        if ($mgr -ne 'cgroupfs') {
            $conf = "# Added by grafana-openshift-ha tests/local/run-test.ps1 (kind on WSL).`n[engine]`ncgroup_manager = `"cgroupfs`"`n"
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($conf))
            $w = Exec 'podman' @('machine', 'ssh', "sudo mkdir -p /etc/containers/containers.conf.d && echo $b64 | base64 -d | sudo tee /etc/containers/containers.conf.d/90-kind-cgroupfs.conf")
            Log "Switching Podman to cgroupfs and restarting the Podman machine (about 30 s)"
            Exec 'podman' @('machine', 'stop') | Out-Null
            Exec 'podman' @('machine', 'start') | Out-Null
            $mgr = (Exec 'podman' @('info', '--format', '{{.Host.CgroupManager}}')).Out.Trim()
            Log "Podman cgroup manager now: $mgr"
            if ($mgr -ne 'cgroupfs') { Log 'ERROR: could not switch Podman to cgroupfs. See the log.'; exit 1 }
            Exec 'podman' @('machine', 'ssh', 'sudo sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288') | Out-Null
        }

        Log "Creating kind cluster $Cluster (1 control plane, 2+2 workers in data zones, 1 in the quorum zone). First run downloads the node image."
        $created = $false
        for ($attempt = 1; $attempt -le 5 -and -not $created; $attempt++) {
            $r = Exec 'kind' @('create', 'cluster', '--config', (Join-Path $PSScriptRoot 'kind-config.yaml'), '--wait', '5m')
            if ($r.Code -eq 0) { $created = $true; break }
            Log "kind create cluster failed (attempt $attempt/5); collecting Podman diagnostics and retrying."
            Exec 'podman' @('ps', '-a') | Out-Null
            Exec 'podman' @('machine', 'ssh', 'ulimit -a; sysctl fs.inotify fs.file-max kernel.pid_max; free -m; sudo dmesg | tail -n 40; sudo journalctl -n 60 --no-pager') | Out-Null
            Exec 'kind' @('delete', 'cluster', '--name', $Cluster) | Out-Null
            Start-Sleep -Seconds 10
        }
        if (-not $created) { Log "ERROR: kind create cluster failed 5 times. See $LogFile"; exit 1 }
    } else {
        Log "Reusing kind cluster $Cluster"
    }

    # kind writes the API address it was given (0.0.0.0, see kind-config.yaml);
    # Windows cannot connect to 0.0.0.0, so point kubectl at 127.0.0.1, which the
    # SSH tunnel forwards to the Podman machine.
    if (-not (Start-Tunnel)) { exit 1 }
    Exec 'kubectl' @('config', 'set-cluster', $Ctx, "--server=https://127.0.0.1:$ApiPort") | Out-Null
    $apiOk = Wait-Until { (Exec 'kubectl' @('--context', $Ctx, 'get', '--raw', '/readyz')).Out -match 'ok' } 120 "Kubernetes API on 127.0.0.1:$ApiPort"
    if (-not $apiOk) {
        Log "ERROR: the Kubernetes API is not reachable from Windows on 127.0.0.1:$ApiPort. Collecting network diagnostics."
        Exec 'podman' @('ps', '--format', '{{.Names}} {{.Ports}}') | Out-Null
        Exec 'podman' @('machine', 'ssh', "ss -ltnp | grep -E ':($ApiPort|3300) ' ; curl -sk https://127.0.0.1:$ApiPort/readyz; echo") | Out-Null
        $tnc = Test-NetConnection -ComputerName 127.0.0.1 -Port $ApiPort -WarningAction SilentlyContinue
        Log "Windows -> 127.0.0.1:$ApiPort TcpTestSucceeded=$($tnc.TcpTestSucceeded)"
        exit 1
    }
    Log "Kubernetes API reachable on https://127.0.0.1:$ApiPort"

    $nsYaml = (& kubectl --context $Ctx create namespace $Ns --dry-run=client -o yaml 2>&1) -join "`n"
    $nsYaml | & kubectl --context $Ctx apply -f - 2>&1 | Out-Null

    # --- 2. Secrets: reuse what the cluster has, generate only what is missing ---
    $adminPw = Get-SecretValue 'grafana-admin' 'admin-password'
    if (-not $adminPw) { $adminPw = New-Password; Ensure-Secret 'grafana-admin' @{ 'admin-user' = 'admin'; 'admin-password' = $adminPw } }
    $dbPw = Get-SecretValue 'grafana-db' 'password'
    if (-not $dbPw) { $dbPw = New-Password; Ensure-Secret 'grafana-db' @{ 'username' = 'grafana'; 'password' = $dbPw; 'database' = 'grafana' } }
    $sk = Get-SecretValue 'grafana-secret-key' 'secret-key'
    if (-not $sk) { Ensure-Secret 'grafana-secret-key' @{ 'secret-key' = (New-Password) } }
    Log 'Secrets ready (grafana-admin, grafana-db, grafana-secret-key)'

    # --- 3. PostgreSQL -----------------------------------------------------------
    Log 'Deploying PostgreSQL (manifests/overlays/kind)'
    $r = Exec 'kubectl' @('--context', $Ctx, 'apply', '-k', (Join-Path $Root 'manifests\overlays\kind'))
    if ($r.Code -ne 0) { Log "ERROR: kubectl apply -k failed: $($r.Out)"; Collect-Diagnostics; exit 1 }
    $r = K @('rollout', 'status', 'statefulset/grafana-postgresql', '--timeout=600s')
    if ($r.Code -ne 0) { Log 'ERROR: PostgreSQL did not become ready.'; Collect-Diagnostics; exit 1 }
    Log 'PostgreSQL ready'

    # --- 4. Grafana --------------------------------------------------------------
    Log "Deploying Grafana (helm upgrade --install, chart $ChartVersion). First start runs DB migrations."
    $r = Helm-Deploy 'values-test-datasources.yaml'
    if ($r.Code -ne 0) { Log "ERROR: helm upgrade failed: $($r.Out)"; Collect-Diagnostics; exit 1 }
}

if ($SkipDeploy) {
    if (-not (Start-Tunnel)) { exit 1 }
    Exec 'kubectl' @('config', 'set-cluster', $Ctx, "--server=https://127.0.0.1:$ApiPort") | Out-Null
}
$adminPw = Get-SecretValue 'grafana-admin' 'admin-password'
if (-not $adminPw) { Log 'ERROR: secret grafana-admin not found. Run without -SkipDeploy.'; exit 1 }
$script:AuthB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$adminPw"))

if (-not (Wait-GrafanaReady $Replicas 600)) {
    Log 'Grafana pods not ready, trying anyway to reach the API.'
}

# --- 5. Access: kind port mapping, or port-forward as a fallback -------------------
if ((Api 'GET' '/api/health' -Anonymous).Status -ne 200) {
    Log "$PortUrl not reachable; starting kubectl port-forward on 3301 (pod-kill test less representative)."
    $script:PortForward = Start-Process -FilePath 'kubectl' -WindowStyle Hidden -PassThru `
        -ArgumentList @('--context', $Ctx, '-n', $Ns, 'port-forward', 'svc/grafana', '3301:80')
    $script:BaseUrl = 'http://localhost:3301'
    Start-Sleep -Seconds 5
}
if ((Api 'GET' '/api/health' -Anonymous).Status -ne 200) {
    Log "ERROR: Grafana API not reachable at $script:BaseUrl"
    Collect-Diagnostics; Stop-PortForward; exit 1
}
Log "Grafana reachable at $script:BaseUrl"

# =================================== TESTS ========================================

# T01 replicas
$ready = Get-ReadyGrafanaPods
if ($ready.Count -eq $Replicas) { Result 'T01' 'replicas ready' 'PASS' "$Replicas/$Replicas Grafana pods ready" }
else { Result 'T01' 'replicas ready' 'FAIL' "$($ready.Count)/$Replicas Grafana pods ready" }

# T02 zone spread
$nodes = (& kubectl --context $Ctx get nodes -o json 2>$null) -join "`n" | ConvertFrom-Json
$zoneOf = @{}
foreach ($n in $nodes.items) { $zoneOf[$n.metadata.name] = $n.metadata.labels.'topology.kubernetes.io/zone' }
function Get-ZonePlacement {
    $pods = @(Get-ReadyGrafanaPods)
    $byZone = @{}
    foreach ($z in ($DataZones + $QuorumZone)) { $byZone[$z] = 0 }
    foreach ($p in $pods) { $z = $zoneOf[$p.spec.nodeName]; if ($byZone.ContainsKey($z)) { $byZone[$z]++ } else { $byZone[$z] = 1 } }
    return $byZone
}
$byZone = Get-ZonePlacement
$nodesUsed = @($ready | ForEach-Object { $_.spec.nodeName } | Sort-Object -Unique).Count
$pg = KJson @('get', 'pod', 'grafana-postgresql-0')
$pgZone = 'n/a'; if ($pg) { $pgZone = $zoneOf[$pg.spec.nodeName] }
$placement = ($byZone.Keys | Sort-Object | ForEach-Object { "$_=$($byZone[$_])" }) -join ' '
$detail = "Grafana per zone: $placement; distinct nodes: $nodesUsed; PostgreSQL in $pgZone"
$even = ($byZone[$DataZones[0]] -eq 2 -and $byZone[$DataZones[1]] -eq 2)
if ($byZone[$QuorumZone] -gt 0 -or $pgZone -eq $QuorumZone) { Result 'T02' 'zone placement' 'FAIL' "$detail (quorum zone used)" }
elseif ($even -and $nodesUsed -eq $Replicas) { Result 'T02' 'zone placement' 'PASS' $detail }
else { Result 'T02' 'zone placement' 'WARN' "$detail (not 2+2 on distinct nodes)" }

# T03 database backend, no Grafana PVC
$settings = Api 'GET' '/api/admin/settings'
$dbType = $null; if ($settings.Json) { $dbType = $settings.Json.database.type }
$pvcs = KJson @('get', 'pvc', '-l', $Selector)
$pvcCount = 0; if ($pvcs) { $pvcCount = @($pvcs.items).Count }
if ($dbType -eq 'postgres' -and $pvcCount -eq 0) { Result 'T03' 'state in PostgreSQL' 'PASS' 'database.type=postgres, no Grafana PVC' }
else { Result 'T03' 'state in PostgreSQL' 'FAIL' "database.type=$dbType, Grafana PVCs=$pvcCount (settings HTTP $($settings.Status))" }

# T04 alerting HA: the replicas form one gossip cluster.
# Read the cluster size from the Prometheus metrics of each replica (reached
# through the service, so several pods answer); fall back to the gossip
# messages in the pod logs if the metric is not exposed.
function Get-ClusterSizes {
    $sizes = @()
    for ($i = 0; $i -lt 12; $i++) {
        $m = Api 'GET' '/metrics'
        if ($m.Status -eq 200 -and $m.Raw) {
            foreach ($line in ($m.Raw -split "`n")) {
                if ($line -match '^[a-z_]*cluster_members(\{[^}]*\})?\s+([0-9.e+]+)\s*$') { $sizes += [int][double]$Matches[2] }
            }
        }
    }
    return $sizes
}
$sizes = @()
$peersOk = Wait-Until {
    $script:sizes = @(Get-ClusterSizes)
    $script:sizes.Count -gt 0 -and (@($script:sizes | Where-Object { $_ -ne $Replicas }).Count -eq 0)
} 120 "alerting cluster of $Replicas members"
$sizes = $script:sizes
if ($sizes.Count -gt 0) {
    $detail = "cluster_members seen on the replicas: $((($sizes | Sort-Object -Unique) -join ', ')) (expected $Replicas)"
    if ($peersOk) { Result 'T04' 'alerting HA' 'PASS' $detail } else { Result 'T04' 'alerting HA' 'FAIL' $detail }
} else {
    # Fallback: last "gossip ... now=N" message of each pod.
    $counts = @()
    foreach ($p in (Get-ReadyGrafanaPods)) {
        $lg = (K @('logs', $p.metadata.name, '-c', 'grafana')).Out
        $last = @($lg -split "`n" | Where-Object { $_ -match 'component=clustering' -and $_ -match 'now=(\d+)' }) | Select-Object -Last 1
        if ($last -and $last -match 'now=(\d+)') { $counts += [int]$Matches[1] }
    }
    $settled = @(Get-ReadyGrafanaPods | Where-Object { (K @('logs', $_.metadata.name, '-c', 'grafana')).Out -match 'gossip settled' }).Count
    $detail = "metric not exposed; from logs: gossip settled on $settled/$Replicas pods, peers seen: $(($counts | Sort-Object -Unique) -join ', ')"
    if ($settled -eq $Replicas -and @($counts | Where-Object { $_ -eq $Replicas }).Count -gt 0) { Result 'T04' 'alerting HA' 'PASS' $detail }
    else { Result 'T04' 'alerting HA' 'FAIL' $detail }
}

# T05 test content: clean previous run, then create folders, dashboards, permissions, user
foreach ($f in @('shared-test', 'restricted-test')) { Api 'DELETE' "/api/folders/$($f)?forceDeleteRules=true" | Out-Null }
$lookup = Api 'GET' '/api/users/lookup?loginOrEmail=test-viewer'
if ($lookup.Status -eq 200 -and $lookup.Json.id) { Api 'DELETE' "/api/admin/users/$($lookup.Json.id)" | Out-Null }

$steps = @()
$steps += (Api 'POST' '/api/folders' @{ uid = 'shared-test'; title = 'Shared (test)' }).Status
$steps += (Api 'POST' '/api/folders' @{ uid = 'restricted-test'; title = 'Restricted (test)' }).Status
# Restricted folder: Viewer role (and so anonymous users) removed, Editors keep edit.
$steps += (Api 'POST' '/api/folders/restricted-test/permissions' @{ items = @(@{ role = 'Editor'; permission = 2 }) }).Status
$steps += (Api 'POST' '/api/dashboards/db' @{ folderUid = 'shared-test'; overwrite = $true;
            dashboard = @{ uid = 'dash-shared'; title = 'Shared test dashboard'; tags = @('test'); panels = @(); schemaVersion = 41 } }).Status
$steps += (Api 'POST' '/api/dashboards/db' @{ folderUid = 'restricted-test'; overwrite = $true;
            dashboard = @{ uid = 'dash-restricted'; title = 'Restricted test dashboard'; tags = @('test'); panels = @(); schemaVersion = 41 } }).Status
$steps += (Api 'POST' '/api/admin/users' @{ name = 'Test Viewer'; login = 'test-viewer'; email = 'test-viewer@example.com'; password = (New-Password) }).Status
if (@($steps | Where-Object { $_ -ne 200 }).Count -eq 0) { Result 'T05' 'create test content' 'PASS' 'folders, dashboards, permissions, user created' }
else { Result 'T05' 'create test content' 'FAIL' "HTTP codes: $($steps -join ',')" }

# Content check used after each disruptive step.
function Test-Content([string]$Id, [string]$Name) {
    $c = @(
        (Api 'GET' '/api/dashboards/uid/dash-shared').Status,
        (Api 'GET' '/api/dashboards/uid/dash-restricted').Status,
        (Api 'GET' '/api/folders/shared-test').Status,
        (Api 'GET' '/api/users/lookup?loginOrEmail=test-viewer').Status,
        (Api 'GET' '/api/dashboards/uid/dash-shared' -Anonymous).Status,
        (Api 'GET' '/api/dashboards/uid/dash-restricted' -Anonymous).Status)
    $ok = ($c[0] -eq 200 -and $c[1] -eq 200 -and $c[2] -eq 200 -and $c[3] -eq 200 -and $c[4] -eq 200 -and $c[5] -ne 200)
    $detail = "admin: shared=$($c[0]) restricted=$($c[1]) folder=$($c[2]) user=$($c[3]); anonymous: shared=$($c[4]) restricted=$($c[5])"
    if ($ok) { Result $Id $Name 'PASS' $detail } else { Result $Id $Name 'FAIL' $detail }
    return $ok
}

# T06 anonymous access
$anonShared = (Api 'GET' '/api/dashboards/uid/dash-shared' -Anonymous).Status
$anonRestr  = (Api 'GET' '/api/dashboards/uid/dash-restricted' -Anonymous).Status
$searchOk = Wait-Until {
    $s = Api 'GET' '/api/search?tag=test' -Anonymous
    $uids = @($s.Json | ForEach-Object { $_.uid })
    ($uids -contains 'dash-shared') -and -not ($uids -contains 'dash-restricted')
} 90 'anonymous search shows shared only'
$fs = Api 'GET' '/api/frontend/settings' -Anonymous
$ver = ''; if ($fs.Json -and $fs.Json.buildInfo) { $ver = $fs.Json.buildInfo.version }
$detail = "dashboard GET shared=$anonShared restricted=$anonRestr; search shared-only=$searchOk; version shown to anonymous='$ver'"
if ($anonShared -eq 200 -and $anonRestr -ne 200 -and $searchOk) { Result 'T06' 'anonymous access' 'PASS' $detail }
else { Result 'T06' 'anonymous access' 'FAIL' $detail }

# T07 every replica answers with the same content (new connection per request)
$codes = @()
for ($i = 0; $i -lt 30; $i++) { $codes += (Api 'GET' '/api/dashboards/uid/dash-shared').Status }
$bad = @($codes | Where-Object { $_ -ne 200 }).Count
if ($bad -eq 0) { Result 'T07' 'same content on all replicas' 'PASS' '30/30 requests found the dashboard' }
else { Result 'T07' 'same content on all replicas' 'FAIL' "$bad/30 requests did not find it" }

# T08 delete ALL Grafana pods at once
$before = @(Get-GrafanaPods | ForEach-Object { $_.metadata.name })
Log "Deleting all Grafana pods: $($before -join ', ')"
K @('delete', 'pod', '-l', $Selector, '--wait=false') | Out-Null
Start-Sleep -Seconds 5
$back = Wait-Until {
    $r = Get-ReadyGrafanaPods
    $r.Count -eq $Replicas -and @($r | Where-Object { $before -contains $_.metadata.name }).Count -eq 0
} 600 "$Replicas new Grafana pods ready"
Wait-Until { (Api 'GET' '/api/health' -Anonymous).Status -eq 200 } 120 'API back' | Out-Null
if ($back) { Test-Content 'T08' 'all pods deleted: content kept' | Out-Null }
else { Result 'T08' 'all pods deleted: content kept' 'FAIL' 'new pods did not become ready' }

# T09 add a datasource through Helm (the operation that used to lose dashboards)
$before = @(Get-GrafanaPods | ForEach-Object { $_.metadata.name })
Log 'helm upgrade with a third datasource'
$r = Helm-Deploy 'values-test-datasources-added.yaml'
Wait-GrafanaReady $Replicas 600 | Out-Null
$after = @(Get-ReadyGrafanaPods | ForEach-Object { $_.metadata.name })
$rolled = @($after | Where-Object { $before -contains $_ }).Count -eq 0
$dsC = (Api 'GET' '/api/datasources/uid/test-cluster-c').Status
if ($r.Code -eq 0 -and $dsC -eq 200 -and $rolled) {
    Result 'T09a' 'datasource added' 'PASS' 'test-cluster-c present, all pods replaced by the rollout'
} else {
    Result 'T09a' 'datasource added' 'FAIL' "helm rc=$($r.Code), datasource HTTP $dsC, pods replaced=$rolled"
}
Test-Content 'T09b' 'datasource added: content kept' | Out-Null

# T10 kill one pod while clients are polling
$job = Start-Job -ArgumentList "$script:BaseUrl/api/dashboards/uid/dash-shared", 60 -ScriptBlock {
    param($Url, $Seconds)
    $ok = 0; $fail = 0; $errs = @()
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -DisableKeepAlive
            if ($r.StatusCode -eq 200) { $ok++ } else { $fail++ }
        } catch { $fail++; if ($errs.Count -lt 5) { $errs += $_.Exception.Message } }
        Start-Sleep -Milliseconds 100
    }
    [pscustomobject]@{ Ok = $ok; Fail = $fail; Errors = ($errs -join ' | ') }
}
Start-Sleep -Seconds 10
$victim = @(Get-ReadyGrafanaPods)[0].metadata.name
Log "Deleting one Grafana pod under load: $victim"
K @('delete', 'pod', $victim, '--wait=false') | Out-Null
$load = Receive-Job -Job $job -Wait -AutoRemoveJob
$detail = "requests ok=$($load.Ok) failed=$($load.Fail)"
if ($load.Errors) { $detail += "; errors: $($load.Errors)" }
if ($load.Ok -gt 0 -and $load.Fail -eq 0) { Result 'T10' 'pod killed under load' 'PASS' $detail }
elseif ($load.Ok -gt 0 -and $load.Fail -le 3) { Result 'T10' 'pod killed under load' 'WARN' $detail }
else { Result 'T10' 'pod killed under load' 'FAIL' $detail }
Wait-GrafanaReady $Replicas 600 | Out-Null

# T11 lose a whole data zone (the one without PostgreSQL) while clients poll
$pgNode = ''; $pgp = KJson @('get', 'pod', 'grafana-postgresql-0'); if ($pgp) { $pgNode = $pgp.spec.nodeName }
$pgZone = $zoneOf[$pgNode]
$lostZone = @($DataZones | Where-Object { $_ -ne $pgZone })[0]
$zoneNodes = @($nodes.items | Where-Object { $_.metadata.labels.'topology.kubernetes.io/zone' -eq $lostZone } | ForEach-Object { $_.metadata.name })
Log "Simulating the loss of $lostZone (nodes: $($zoneNodes -join ', ')); PostgreSQL stays in $pgZone"
$job = Start-Job -ArgumentList "$script:BaseUrl/api/dashboards/uid/dash-shared", 150 -ScriptBlock {
    param($Url, $Seconds)
    $ok = 0; $fail = 0; $errs = @()
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5 -DisableKeepAlive
            if ($r.StatusCode -eq 200) { $ok++ } else { $fail++ }
        } catch { $fail++; if ($errs.Count -lt 5) { $errs += $_.Exception.Message } }
        Start-Sleep -Milliseconds 200
    }
    [pscustomobject]@{ Ok = $ok; Fail = $fail; Errors = ($errs -join ' | ') }
}
Start-Sleep -Seconds 5
$drainOk = $true
foreach ($n in $zoneNodes) {
    $d = Exec 'kubectl' @('--context', $Ctx, 'drain', $n, '--ignore-daemonsets', '--delete-emptydir-data', '--force', '--timeout=300s')
    if ($d.Code -ne 0) { $drainOk = $false }
}
$survived = Wait-Until { (Get-ReadyGrafanaPods).Count -eq $Replicas } 300 "$Replicas replicas back in the remaining zone"
$load = Receive-Job -Job $job -Wait -AutoRemoveJob
$byZone = Get-ZonePlacement
$placement = ($byZone.Keys | Sort-Object | ForEach-Object { "$_=$($byZone[$_])" }) -join ' '
$detail = "drained $lostZone (drain ok=$drainOk); requests ok=$($load.Ok) failed=$($load.Fail); now: $placement"
if ($load.Errors) { $detail += "; errors: $($load.Errors)" }
if ($byZone[$QuorumZone] -gt 0) { Result 'T11' 'data zone lost' 'FAIL' "$detail (pods moved to the quorum zone)" }
elseif ($survived -and $load.Ok -gt 0 -and $load.Fail -eq 0) { Result 'T11' 'data zone lost' 'PASS' $detail }
elseif ($survived -and $load.Ok -gt 0 -and $load.Fail -le 3) { Result 'T11' 'data zone lost' 'WARN' $detail }
else { Result 'T11' 'data zone lost' 'FAIL' $detail }
Log "Restoring $lostZone (uncordon)"
foreach ($n in $zoneNodes) { Exec 'kubectl' @('--context', $Ctx, 'uncordon', $n) | Out-Null }

# T12 NetworkPolicy on PostgreSQL
function Probe-Postgres([string]$PodName, [string]$Labels) {
    K @('delete', 'pod', $PodName, '--ignore-not-found', '--wait=true') | Out-Null
    # Probe pod pinned to the data zones like every other workload (no quorum zone).
    $labelLines = ''
    if ($Labels) {
        foreach ($kv in ($Labels -split ',')) { $k, $v = $kv -split '=', 2; $labelLines += "`n    ${k}: `"$v`"" }
    }
    $zones = ($DataZones | ForEach-Object { "`n                  - $_" }) -join ''
    $yaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $PodName
  labels:
    app.kubernetes.io/name: np-probe$labelLines
spec:
  restartPolicy: Never
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values:$zones
  containers:
    - name: probe
      image: docker.io/library/postgres:18
      command: ["pg_isready", "-h", "grafana-postgresql", "-p", "5432", "-t", "8"]
"@
    $r = ($yaml | & kubectl --context $Ctx -n $Ns apply -f - 2>&1 | ForEach-Object { "$_" }) -join "`n"
    Add-Content -Path $LogFile -Value "> probe pod $PodName : $r" -Encoding UTF8
    Wait-Until {
        $p = KJson @('get', 'pod', $PodName)
        $p -and ($p.status.phase -eq 'Succeeded' -or $p.status.phase -eq 'Failed')
    } 180 "probe pod $PodName finished" | Out-Null
    $log = (K @('logs', $PodName)).Out
    K @('delete', 'pod', $PodName, '--ignore-not-found', '--wait=false') | Out-Null
    return $log
}
$denied  = Probe-Postgres 'np-probe-unlabelled' ''
$allowed = Probe-Postgres 'np-probe-labelled' 'grafana-db-client=true'
$detail = "unlabelled: '$($denied.Trim())'; labelled: '$($allowed.Trim())'"
if ($allowed -match 'accepting connections' -and $denied -notmatch 'accepting connections') { Result 'T12' 'NetworkPolicy on PostgreSQL' 'PASS' $detail }
elseif ($allowed -match 'accepting connections') { Result 'T12' 'NetworkPolicy on PostgreSQL' 'WARN' "$detail (policy not enforced by this cluster network plugin)" }
else { Result 'T12' 'NetworkPolicy on PostgreSQL' 'FAIL' $detail }

# T13 backup, simulated loss, restore
$jobName = 'backup-test-' + (Get-Date -Format 'yyyyMMddHHmmss')
Log "Running backup job $jobName"
K @('create', 'job', "--from=cronjob/grafana-db-backup", $jobName) | Out-Null
$bk = K @('wait', '--for=condition=complete', "job/$jobName", '--timeout=600s')
$bkLog = (K @('logs', "job/$jobName")).Out
if ($bk.Code -ne 0 -or $bkLog -notmatch 'backup written') {
    Result 'T13' 'backup and restore' 'FAIL' "backup job failed: $($bkLog.Trim())"
} else {
    $del = (Api 'DELETE' '/api/dashboards/uid/dash-shared').Status
    $gone = (Api 'GET' '/api/dashboards/uid/dash-shared').Status
    Log "Simulated loss: DELETE dash-shared HTTP $del, now GET HTTP $gone"
    Log 'Scaling Grafana to 0 for the restore'
    K @('scale', 'deployment/grafana', '--replicas=0') | Out-Null
    Wait-Until { (Get-GrafanaPods).Count -eq 0 } 300 'Grafana scaled to 0' | Out-Null
    K @('delete', 'job', 'grafana-db-restore', '--ignore-not-found') | Out-Null
    Exec 'kubectl' @('--context', $Ctx, 'apply', '-k', (Join-Path $PSScriptRoot 'restore-kind')) | Out-Null
    $rs = K @('wait', '--for=condition=complete', 'job/grafana-db-restore', '--timeout=600s')
    $rsLog = (K @('logs', 'job/grafana-db-restore')).Out
    Log "Scaling Grafana back to $Replicas"
    K @('scale', 'deployment/grafana', "--replicas=$Replicas") | Out-Null
    Wait-GrafanaReady $Replicas 600 | Out-Null
    $restored = (Api 'GET' '/api/dashboards/uid/dash-shared').Status
    if ($rs.Code -eq 0 -and $gone -ne 200 -and $restored -eq 200) {
        Result 'T13' 'backup and restore' 'PASS' 'dashboard deleted, database restored from the dump, dashboard back'
    } else {
        Result 'T13' 'backup and restore' 'FAIL' "restore rc=$($rs.Code), GET after delete=$gone, after restore=$restored; restore log: $($rsLog.Trim())"
    }
    K @('delete', 'job', 'grafana-db-restore', '--ignore-not-found') | Out-Null
}

# T14 standing rule: no workload of this namespace ever ran in the quorum zone
$allPods = KJson @('get', 'pods')
$inQuorum = @()
if ($allPods) {
    $inQuorum = @($allPods.items | Where-Object { $_.spec.nodeName -and $zoneOf[$_.spec.nodeName] -eq $QuorumZone } | ForEach-Object { $_.metadata.name })
}
$total = 0; if ($allPods) { $total = @($allPods.items).Count }
if ($inQuorum.Count -eq 0) { Result 'T14' 'quorum zone empty' 'PASS' "0 of $total pods in namespace $Ns ran in $QuorumZone" }
else { Result 'T14' 'quorum zone empty' 'FAIL' "pods in ${QuorumZone}: $($inQuorum -join ', ')" }

# --- Wrap up -------------------------------------------------------------------
Collect-Diagnostics
Stop-PortForward
Write-Summary
Write-Host ''
Write-Host "Grafana stays up at $script:BaseUrl (user admin, password in secret grafana-admin)."
Write-Host "The SSH tunnel (pid in $TunnelPidFile) stays open for that; -Destroy closes it."
Write-Host "Delete the test cluster with: powershell -ExecutionPolicy Bypass -File $(Join-Path $PSScriptRoot 'run-test.ps1') -Destroy"
$failed = @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failed -gt 0) { exit 1 } else { exit 0 }
