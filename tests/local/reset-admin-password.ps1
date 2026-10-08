<#
.SYNOPSIS
  Set a new Grafana admin password on the local test cluster (letters and digits only).

.DESCRIPTION
  Grafana reads the admin password from the Secret only when it first creates
  the admin user; after that the password lives in PostgreSQL. This script
  therefore:
    1. generates a random password from A-Z, a-z, 0-9 (cryptographic RNG),
    2. changes it in Grafana through the API (authenticated with the current one),
    3. updates the Secret grafana-admin so both stay in sync,
    4. prints the new password on the console (never written to a file).

  Needs the SSH tunnel opened by run-test.ps1 (Grafana on http://localhost:3300).

.PARAMETER Length
  Password length (default 24).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File D:\grafana-openshift-ha\tests\local\reset-admin-password.ps1
#>
param([int]$Length = 24)

$ErrorActionPreference = 'Stop'
$Ctx = 'kind-grafana-ha'
$Ns = 'grafana'
$BaseUrl = 'http://localhost:3300'

function New-AlnumPassword([int]$Len) {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 1
    $sb = New-Object System.Text.StringBuilder
    while ($sb.Length -lt $Len) {
        $rng.GetBytes($bytes)
        # 248 = 62 * 4: reject higher values so every character is equally likely
        if ($bytes[0] -lt 248) { [void]$sb.Append($chars[$bytes[0] % 62]) }
    }
    return $sb.ToString()
}

function Get-SecretValue([string]$Name, [string]$Key) {
    $json = (& kubectl --context $Ctx -n $Ns get secret $Name -o json 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $null }
    $b64 = ($json | ConvertFrom-Json).data.$Key
    if (-not $b64) { return $null }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}

$user = Get-SecretValue 'grafana-admin' 'admin-user'
$old  = Get-SecretValue 'grafana-admin' 'admin-password'
if (-not $user -or -not $old) { Write-Host 'ERROR: secret grafana-admin not found in the test cluster.'; exit 1 }

$auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:$old")) }
try {
    $me = Invoke-RestMethod -Uri "$BaseUrl/api/user" -Headers $auth -UseBasicParsing -TimeoutSec 15
} catch {
    Write-Host "ERROR: cannot log in to Grafana at $BaseUrl with the password stored in the Secret."
    Write-Host '       Is the SSH tunnel up? Run run-test.ps1 -SkipDeploy first, or check the Secret.'
    exit 1
}

$new = New-AlnumPassword $Length
$body = @{ password = $new } | ConvertTo-Json -Compress
Invoke-RestMethod -Uri "$BaseUrl/api/admin/users/$($me.id)/password" -Method Put -Headers $auth `
    -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 15 | Out-Null

# Keep the Secret in sync (used by run-test.ps1 and by a fresh install).
$yaml = (& kubectl --context $Ctx -n $Ns create secret generic grafana-admin `
          "--from-literal=admin-user=$user" "--from-literal=admin-password=$new" `
          --dry-run=client -o yaml) -join "`n"
$yaml | & kubectl --context $Ctx -n $Ns apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'WARNING: Grafana password changed, but the Secret update failed.' }

# Verify the new password works.
$auth2 = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:$new")) }
try { Invoke-RestMethod -Uri "$BaseUrl/api/user" -Headers $auth2 -UseBasicParsing -TimeoutSec 15 | Out-Null }
catch { Write-Host 'ERROR: the new password does not work. Check Grafana logs.'; exit 1 }

Write-Host ''
Write-Host "Grafana URL : $BaseUrl"
Write-Host "User        : $user"
Write-Host "Password    : $new"
Write-Host ''
Write-Host 'Letters A-Z a-z and digits 0-9 only. Not written to any file.'
