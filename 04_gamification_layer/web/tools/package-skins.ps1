param(
  [switch]$NoZip
)

# Packages each skin per framework into web/dist/<framework>-<skin>/ and a zip archive.
# - Copies the skin folder
# - Copies shared/ into the package
# - Rewrites shared path references in index files to ./shared

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$webRoot = Resolve-Path (Join-Path $scriptDir "..")
$dist = Join-Path $webRoot "dist"

if (-not (Test-Path $dist)) { New-Item -ItemType Directory -Path $dist | Out-Null }

function Package-Skin {
  param(
    [string]$Framework,
    [string]$SkinPath,  # absolute path to skin dir
    [string]$SkinName,
    [string]$IndexFileName  # index.html or index.php
  )
  $packageName = "$Framework-$SkinName"
  $outDir = Join-Path $dist $packageName
  if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
  New-Item -ItemType Directory -Path $outDir | Out-Null

  # Copy skin content
  Copy-Item -Recurse -Force (Join-Path $SkinPath "*") $outDir

  # Copy shared content next to index
  Copy-Item -Recurse -Force (Join-Path $webRoot "shared") (Join-Path $outDir "shared")

  # Rewrite shared paths inside index.* to be ./shared
  $indexPath = Join-Path $outDir $IndexFileName
  if (Test-Path $indexPath) {
    $content = Get-Content $indexPath -Raw
    $content = $content -replace "\.{2,}/shared", "./shared"
    Set-Content -Path $indexPath -Value $content -Encoding UTF8
  }

  if (-not $NoZip) {
    $zipPath = Join-Path $dist ("$packageName.zip")
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath
  }

  Write-Host ("Packaged: {0} -> {1}" -f $packageName, $outDir)
}

# HTML skins
Get-ChildItem -Directory (Join-Path $webRoot 'frameworks/html/skins') | ForEach-Object {
  $skinName = $_.Name
  Package-Skin -Framework 'html' -SkinPath $_.FullName -SkinName $skinName -IndexFileName 'index.html'
}

# PHP skins
Get-ChildItem -Directory (Join-Path $webRoot 'frameworks/php/public/skins') | ForEach-Object {
  $skinName = $_.Name
  Package-Skin -Framework 'php' -SkinPath $_.FullName -SkinName $skinName -IndexFileName 'index.php'
}

# Vue skins
Get-ChildItem -Directory (Join-Path $webRoot 'frameworks/vue/public/skins') | ForEach-Object {
  $skinName = $_.Name
  Package-Skin -Framework 'vue' -SkinPath $_.FullName -SkinName $skinName -IndexFileName 'index.html'
}

Write-Host "Done. Output in: $dist"
