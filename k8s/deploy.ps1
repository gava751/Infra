[CmdletBinding()]
param(
    [string]$Profile = 'innoboard',
    [int]$Cpus = 4,
    [string]$Memory = '8192mb',
    [string]$DiskSize = '20g',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$k8sDir    = $PSScriptRoot
$infraDir  = Split-Path -Parent $k8sDir
$repoRoot  = Split-Path -Parent $infraDir

function Get-MinikubePath {
    $command = Get-Command minikube -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidate = Join-Path $env:LOCALAPPDATA 'Programs\minikube\minikube.exe'
    if (Test-Path $candidate) { return $candidate }
    throw 'minikube не найден. Установите его: https://minikube.sigs.k8s.io/docs/start/'
}

function Test-Docker {
    & docker info *> $null
    return ($LASTEXITCODE -eq 0)
}

$minikube = Get-MinikubePath
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl не найден в PATH.'
}

if (-not (Test-Docker)) {
    $dockerDesktop = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'
    if (-not (Test-Path $dockerDesktop)) {
        throw 'Docker Desktop не запущен и не найден. Запустите Docker Desktop вручную.'
    }
    Write-Host '==> Docker Desktop не запущен, запускаю...'
    Start-Process $dockerDesktop
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-Docker)) {
        if ((Get-Date) -gt $deadline) { throw 'Docker не запустился за 3 минуты.' }
        Start-Sleep -Seconds 5
    }
}

Write-Host "==> Запуск Minikube (profile=$Profile, cpus=$Cpus, memory=$Memory)"
& $minikube -p $Profile start --driver=docker --cpus=$Cpus --memory=$Memory --disk-size=$DiskSize
if ($LASTEXITCODE -ne 0) { throw 'minikube start завершился с ошибкой.' }

Write-Host '==> Включение ingress addon'
& $minikube -p $Profile addons enable ingress
if ($LASTEXITCODE -ne 0) { throw 'Не удалось включить ingress addon.' }

if (-not $SkipBuild) {
    $services = @('api-gateway', 'auth-service', 'user-service', 'order-service', 'payment-service')
    foreach ($service in $services) {
        $context = (Resolve-Path (Join-Path $repoRoot $service)).Path
        $image = "innoboard/${service}:latest"
        Write-Host "==> Сборка $image"
        & $minikube -p $Profile image build -t $image $context
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "minikube image build не удался для $service, пробую docker build + minikube image load"
            & docker build -t $image $context
            if ($LASTEXITCODE -ne 0) { throw "docker build завершился с ошибкой для $service." }
            & $minikube -p $Profile image load $image
            if ($LASTEXITCODE -ne 0) { throw "minikube image load завершился с ошибкой для $service." }
        }
    }
}

Write-Host '==> Подготовка секретов и JWT-ключей'
& (Join-Path $k8sDir 'prepare.ps1')

Write-Host '==> Применение манифестов'
& kubectl apply -k $k8sDir
if ($LASTEXITCODE -ne 0) { throw 'kubectl apply -k завершился с ошибкой.' }

Write-Host '==> Ожидание базы данных и Kafka'
$statefulSets = @('auth-postgres', 'user-postgres', 'order-postgres', 'payment-mongo', 'kafka')
foreach ($name in $statefulSets) {
    & kubectl -n innoboard rollout status "statefulset/$name" --timeout=600s
    if ($LASTEXITCODE -ne 0) { throw "StatefulSet $name не стал ready за 10 минут." }
}

Write-Host '==> Ожидание приложений'
$deployments = @('user-redis', 'order-redis', 'auth-service', 'user-service', 'order-service', 'payment-service', 'api-gateway')
foreach ($name in $deployments) {
    & kubectl -n innoboard rollout status "deployment/$name" --timeout=600s
    if ($LASTEXITCODE -ne 0) { throw "Deployment $name не стал ready за 10 минут." }
}

& kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s *> $null

Write-Host ''
Write-Host '==> Состояние кластера'
& kubectl -n innoboard get pods,svc,ingress

Write-Host ''
Write-Host 'Готово. Доступ снаружи (в отдельном терминале):'
Write-Host '  kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8080:80'
Write-Host '  curl.exe -H "Host: innoboard.local" http://localhost:8080/actuator/health'
Write-Host ''
Write-Host 'Альтернатива: minikube -p '"$Profile"' service -n ingress-nginx ingress-nginx-controller --url'
Write-Host '(печатает локальный адрес; запросы всё равно нужно слать с заголовком Host: innoboard.local)'
