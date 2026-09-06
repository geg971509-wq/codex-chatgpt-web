$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ($PSVersionTable.PSVersion.Major -lt 6) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Operation,
    [Parameter(Mandatory = $true)][string]$Label
  )
  for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
    try {
      return & $Operation
    } catch {
      if ($Attempt -eq 3) {
        throw "$Label failed after $Attempt attempts: $($_.Exception.Message)"
      }
      Start-Sleep -Seconds (2 * $Attempt)
    }
  }
}

function Test-IsFullyQualifiedWindowsPath {
  param([AllowEmptyString()][string]$Path)
  return $Path -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$))'
}

# B2 migration: snapshot before the installer can replace application files.
function Resolve-MigrationPath {
  param([string]$Path)
  if ($Path -eq '~') { $Path = $HOME }
  elseif ($Path.StartsWith('~/') -or $Path.StartsWith('~\')) { $Path = Join-Path $HOME $Path.Substring(2) }
  if (-not (Test-IsFullyQualifiedWindowsPath $Path)) { throw "Migration requires an absolute path: $Path" }
  return [IO.Path]::GetFullPath($Path)
}
function Assert-MigrationStopped {
  if ((Get-Process -Name 'Codex Web GPT', 'codex' -ErrorAction SilentlyContinue)) {
    throw 'Quit Codex Web GPT and Codex before migration. No process is killed automatically.'
  }
  foreach ($Name in @('launcher-browser.json', 'launcher-supervisor.json')) {
    $StateFile = Join-Path $CoreHome "runtime\$Name"
    try { $StateText = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { continue }
    # Missing optional metadata is normal; unreadable or corrupt metadata is not.
    $State = $StateText | ConvertFrom-Json
    foreach ($Field in @('pid', 'ownerPid', 'daemonPid', 'tunnelPid')) {
      $OwnerPid = $State.$Field
      if ($OwnerPid -and (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)) {
        throw "An existing runtime (PID $OwnerPid) is still running. Quit it before migration."
      }
    }
  }
}
function Backup-MigrationItem {
  param([string]$Label, [string]$Target)
  $Target = Resolve-MigrationPath $Target
  if ($Target.TrimEnd('\') -eq [IO.Path]::GetPathRoot($Target).TrimEnd('\') -or
      $Target.TrimEnd('\') -eq $HOME.TrimEnd('\') -or
      $Backup.StartsWith($Target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe backup target: $Target"
  }
  $Present = Test-Path -LiteralPath $Target
  if ($Present) {
    $Item = Get-Item -LiteralPath $Target -Force
    $Items = @($Item)
    if ($Item.PSIsContainer) { $Items += @(Get-ChildItem -LiteralPath $Target -Force -Recurse) }
    if ($Items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
      throw "Migration refuses a reparse point under $Target; use a physical data directory"
    }
    $Destination = Join-Path $Backup $Label
    Copy-Item -LiteralPath $Target -Destination $Destination -Recurse -Force
    foreach ($File in $Items | Where-Object { -not $_.PSIsContainer }) {
      $Copy = if ($Item.PSIsContainer) { Join-Path $Destination $File.FullName.Substring($Target.TrimEnd('\').Length + 1) } else { $Destination }
      if ((Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $Copy -Algorithm SHA256).Hash) { throw "Backup verification failed: $($File.FullName)" }
    }
  }
  $script:MigrationItems += [pscustomobject]@{ label = $Label; target = $Target; present = $Present }
}
function Initialize-MigrationBackup {
  foreach ($Target in @($CoreHome, $LauncherData, $CodexHome, $OldInstallLocation) | Where-Object { $_ }) {
    $Full = (Resolve-MigrationPath $Target).TrimEnd('\')
    if ($BackupRoot.StartsWith($Full + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $BackupRoot.TrimEnd('\') -eq $Full -or $Full -eq $HOME.TrimEnd('\')) { throw "Backup root overlaps $Target" }
  }
  New-Item -ItemType Directory -Path (Split-Path $CoreHome) -Force | Out-Null
  $script:MigrationLock = [IO.File]::Open("$CoreHome.migration-lock", [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  Assert-MigrationStopped
  $PreviousSource = if (Test-Path -LiteralPath $SourceMarker) { (Get-Content -LiteralPath $SourceMarker -Raw).Trim() } else { 'unrecorded (possibly upstream)' }
  $HasPriorData = $OldInstallLocation -or (Test-Path -LiteralPath (Join-Path $CoreHome 'config.json')) -or (Test-Path -LiteralPath (Join-Path $LauncherData 'launcher-state.json')) -or (Test-Path -LiteralPath (Join-Path $LauncherData 'Partitions')) -or (Test-Path -LiteralPath $SourceMarker)
  if ($HasPriorData -and $PreviousSource -ne $Repository) {
    Write-Host "This replaces the existing application. Publisher: $PreviousSource -> $Repository"
    Write-Host 'Local configuration and browser profile will be backed up; login survival is not guaranteed.'
    if ($env:CODEX_WEB_GPT_ACCEPT_MIGRATION -ne '1') {
      if ((Read-Host 'Type MIGRATE to confirm') -cne 'MIGRATE') { throw 'Migration cancelled; installation unchanged' }
    }
  }
  if ((Test-Path -LiteralPath $BackupRoot) -and
      ((Get-Item -LiteralPath $BackupRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Backup root cannot be a reparse point'
  }
  New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
  $script:Backup = Join-Path $BackupRoot ("migration-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $Backup | Out-Null
  # Protect inherited credential/cookie copies, including on systems with shared parent ACLs.
  $Acl = New-Object System.Security.AccessControl.DirectorySecurity
  $Acl.SetAccessRuleProtection($true, $false)
  $Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $Rule = New-Object Security.AccessControl.FileSystemAccessRule($Sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
  $Acl.AddAccessRule($Rule)
  Set-Acl -LiteralPath $Backup -AclObject $Acl
  $script:MigrationItems = @()
  Backup-MigrationItem 'core-home' $CoreHome
  Backup-MigrationItem 'launcher-data' $LauncherData
  Backup-MigrationItem 'codex-config' (Join-Path $CodexHome 'config.toml')
  Backup-MigrationItem 'codex-models' (Join-Path $CodexHome 'models_cache.json')
  if ($OldInstallLocation) { Backup-MigrationItem 'application' $OldInstallLocation }
  $MigrationItems | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Backup 'files.json') -Encoding UTF8
  foreach ($Key in $RegistryKeys) {
    $Index = [array]::IndexOf($RegistryKeys, $Key)
    if (Test-Path -LiteralPath $Key.Replace('HKCU\', 'HKCU:\')) {
      & reg.exe export $Key (Join-Path $Backup "registry-$Index.reg") /y | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "Could not back up $Key" }
    }
  }
  # Store a self-contained, explicitly invoked recovery script with the private backup.
  @'
param([switch]$ConfirmRestore)
$ErrorActionPreference = 'Stop'
if (-not $ConfirmRestore) { throw 'Quit Codex Web GPT and Codex, then run restore.ps1 -ConfirmRestore' }
if (Get-Process -Name 'Codex Web GPT', 'codex' -ErrorAction SilentlyContinue) { throw 'Quit both applications before recovery' }
$Root = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $Root 'backup-complete'))) { throw 'Backup incomplete; nothing restored' }
$Hashes = Get-Content -LiteralPath (Join-Path $Root 'hashes.json') -Raw | ConvertFrom-Json
foreach ($Record in $Hashes) {
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Root $Record.path)).Hash -ne $Record.sha256) {
    throw "Backup integrity failure: $($Record.path)"
  }
}
$Saved = Join-Path $Root ('before-restore-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Saved | Out-Null
$Items = @(Get-Content -LiteralPath (Join-Path $Root 'files.json') -Raw | ConvertFrom-Json)
$Core = ($Items | Where-Object { $_.label -eq 'core-home' }).target
foreach ($Name in @('launcher-browser.json', 'launcher-supervisor.json')) {
  $StatePath = Join-Path $Core "runtime\$Name"
  try { $StateText = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop }
  catch [System.Management.Automation.ItemNotFoundException] { continue }
  # Keep parsing outside the missing-file handler: malformed ownership must fail.
  $State = $StateText | ConvertFrom-Json
  foreach ($Field in @('pid', 'ownerPid', 'daemonPid', 'tunnelPid')) {
    if ($State.$Field -and (Get-Process -Id $State.$Field -ErrorAction SilentlyContinue)) { throw 'Stop the recorded runtime before recovery' }
  }
}
foreach ($Item in $Items) {
  if (Test-Path -LiteralPath $Item.target) {
    Copy-Item -LiteralPath $Item.target -Destination (Join-Path $Saved $Item.label) -Recurse -Force
  }
  if ($Item.present) {
    $Next = $Item.target + '.restore-' + [guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path (Split-Path $Item.target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root $Item.label) -Destination $Next -Recurse -Force
    $Previous = $Item.target + '.before-restore-' + [guid]::NewGuid().ToString('N')
    $HadPrevious = Test-Path -LiteralPath $Item.target
    if ($HadPrevious) { Move-Item -LiteralPath $Item.target -Destination $Previous }
    try { Move-Item -LiteralPath $Next -Destination $Item.target }
    catch { if ($HadPrevious) { Move-Item -LiteralPath $Previous -Destination $Item.target }; throw }
    if ($HadPrevious) { Remove-Item -LiteralPath $Previous -Recurse -Force }
  } elseif (Test-Path -LiteralPath $Item.target) {
    Remove-Item -LiteralPath $Item.target -Recurse -Force
  }
}
$Keys = @('HKCU\Software\d1a6026a-6210-588e-9a2b-da3936f94e02', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{d1a6026a-6210-588e-9a2b-da3936f94e02}')
foreach ($Key in $Keys) {
  if (Test-Path -LiteralPath $Key.Replace('HKCU\', 'HKCU:\')) { & reg.exe delete $Key /f | Out-Null; if ($LASTEXITCODE -ne 0) { throw "Could not restore $Key" } }
}
Get-ChildItem -LiteralPath $Root -Filter 'registry-*.reg' | ForEach-Object {
  & reg.exe import $_.FullName | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Registry recovery failed: $($_.Name)" }
}
Write-Host 'Files restored. Restart the previous launcher and verify the Codex route before resuming work.'
'@ | Set-Content -LiteralPath (Join-Path $Backup 'restore.ps1') -Encoding UTF8
  $Hashes = @(Get-ChildItem -LiteralPath $Backup -Recurse -File -Force | ForEach-Object {
    [pscustomobject]@{ path = $_.FullName.Substring($Backup.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
  })
  $Hashes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $Backup 'hashes.json') -Encoding UTF8
  "repository=$Repository`nversion=$Version" | Set-Content -LiteralPath (Join-Path $Backup 'backup-complete') -Encoding UTF8
  Write-Host "Recovery backup: $Backup"
}

$Repository = if ($env:CODEX_WEB_GPT_REPOSITORY) { $env:CODEX_WEB_GPT_REPOSITORY } else { "geg971509-wq/codex-chatgpt-web" }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
  throw "Invalid GitHub repository: $Repository"
}
if ($Repository -ne 'geg971509-wq/codex-chatgpt-web') { throw 'This installer only trusts geg971509-wq/codex-chatgpt-web; remove the repository override' }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell so migration reads the same registry view as the x64 installer' }
$CoreHome = Resolve-MigrationPath $(if ($env:CODEX_CHATGPT_WEB_HOME) { $env:CODEX_CHATGPT_WEB_HOME } else { Join-Path $HOME '.codex-chatgpt-web' })
$CodexHome = Resolve-MigrationPath $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' })
$LauncherData = Resolve-MigrationPath $(if ($env:CODEX_WEB_GPT_LAUNCHER_DATA_DIR) { $env:CODEX_WEB_GPT_LAUNCHER_DATA_DIR } else { Join-Path $env:APPDATA 'Codex Web GPT' })
$BackupRoot = Resolve-MigrationPath $(if ($env:CODEX_WEB_GPT_BACKUP_DIR) { $env:CODEX_WEB_GPT_BACKUP_DIR } else { Join-Path $HOME '.codex-web-gpt-migration-backups' })
$SourceMarker = Join-Path $CoreHome 'distribution-source'
$InstallRegistry = "HKCU:\Software\d1a6026a-6210-588e-9a2b-da3936f94e02"
$RegistryKeys = @('HKCU\Software\d1a6026a-6210-588e-9a2b-da3936f94e02', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{d1a6026a-6210-588e-9a2b-da3936f94e02}')
$OldInstallLocation = if (Test-Path -LiteralPath $InstallRegistry) { [string](Get-ItemPropertyValue -LiteralPath $InstallRegistry -Name 'InstallLocation') } else { $null }
$Backup = $null
$MigrationLock = $null
$Mutated = $false
$Version = $env:CODEX_WEB_GPT_VERSION
if (-not $Version) {
  $Release = Invoke-WithRetry -Label "Resolving the latest release" -Operation {
    Invoke-RestMethod "https://api.github.com/repos/$Repository/releases/latest" -TimeoutSec 60
  }
  $Version = [string]$Release.tag_name
}
if ($Version -and $Version.StartsWith("v")) { $Version = $Version.Substring(1) }
if (-not $Version) { throw "Could not resolve the latest Codex Web GPT release" }
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$') { throw "Invalid release version: $Version" }

if (-not [Environment]::Is64BitOperatingSystem) {
  throw "The packaged Windows launcher requires 64-bit Windows"
}
$Arch = "x64"

$Asset = "codex-web-gpt-$Version-win-$Arch.exe"
$BaseUrl = "https://github.com/$Repository/releases/download/v$Version"
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) "codex-web-gpt-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $Temp | Out-Null
try {
  if (Get-Process -Name "Codex Web GPT" -ErrorAction SilentlyContinue) {
    throw "Quit Codex Web GPT before updating it"
  }
  $Installer = Join-Path $Temp $Asset
  $Checksums = Join-Path $Temp "checksums.txt"
  $null = Invoke-WithRetry -Label "Downloading $Asset" -Operation {
    Remove-Item $Installer -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest "$BaseUrl/$Asset" -OutFile $Installer -TimeoutSec 900 -UseBasicParsing
  }
  $null = Invoke-WithRetry -Label "Downloading checksums.txt" -Operation {
    Remove-Item $Checksums -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest "$BaseUrl/checksums.txt" -OutFile $Checksums -TimeoutSec 60 -UseBasicParsing
  }
  $ExpectedLine = Get-Content $Checksums | Where-Object { $_ -match "\s$([regex]::Escape($Asset))$" } | Select-Object -First 1
  if (-not $ExpectedLine) { throw "checksums.txt has no entry for $Asset" }
  $Expected = ($ExpectedLine -split "\s+")[0].ToLowerInvariant()
  $Actual = (Get-FileHash -Algorithm SHA256 $Installer).Hash.ToLowerInvariant()
  if ($Actual -ne $Expected) { throw "SHA-256 verification failed for $Asset" }
  Initialize-MigrationBackup
  Assert-MigrationStopped
  $Mutated = $true
  $Process = Start-Process -FilePath $Installer -ArgumentList "/S", "/currentuser", "/MIGRATION_PREPARED" -Wait -PassThru
  if ($Process.ExitCode -ne 0) { throw "Installer exited with code $($Process.ExitCode)" }
  $InstallRegistry = "HKCU:\Software\d1a6026a-6210-588e-9a2b-da3936f94e02"
  $InstallLocation = [string](Get-ItemPropertyValue -LiteralPath $InstallRegistry -Name "InstallLocation")
  if (-not (Test-IsFullyQualifiedWindowsPath $InstallLocation)) {
    throw "Installer recorded an invalid InstallLocation: $InstallLocation"
  }
  $Executable = Join-Path $InstallLocation "Codex Web GPT.exe"
  if (-not (Test-Path $Executable)) { throw "Installed launcher was not found at $Executable" }
  New-Item -ItemType Directory -Path $CoreHome -Force | Out-Null
  [IO.File]::WriteAllText("$SourceMarker.next", "$Repository`n", (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath "$SourceMarker.next" -Destination $SourceMarker -Force
  # The backup remains after launch; creating a process is not a health check.
  $MigrationLock.Dispose()
  $MigrationLock = $null
  Remove-Item -LiteralPath "$CoreHome.migration-lock"
  Start-Process $Executable
  $Mutated = $false
  Write-Host "Installed $Executable"
} catch {
  $OriginalError = $_
  if ($Mutated -and $Backup) {
    try { & (Join-Path $Backup 'restore.ps1') -ConfirmRestore }
    catch { Write-Warning "Automatic file recovery failed: $_. Keep the backup at $Backup" }
  }
  throw $OriginalError
} finally {
  if ($MigrationLock) { $MigrationLock.Dispose(); Remove-Item -LiteralPath "$CoreHome.migration-lock" -Force }
  Remove-Item -Recurse -Force $Temp -ErrorAction SilentlyContinue
}
