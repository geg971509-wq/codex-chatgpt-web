# Independent distribution: in-place migration and recovery

This repository is maintained and updated by **geg971509-wq/codex-chatgpt-web**.
It is based on **miuuyy/codex-chatgpt-web**, whose copyright and licenses remain
unchanged. Historical upstream issue links and third-party download sources are
not this distribution's support or update channel.

## Compatibility contract (B2)

This distribution replaces the existing launcher; it is not a second installation
that can run against the same profile. The application name, macOS bundle ID,
Windows NSIS GUID, Linux wrapper, core home, Electron user-data directory and
browser partition deliberately remain compatible. The release repository and
`distribution-source` receipt identify the new publisher independently of those
installation identifiers. Do not rename the application identity simply to
rebrand it: doing so would invalidate the intended upgrade/profile relationship.

The existing upstream application cannot discover this fork through its updater.
The first switch must use **this repository's checked installer**. Subsequent
in-app update checks are pinned to this repository; there is no upstream fallback.
An inherited repository override pointing elsewhere is rejected by the installers.

## Before switching

Quit Codex and quit Codex Web GPT completely, including its tray/background
process. Stop any separately managed terminal daemon/tunnel. The installer checks
known process names and recorded runtime PIDs; it does not forcibly kill a process
or prove that an unrelated program is not writing the configuration. Do not launch
or edit either installation while migration or recovery is running.

Use the same user account and the same path overrides used for the old installation.
The installer honors `CODEX_CHATGPT_WEB_HOME`, `CODEX_HOME`,
`CODEX_WEB_GPT_LAUNCHER_DATA_DIR`, and the platform's launcher installation paths.
On Windows use 64-bit PowerShell (including Windows PowerShell 5.1); the same NSIS
registry identity resolves the existing application path. Symbolic-link/reparse-point
migration roots and overlapping backup locations are rejected rather than guessed.

A publisher change asks you to type **MIGRATE**. For an unattended, deliberately
approved migration, set `CODEX_WEB_GPT_ACCEPT_MIGRATION=1` explicitly. That flag
approves this installer operation; it is not a general authorization for a remote
agent to install software, publish a release or migrate another user's machine.
The target release must exist and its checksums must verify before installation.

## What is backed up

Before replacing files, the desktop installer creates a private recovery directory
under `~/.codex-web-gpt-migration-backups` (or `CODEX_WEB_GPT_BACKUP_DIR`). It records
both the existence and absence of each selected path, preserving:

- The core home, including its configuration, internal credential files and route
  journals; the Electron user-data directory, including its existing browser profile.
- The selected Codex home's `config.toml` and `models_cache.json`, not unrelated
  Codex histories or authentication stores.
- The prior macOS application bundle and the two standard legacy launch-agent
  plist files; or the Linux launcher library, wrapper, desktop entry, icon and
  autostart entry; or the registered Windows application and its install/uninstall
  registry entries.

POSIX copies are compared before installation. Windows file copies are checked
against source SHA-256 values. Recovery checks its saved file hashes before
restoring. POSIX recovery directories are mode 0700; Windows recovery directories
receive a non-inherited ACL for the current user. Backups contain sensitive data:
**never attach them to issues or diagnostic reports**. They are retained after
success and are not removed with temporary downloads. Delete them deliberately
only after validating the migration and deciding recovery is no longer needed.

External credential/profile files referenced from the configuration remain at
those paths and are **not** included in this installation snapshot. Neither system
keychains nor separately installed terminal binaries/services are copied or
recreated. Back them up through their own supported mechanism when applicable.
The existing launcher's setup transaction remains responsible for configured
external files it changes. Terminal-only cross-publisher takeover is deliberately
blocked; use the desktop migration entrypoint and its explicit Setup flow.

## Commit and failure behavior

Installers serialize against the same core home's `.migration-lock` and write the
new `distribution-source` receipt only after the installation step succeeds. The
launcher refuses to start its runtime while migration is locked or when pre-existing
core/browser data lacks this distribution's receipt. A missing or corrupt receipt
is not treated as consent. Fresh profiles can initialize normally.

Installation errors after replacement starts trigger **file-level recovery** and
retain the backup. Recovery stages replacement files and keeps copies of the
current files under `before-restore-*`. This is not a single atomic transaction
across filesystems, the Windows installer and operating-system services. A recovery
failure is reported and its backup is retained; it must not be described as success.

macOS ZIP/DMG drag-and-drop is **not a supported migration path** because it would
replace the old bundle before a recovery copy exists. Direct Windows installers
reject an existing registered installation unless invoked by the checked installer
or an already-approved in-app update. Use raw packages only for fresh installations
with no old profile; do not hand-create a receipt to bypass the migration gate.

Launcher startup reuses the existing reversible runtime/setup implementation. A
rejected configuration, failed login or unhealthy MCP tunnel still requires repair
or recovery. Starting a process is not proof that the migrated application is
healthy; backups are retained for that reason. Existing cookies may continue to
work because their identity/path is preserved, but encryption/keychain access and
server session expiry can still require reauthentication. No credentials are sent
to the new repository by the migration process.

## Recovering the previous installation

Quit both applications and stop their separately managed services first. Inspect
the backup path printed by the installer. On macOS/Linux run:

```sh
sh '/absolute/path/to/migration-backup/restore.sh' --confirm
```

On Windows run from 64-bit PowerShell:

```powershell
& 'C:\absolute\path\to\migration-backup\restore.ps1' -ConfirmRestore
```

Recovery restores the selected files/registry entries, including the previous
receipt (or its absence). Changes made after the snapshot are displaced; the
recovery command saves those current files under `before-restore-*`. It does not
silently reload launch agents, restart a tunnel, import a system keychain or start
either application. Restart the previous launcher yourself, re-check its Codex
route, then restart Codex. Keep both snapshots if any recovery step fails.

After a machine crash, an installer lock may remain. Before removing that exact
`.migration-lock` path, verify that no installer/launcher/runtime is still running.
A lock is not removed based on elapsed time or a guessed dead owner.

## Release acceptance

Do not infer release readiness from fixture tests. Before publishing, validate
native macOS and Windows replacement of an actual upstream installation, retained
configuration and login behavior, real MCP health, in-app updates, cancellation,
partial-install failure and recovery. Also verify platform signing/notarization
with the intended publisher credentials. CI ad-hoc signing only exercises package
integrity and startup; it is not notarized public-distribution approval.
