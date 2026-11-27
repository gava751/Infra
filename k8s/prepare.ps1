[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$k8sDir    = $PSScriptRoot
$infraDir  = Split-Path -Parent $k8sDir
$repoRoot  = Split-Path -Parent $infraDir
$envFile   = Join-Path $infraDir '.env'
$secrets   = Join-Path $k8sDir 'secrets.env'
$keysDir   = Join-Path $k8sDir 'keys'

if (-not (Test-Path $envFile)) {
    throw "Не найден $envFile. Скопируйте infra/.env.example в infra/.env и заполните значения."
}

$vars = [ordered]@{}
foreach ($line in Get-Content -Path $envFile) {
    $trimmed = $line.Trim()
    if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
    $separator = $trimmed.IndexOf('=')
    if ($separator -lt 1) { continue }
    $key   = $trimmed.Substring(0, $separator).Trim()
    $value = $trimmed.Substring($separator + 1).Trim()
    $vars[$key] = $value
}

$required = @(
    'AUTH_POSTGRES_USER', 'AUTH_POSTGRES_PASSWORD', 'AUTH_POSTGRES_DB',
    'USER_POSTGRES_USER', 'USER_POSTGRES_PASSWORD', 'USER_POSTGRES_DB',
    'ORDER_POSTGRES_USER', 'ORDER_POSTGRES_PASSWORD', 'ORDER_POSTGRES_DB',
    'PAYMENT_MONGO_USER', 'PAYMENT_MONGO_PASSWORD', 'PAYMENT_MONGO_DB',
    'INTERNAL_SERVICE_TOKEN', 'JWT_KEY_ID'
)

foreach ($key in $required) {
    if (-not $vars.Contains($key) -or [string]::IsNullOrWhiteSpace($vars[$key])) {
        throw "В infra/.env не задано обязательное значение $key"
    }
}

$vars['AUTH_DB_URL']  = "jdbc:postgresql://auth-postgres:5432/$($vars['AUTH_POSTGRES_DB'])"
$vars['USER_DB_URL']  = "jdbc:postgresql://user-postgres:5432/$($vars['USER_POSTGRES_DB'])"
$vars['ORDER_DB_URL'] = "jdbc:postgresql://order-postgres:5432/$($vars['ORDER_POSTGRES_DB'])"
$vars['PAYMENT_MONGO_URI'] = "mongodb://$($vars['PAYMENT_MONGO_USER']):$($vars['PAYMENT_MONGO_PASSWORD'])@payment-mongo:27017/$($vars['PAYMENT_MONGO_DB'])?authSource=admin"

$lines = foreach ($entry in $vars.GetEnumerator()) { "$($entry.Key)=$($entry.Value)" }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($secrets, [string[]]$lines, $utf8NoBom)
Write-Host "Создан $secrets"

New-Item -ItemType Directory -Force -Path $keysDir | Out-Null
$keyFiles = @{
    'jwt-private.pem' = Join-Path $repoRoot 'auth-service\keys\jwt-private.pem'
    'jwt-public.pem'  = Join-Path $repoRoot 'auth-service\keys\jwt-public.pem'
}
foreach ($name in $keyFiles.Keys) {
    $source = $keyFiles[$name]
    if (-not (Test-Path $source)) {
        throw "Не найден $source. Сгенерируйте ключи по инструкции из auth-service/README.md."
    }
    Copy-Item -Path $source -Destination (Join-Path $keysDir $name) -Force
}
Write-Host "Скопированы JWT-ключи в $keysDir"
