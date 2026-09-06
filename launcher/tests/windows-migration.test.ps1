$ErrorActionPreference = 'Stop'
# Exercise the actual installer's migration functions without downloading/running
# an installer or touching the runner's registered application.
$Source = Get-Content (Join-Path $PSScriptRoot '..\..\scripts\install-launcher.ps1') -Raw
$Tokens = $null; $Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$Tokens, [ref]$Errors)
if ($Errors.Count) { throw ($Errors | Out-String) }
$Functions = $Ast.FindAll({ param($Node) $Node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($Function in $Functions) { . ([scriptblock]::Create($Function.Extent.Text)) }
function Assert-Equal($Actual, $Expected) {
  if ($Actual -ne $Expected) { throw "Expected '$Expected', received '$Actual'" }
}
$Fixture = Join-Path ([IO.Path]::GetTempPath()) ("migration-test ' " + [guid]::NewGuid().ToString('N'))
$CoreHome = Join-Path $Fixture 'core'
$LauncherData = Join-Path $Fixture 'launcher data'
$CodexHome = Join-Path $Fixture 'codex'
$OldInstallLocation = Join-Path $Fixture 'application'
$BackupRoot = Join-Path $Fixture 'backups'
$SourceMarker = Join-Path $CoreHome 'distribution-source'
$Repository = 'geg971509-wq/codex-chatgpt-web'
$Version = '5.0.4'
$RegistryKeys = @()
$MigrationLock = $null
$SavedConsent = $env:CODEX_WEB_GPT_ACCEPT_MIGRATION
$env:CODEX_WEB_GPT_ACCEPT_MIGRATION = '1'
try {
  foreach ($Dir in @($CoreHome, $LauncherData, $CodexHome, $OldInstallLocation)) {
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  }
  [IO.File]::WriteAllText((Join-Path $CoreHome 'config.json'), '{"version":3}')
  [IO.File]::WriteAllText((Join-Path $LauncherData 'launcher-state.json'), '{"language":"zh-CN"}')
  [IO.File]::WriteAllText((Join-Path $LauncherData 'Cookies'), 'private-cookie-fixture')
  [IO.File]::WriteAllText((Join-Path $CodexHome 'config.toml'), 'old-route')
  [IO.File]::WriteAllText((Join-Path $OldInstallLocation 'Codex Web GPT.exe'), 'old-binary-fixture')
  Initialize-MigrationBackup
  Assert-Equal (Get-Content -LiteralPath (Join-Path $Backup 'core-home\config.json') -Raw) '{"version":3}'
  Assert-Equal (Get-Content -LiteralPath (Join-Path $Backup 'launcher-data\Cookies') -Raw) 'private-cookie-fixture'
  Assert-Equal (Get-Acl -LiteralPath $Backup).AreAccessRulesProtected $true
  $MigrationLock.Dispose(); $MigrationLock = $null
  Remove-Item -LiteralPath "$CoreHome.migration-lock"
  [IO.File]::WriteAllText((Join-Path $CodexHome 'config.toml'), 'new-route')
  [IO.File]::WriteAllText($SourceMarker, $Repository)
  # Refuse registry changes even if this test is accidentally run on a workstation
  # with a real installation. File restoration remains real filesystem I/O.
  function reg.exe { $global:LASTEXITCODE = 0 }
  # Both preflight and recovery distinguish absent metadata from corrupt/live ownership.
  $Runtime = Join-Path $CoreHome 'runtime'
  $Descriptor = Join-Path $Runtime 'launcher-browser.json'
  New-Item -ItemType Directory -Path $Runtime | Out-Null
  foreach ($Metadata in @('{not-json', ('{"pid":' + $PID + '}'))) {
    [IO.File]::WriteAllText($Descriptor, $Metadata)
    $Rejected = $false
    try { Assert-MigrationStopped } catch { $Rejected = $true }
    Assert-Equal $Rejected $true
    $Rejected = $false
    try { & (Join-Path $Backup 'restore.ps1') -ConfirmRestore } catch { $Rejected = $true }
    Assert-Equal $Rejected $true
    Assert-Equal (Get-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Raw) 'new-route'
  }
  Remove-Item -LiteralPath $Descriptor
  Assert-MigrationStopped
  & (Join-Path $Backup 'restore.ps1') -ConfirmRestore
  Assert-Equal (Get-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Raw) 'old-route'
  Assert-Equal (Test-Path -LiteralPath $SourceMarker) $false
  [IO.File]::WriteAllText((Join-Path $Backup 'core-home\config.json'), 'corrupt-backup')
  [IO.File]::WriteAllText((Join-Path $CodexHome 'config.toml'), 'preserve-current-route')
  $Rejected = $false
  try { & (Join-Path $Backup 'restore.ps1') -ConfirmRestore } catch { $Rejected = $true }
  Assert-Equal $Rejected $true
  Assert-Equal (Get-Content -LiteralPath (Join-Path $CodexHome 'config.toml') -Raw) 'preserve-current-route'
  $BackupRoot = Join-Path $CoreHome 'nested-backup'
  $Rejected = $false
  try { Initialize-MigrationBackup } catch { $Rejected = $true }
  Assert-Equal $Rejected $true
  Assert-Equal (Test-Path -LiteralPath $BackupRoot) $false
  Write-Output 'WINDOWS_MIGRATION_FIXTURES_OK'
} finally {
  if ($MigrationLock) { $MigrationLock.Dispose() }
  $env:CODEX_WEB_GPT_ACCEPT_MIGRATION = $SavedConsent
  Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
}
