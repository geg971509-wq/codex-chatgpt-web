#!/bin/sh
set -eu

REPOSITORY="${CODEX_WEB_GPT_REPOSITORY:-geg971509-wq/codex-chatgpt-web}"
VERSION="${CODEX_WEB_GPT_VERSION:-}"
OS="$(uname -s)"
MACHINE="$(uname -m)"

if ! printf '%s\n' "$REPOSITORY" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  echo "Invalid GitHub repository: $REPOSITORY" >&2
  exit 1
fi

if [ "$REPOSITORY" != "geg971509-wq/codex-chatgpt-web" ]; then
  echo "This installer only trusts geg971509-wq/codex-chatgpt-web; remove the repository override" >&2
  exit 1
fi

case "$OS" in
  Darwin)
    PLATFORM="mac"
    EXTENSION="zip"
    case "$MACHINE" in
      arm64|aarch64) ARCH="arm64" ;;
      x86_64|amd64) ARCH="x64" ;;
      *) echo "Unsupported macOS architecture: $MACHINE" >&2; exit 1 ;;
    esac
    ;;
  Linux)
    PLATFORM="linux"
    EXTENSION="AppImage"
    case "$MACHINE" in
      x86_64|amd64) ARCH="x64" ;;
      *) echo "The packaged Linux launcher currently supports x86_64; detected $MACHINE" >&2; exit 1 ;;
    esac
    ;;
  *) echo "Use install-launcher.ps1 on Windows; unsupported OS: $OS" >&2; exit 1 ;;
esac

# B2 keeps application/data identities, but a publisher change is never implicit.
umask 077
absolute_path() {
  case "$1" in
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    /*) printf '%s\n' "$1" ;;
    *) echo "Migration requires an absolute path: $1" >&2; exit 1 ;;
  esac
}
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}
CORE_HOME="$(absolute_path "${CODEX_CHATGPT_WEB_HOME:-$HOME/.codex-chatgpt-web}")"
CODEX_DIR="$(absolute_path "${CODEX_HOME:-$HOME/.codex}")"
if [ "$OS" = "Darwin" ]; then
  DEFAULT_DATA="$HOME/Library/Application Support/Codex Web GPT"
else
  DEFAULT_DATA="${XDG_CONFIG_HOME:-$HOME/.config}/Codex Web GPT"
fi
LAUNCHER_DATA="$(absolute_path "${CODEX_WEB_GPT_LAUNCHER_DATA_DIR:-$DEFAULT_DATA}")"
SOURCE_MARKER="$CORE_HOME/distribution-source"
BACKUP_ROOT="$(absolute_path "${CODEX_WEB_GPT_BACKUP_DIR:-$HOME/.codex-web-gpt-migration-backups}")"
BACKUP_DIR=""
MUTATED=0
LOCK_HELD=0
assert_stopped() {
  if pgrep -x "Codex Web GPT" >/dev/null 2>&1 || pgrep -x codex >/dev/null 2>&1; then
    echo "Quit Codex Web GPT and Codex before migration; no process will be killed automatically" >&2
    return 1
  fi
  for state in "$CORE_HOME/runtime/launcher-browser.json" "$CORE_HOME/runtime/launcher-supervisor.json"; do
    [ -f "$state" ] || continue
    for pid in $(tr ',' '\n' < "$state" | sed -n 's/.*"\(pid\|ownerPid\|daemonPid\|tunnelPid\)"[[:space:]]*:[[:space:]]*\([1-9][0-9]*\).*/\2/p'); do
      if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
        echo "An existing runtime (PID $pid) is still running. Quit it before migration" >&2
        return 1
      fi
    done
  done
}
confirm_migration() {
  old_source="unrecorded (possibly upstream)"
  if [ -f "$SOURCE_MARKER" ]; then old_source="$(cat "$SOURCE_MARKER")"; fi
  if [ "$old_source" = "$REPOSITORY" ]; then return; fi
  printf '%s\n' "This installer replaces the existing application in place." \
    "Previous distribution: $old_source" "New distribution: $REPOSITORY" \
    "Application, local configuration and browser profile backups will remain under $BACKUP_ROOT." \
    "External credential files are kept at their current paths, not imported. Login survival is not guaranteed."
  if [ "${CODEX_WEB_GPT_ACCEPT_MIGRATION:-}" = "1" ]; then return; fi
  if [ ! -r /dev/tty ] || ! ( : </dev/tty ) 2>/dev/null; then
    echo "Migration needs confirmation. Read docs/distribution-migration.md, then explicitly set CODEX_WEB_GPT_ACCEPT_MIGRATION=1" >&2
    return 1
  fi
  printf 'Type MIGRATE to confirm: ' >/dev/tty
  read -r answer </dev/tty
  [ "$answer" = "MIGRATE" ] || { echo "Migration cancelled; installation unchanged" >&2; return 1; }
}
backup_item() {
  label="$1"; target="$2"
  case "$target" in /|"$HOME"|"$HOME/"|*'/../'*|*/..) echo "Unsafe backup target: $target" >&2; exit 1 ;; esac
  case "$BACKUP_DIR/" in "$target/"*) echo "Backup destination overlaps $target" >&2; exit 1 ;; esac
  # Configuration roots may not silently redirect the replacement elsewhere.
  if [ -L "$target" ] && [ "$label" != "legacy-wrapper" ]; then
    echo "Migration refuses a symbolic-link target: $target" >&2; exit 1
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    cp -pRP "$target" "$BACKUP_DIR/$label"
    if [ ! -L "$target" ]; then diff -qr "$target" "$BACKUP_DIR/$label" >/dev/null; fi
    present=1
  else
    present=0
  fi
  printf 'restore_item %s %s %s\n' "$(shell_quote "$label")" "$(shell_quote "$target")" "$present" >> "$BACKUP_DIR/restore.sh"
}
begin_backup() {
  for target in "$CORE_HOME" "$LAUNCHER_DATA" "$CODEX_DIR" "$1"; do
    case "$target" in /|"$HOME"|"$HOME/"|*'/../'*|*/..) echo "Unsafe migration target: $target" >&2; exit 1 ;; esac
    case "$BACKUP_ROOT/" in "$target/"*) echo "Backup root overlaps $target" >&2; exit 1 ;; esac
  done
  mkdir -p "$(dirname "$CORE_HOME")"
  if ! mkdir "$CORE_HOME.migration-lock" 2>/dev/null; then
    echo "Another migration may be active. Check $CORE_HOME.migration-lock before retrying" >&2; exit 1
  fi
  LOCK_HELD=1
  assert_stopped
  if [ -e "$1" ] || [ -f "$CORE_HOME/config.json" ] || [ -d "$CORE_HOME/secrets" ] || [ -f "$LAUNCHER_DATA/launcher-state.json" ] || [ -d "$LAUNCHER_DATA/Partitions" ] || [ -e "$SOURCE_MARKER" ]; then confirm_migration; fi
  if [ -L "$BACKUP_ROOT" ]; then echo "Backup root cannot be a symbolic link" >&2; exit 1; fi
  mkdir -p "$BACKUP_ROOT"
  chmod 0700 "$BACKUP_ROOT"
  BACKUP_DIR="$(mktemp -d "$BACKUP_ROOT/migration-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
  cat > "$BACKUP_DIR/restore.sh" <<'RESTORE'
#!/bin/sh
set -eu
umask 077
[ "${1:-}" = "--confirm" ] || { echo "Quit both launchers and Codex, then run: sh restore.sh --confirm" >&2; exit 1; }
if pgrep -x "Codex Web GPT" >/dev/null 2>&1 || pgrep -x codex >/dev/null 2>&1; then
  echo "Quit Codex Web GPT and Codex before recovery" >&2; exit 1
fi
BACKUP_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
[ -f "$BACKUP_DIR/backup-complete" ] || { echo "Backup is incomplete; nothing restored" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$BACKUP_DIR" && sha256sum -c files.sha256 >/dev/null)
else
  (cd "$BACKUP_DIR" && shasum -a 256 -c files.sha256 >/dev/null)
fi
RECOVERY_DIR="$(mktemp -d "$BACKUP_DIR/before-restore-XXXXXX")"
restore_item() {
  label="$1"; target="$2"; present="$3"
  if [ -e "$target" ] || [ -L "$target" ]; then
    cp -pRP "$target" "$RECOVERY_DIR/$label"
  fi
  if [ "$present" = 1 ]; then
    next="$target.restore.$$"
    [ ! -e "$next" ] && [ ! -L "$next" ]
    mkdir -p "$(dirname "$target")"
    cp -pRP "$BACKUP_DIR/$label" "$next"
    previous="$target.before-restore.$$"
    [ ! -e "$previous" ] && [ ! -L "$previous" ]
    had_previous=0
    if [ -e "$target" ] || [ -L "$target" ]; then mv "$target" "$previous"; had_previous=1; fi
    if ! mv "$next" "$target"; then
      if [ "$had_previous" = 1 ]; then mv "$previous" "$target"; fi
      return 1
    fi
    if [ "$had_previous" = 1 ]; then rm -rf "$previous"; fi
  else
    rm -rf "$target"
  fi
}
RESTORE
  printf 'CORE_HOME=%s\n' "$(shell_quote "$CORE_HOME")" >> "$BACKUP_DIR/restore.sh"
  cat >> "$BACKUP_DIR/restore.sh" <<'OWNER'
for state in "$CORE_HOME/runtime/launcher-browser.json" "$CORE_HOME/runtime/launcher-supervisor.json"; do
  [ -f "$state" ] || continue
  for pid in $(tr ',' '\n' < "$state" | sed -n 's/.*"\(pid\|ownerPid\|daemonPid\|tunnelPid\)"[[:space:]]*:[[:space:]]*\([1-9][0-9]*\).*/\2/p'); do
    if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
      echo "An existing runtime (PID $pid) must stop before recovery" >&2; exit 1
    fi
  done
done
OWNER
  backup_item core-home "$CORE_HOME"
  backup_item launcher-data "$LAUNCHER_DATA"
  backup_item codex-config "$CODEX_DIR/config.toml"
  backup_item codex-models "$CODEX_DIR/models_cache.json"
  if [ "$OS" = "Darwin" ]; then
    backup_item launchagent-daemon "$HOME/Library/LaunchAgents/io.github.codex-chatgpt-web.daemon.plist"
    backup_item launchagent-tunnel "$HOME/Library/LaunchAgents/io.github.codex-chatgpt-web.tunnel.plist"
  fi
  echo "Recovery backup: $BACKUP_DIR"
}
finish_backup() {
  printf '%s\n' 'echo "Files restored. Restart the previous launcher and verify the Codex route before resuming work."' >> "$BACKUP_DIR/restore.sh"
  chmod 0700 "$BACKUP_DIR/restore.sh"
  printf '%s\n' "repository=$REPOSITORY" "version=$VERSION" > "$BACKUP_DIR/backup-complete"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$BACKUP_DIR" && find . -type f ! -path './files.sha256' -exec sha256sum {} +) > "$BACKUP_DIR/files.sha256"
  else
    (cd "$BACKUP_DIR" && find . -type f ! -path './files.sha256' -exec shasum -a 256 {} +) > "$BACKUP_DIR/files.sha256"
  fi
}
record_source() {
  mkdir -p "$CORE_HOME"
  printf '%s\n' "$REPOSITORY" > "$SOURCE_MARKER.next.$$"
  chmod 0600 "$SOURCE_MARKER.next.$$"
  mv -f "$SOURCE_MARKER.next.$$" "$SOURCE_MARKER"
}
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$MUTATED" = 1 ] && [ -n "$BACKUP_DIR" ]; then
    echo "Installation failed; restoring the verified pre-install files from $BACKUP_DIR" >&2
    sh "$BACKUP_DIR/restore.sh" --confirm || echo "Automatic file recovery failed. Backup retained at $BACKUP_DIR; do not delete it" >&2
  fi
  if [ "$LOCK_HELD" = 1 ]; then rmdir "$CORE_HOME.migration-lock"; fi
  for next in "${TARGET_NEXT:-}" "${WRAPPER_NEXT:-}" "${RUNNER_NEXT:-}" "$SOURCE_MARKER.next.$$"; do
    if [ -n "$next" ]; then rm -f "$next"; fi
  done
  rm -rf "$TEMP_DIR"
  exit "$status"
}

if [ -z "$VERSION" ]; then
  VERSION="$(curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 60 \
    "https://api.github.com/repos/$REPOSITORY/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' \
    | head -n 1)"
fi
VERSION="${VERSION#v}"
if [ -z "$VERSION" ]; then
  echo "Could not resolve the latest Codex Web GPT release" >&2
  exit 1
fi
if ! printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$'; then
  echo "Invalid release version: $VERSION" >&2; exit 1
fi

ASSET="codex-web-gpt-$VERSION-$PLATFORM-$ARCH.$EXTENSION"
BASE_URL="https://github.com/$REPOSITORY/releases/download/v$VERSION"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-web-gpt-launcher.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 900 \
  "$BASE_URL/$ASSET" -o "$TEMP_DIR/$ASSET"
curl -fsSL --retry 3 --retry-all-errors --connect-timeout 15 --max-time 60 \
  "$BASE_URL/checksums.txt" -o "$TEMP_DIR/checksums.txt"
EXPECTED="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TEMP_DIR/checksums.txt")"
if [ "$OS" = "Darwin" ]; then
  ACTUAL="$(shasum -a 256 "$TEMP_DIR/$ASSET" | awk '{ print $1}')"
else
  ACTUAL="$(sha256sum "$TEMP_DIR/$ASSET" | awk '{ print $1}')"
fi
if [ -z "$EXPECTED" ]; then
  echo "checksums.txt has no entry for $ASSET" >&2
  exit 1
fi
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "SHA-256 verification failed for $ASSET" >&2
  exit 1
fi

if [ "$OS" = "Darwin" ]; then
  INSTALL_DIR="$(absolute_path "${CODEX_WEB_GPT_APPLICATIONS_DIR:-/Applications}")"
  STAGE_DIR="$TEMP_DIR/stage"
  mkdir "$STAGE_DIR"
  ditto -x -k "$TEMP_DIR/$ASSET" "$STAGE_DIR"
  SOURCE_APP="$STAGE_DIR/Codex Web GPT.app"
  if [ ! -d "$SOURCE_APP" ] || [ ! -x "$SOURCE_APP/Contents/MacOS/Codex Web GPT" ]; then
    echo "Launcher archive is incomplete" >&2
    exit 1
  fi
  if [ ! -w "$INSTALL_DIR" ]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
  fi
  TARGET_APP="$INSTALL_DIR/Codex Web GPT.app"
  if pgrep -x "Codex Web GPT" >/dev/null 2>&1; then
    echo "Quit Codex Web GPT before updating it" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$SOURCE_APP"
  begin_backup "$TARGET_APP"
  backup_item application "$TARGET_APP"
  finish_backup
  assert_stopped
  MUTATED=1
  rm -rf "$TARGET_APP"
  ditto "$SOURCE_APP" "$TARGET_APP"
  record_source
  echo "Installed $TARGET_APP"
  rmdir "$CORE_HOME.migration-lock"
  LOCK_HELD=0
  open "$TARGET_APP"
  MUTATED=0
  exit 0
fi

LIB_DIR="$(absolute_path "${CODEX_WEB_GPT_LIB_DIR:-$HOME/.local/lib/codex-web-gpt}")"
BIN_DIR="$(absolute_path "${CODEX_WEB_GPT_BIN_DIR:-$HOME/.local/bin}")"
TARGET_DIR="$LIB_DIR/$VERSION"
TARGET="$TARGET_DIR/Codex Web GPT.AppImage"
WRAPPER="$BIN_DIR/codex-web-gpt"
DESCRIPTOR="$CORE_HOME/runtime/launcher-browser.json"
RUNNING_PID=""
if [ -f "$DESCRIPTOR" ]; then
  RUNNING_PID="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$DESCRIPTOR" | head -n 1)"
fi
if { [ -n "$RUNNING_PID" ] && kill -0 "$RUNNING_PID" 2>/dev/null; } \
  || pgrep -f "Codex Web GPT\\.AppImage" >/dev/null 2>&1; then
  echo "Quit Codex Web GPT before updating it" >&2
  exit 1
fi
EXTRACT_DIR="$TEMP_DIR/appimage"
mkdir -p "$EXTRACT_DIR"
chmod 0755 "$TEMP_DIR/$ASSET"
(
  cd "$EXTRACT_DIR"
  "$TEMP_DIR/$ASSET" --appimage-extract >/dev/null
)
ICON_SOURCE="$(find "$EXTRACT_DIR/squashfs-root" -type f -path '*/512x512/*' -name '*.png' | sort | head -n 1)"
if [ -z "$ICON_SOURCE" ]; then
  ICON_SOURCE="$(find "$EXTRACT_DIR/squashfs-root" -type f -name '*.png' | sort | head -n 1)"
fi
if [ -z "$ICON_SOURCE" ]; then
  echo "Launcher AppImage does not contain a PNG application icon" >&2
  exit 1
fi
RUNNER_SOURCE="$(find "$EXTRACT_DIR/squashfs-root" -type f -path '*/app.asar.unpacked/assets/linux-appimage-runner.sh' -print -quit)"
if [ -z "$RUNNER_SOURCE" ]; then
  echo "Launcher AppImage does not contain its bounded Linux runner" >&2
  exit 1
fi

APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
begin_backup "$LIB_DIR"
backup_item linux-library "$LIB_DIR"
backup_item linux-wrapper "$WRAPPER"
backup_item desktop "$APPLICATIONS_DIR/codex-web-gpt.desktop"
backup_item icon "$ICON_DIR/codex-web-gpt.png"
backup_item autostart "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/codex-web-gpt.desktop"
finish_backup
assert_stopped
MUTATED=1
mkdir -p "$TARGET_DIR" "$BIN_DIR"
TARGET_NEXT="$TARGET.next.$$"
WRAPPER_NEXT="$WRAPPER.next.$$"
RUNNER="$LIB_DIR/run-appimage"
RUNNER_NEXT="$RUNNER.next.$$"

install -m 0755 "$TEMP_DIR/$ASSET" "$TARGET_NEXT"
mv -f "$TARGET_NEXT" "$TARGET"
install -m 0755 "$RUNNER_SOURCE" "$RUNNER_NEXT"
mv -f "$RUNNER_NEXT" "$RUNNER"
WRAPPER_QUOTED="$(shell_quote "$WRAPPER")"
TARGET_QUOTED="$(shell_quote "$TARGET")"
RUNNER_QUOTED="$(shell_quote "$RUNNER")"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'set -eu'
  printf 'export CODEX_WEB_GPT_LAUNCHER_EXECUTABLE=%s\n' "$WRAPPER_QUOTED"
  printf 'export CODEX_WEB_GPT_APPIMAGE=%s\n' "$TARGET_QUOTED"
  printf 'exec %s %s "$@"\n' "$RUNNER_QUOTED" "$TARGET_QUOTED"
} > "$WRAPPER_NEXT"
chmod 0755 "$WRAPPER_NEXT"
mv -f "$WRAPPER_NEXT" "$WRAPPER"

APPLICATIONS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
mkdir -p "$APPLICATIONS_DIR" "$ICON_DIR"
install -m 0644 "$ICON_SOURCE" "$ICON_DIR/codex-web-gpt.png"
DESKTOP_WRAPPER="$(printf '%s' "$WRAPPER" | sed \
  -e 's/\\/\\\\/g' \
  -e 's/"/\\"/g' \
  -e 's/`/\\`/g' \
  -e 's/\$/\\$/g' \
  -e 's/%/%%/g')"
cat > "$APPLICATIONS_DIR/codex-web-gpt.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Codex Web GPT
Comment=ChatGPT Web models inside the native Codex harness
Exec="$DESKTOP_WRAPPER"
Icon=codex-web-gpt
Terminal=false
Categories=Development;
StartupWMClass=codex-web-gpt
EOF
chmod 0644 "$APPLICATIONS_DIR/codex-web-gpt.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
fi
record_source
echo "Installed $TARGET"
# This confirms only that launch was requested, not application health. Keep the backup.
MUTATED=0
rmdir "$CORE_HOME.migration-lock"
LOCK_HELD=0
nohup "$WRAPPER" >/dev/null 2>&1 &
