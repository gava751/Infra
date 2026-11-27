[CmdletBinding()]
param(
    [string]$Namespace = 'innoboard',
    [string]$Host_ = 'innoboard.local',
    [int]$LocalPort = 8080
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Write-Host '==> Pods'
& kubectl -n $Namespace get pods -o wide
if ($LASTEXITCODE -ne 0) { throw "Не удалось получить pod'ы." }

Write-Host ''
Write-Host "==> Проверка Service discovery из pod'а api-gateway"
$backends = @(
    @{ Name = 'auth-service';    Port = 8081 },
    @{ Name = 'user-service';    Port = 8082 },
    @{ Name = 'order-service';   Port = 8083 },
    @{ Name = 'payment-service'; Port = 8084 }
)
foreach ($backend in $backends) {
    $url = "http://$($backend.Name):$($backend.Port)/actuator/health"
    Write-Host -NoNewline "$url -> "
    $body = & kubectl -n $Namespace exec deploy/api-gateway -c api-gateway -- curl -fsS $url 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Health check failed: $url" }
    Write-Host $body
}

Write-Host -NoNewline "http://localhost:8080/actuator/health (gateway) -> "
$gatewayBody = & kubectl -n $Namespace exec deploy/api-gateway -c api-gateway -- curl -fsS http://localhost:8080/actuator/health 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Gateway health check failed.' }
Write-Host $gatewayBody

Write-Host ''
Write-Host '==> StatefulSet / Deployment rollout'
& kubectl -n $Namespace get statefulsets,deployments

Write-Host ''
Write-Host '==> Ingress'
& kubectl -n $Namespace get ingress

Write-Host ''
Write-Host "==> Проверка Ingress через port-forward на localhost:$LocalPort"
$forward = Start-Job -ScriptBlock {
    param($ns, $port)
    kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller "${port}:80" 2>&1
} -ArgumentList $Namespace, $LocalPort

try {
    $healthCode = ''
    for ($i = 0; $i -lt 60; $i++) {
        $healthCode = (curl.exe -s -o NUL -w '%{http_code}' -H "Host: $Host_" "http://localhost:$LocalPort/actuator/health" 2>$null)
        if ($healthCode -eq '200') { break }
        Start-Sleep -Milliseconds 500
    }
    if ($healthCode -ne '200') { throw "Ingress вернул HTTP $healthCode вместо 200." }
    Write-Host "http://$Host_/actuator/health -> HTTP 200"

    $unknownCode = (curl.exe -s -o NUL -w '%{http_code}' -H 'Host: unknown.local' "http://localhost:$LocalPort/actuator/health" 2>$null)
    Write-Host "http://unknown.local/actuator/health -> HTTP $unknownCode (ожидается 404)"
}
finally {
    Stop-Job $forward -ErrorAction SilentlyContinue
    Remove-Job $forward -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Проверки пройдены.'
