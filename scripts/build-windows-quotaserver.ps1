param(
    [string]$Configuration = "release"
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if (-not $env:SWIFTPM_SCRATCH_PATH) {
    $env:SWIFTPM_SCRATCH_PATH = if ($IsWindows) { Join-Path $env:TEMP "aiusage-scratch" } else { "/tmp/aiusage-scratch" }
}

$packageRoot = Join-Path $repoRoot "QuotaBackend"
$distDir = Join-Path $repoRoot "dist"
$stagingDir = Join-Path $distDir "AIUsage-windows"
New-Item -ItemType Directory -Path $distDir -Force | Out-Null

Write-Host "Building AIUsage Windows app ($Configuration)"
$publishDir = Join-Path $packageRoot ".windows-publish"
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
& dotnet publish (Join-Path $repoRoot "WindowsApp/AIUsage.csproj") `
    --configuration $Configuration `
    --runtime win-x64 `
    --self-contained true `
    --output $publishDir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$binary = Join-Path $publishDir "AIUsage.exe"
if (-not (Test-Path $binary)) { throw "AIUsage.exe was not produced; check the .NET publish output." }

$stagedBinary = Join-Path $stagingDir "AIUsage.exe"
$zipPath = Join-Path $distDir "AIUsage-win64.zip"
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
Copy-Item -Path $binary -Destination $stagedBinary -Force

if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $stagedBinary -DestinationPath $zipPath -Force
Remove-Item $stagingDir -Recurse -Force
Remove-Item $publishDir -Recurse -Force

Write-Host "Windows package created: $zipPath"