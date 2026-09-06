const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { REPOSITORY, assertDistributionAccess } = require("../electron/distribution.cjs");
const { validateReleaseAssetUrl } = require("../electron/update.cjs");

const root = path.resolve(__dirname, "../..");
function temporary(run) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "migration 'test-"));
  try { return run(home); } finally { fs.rmSync(home, { recursive: true, force: true }); }
}
function write(file, content, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content, { mode });
}

test("independent release URLs cannot switch back to upstream", () => {
  assert.equal(REPOSITORY, "geg971509-wq/codex-chatgpt-web");
  const suffix = "/releases/download/v5.0.5/launcher.zip";
  assert.equal(validateReleaseAssetUrl(`https://github.com/${REPOSITORY}${suffix}`, "5.0.5", "launcher.zip"), `https://github.com/${REPOSITORY}${suffix}`);
  assert.throws(() => validateReleaseAssetUrl(`https://github.com/miuuyy/codex-chatgpt-web${suffix}`, "5.0.5", "launcher.zip"));
});

test("first launch cannot modify an unapproved upstream profile", () => temporary(home => {
  const coreHome = path.join(home, "core"); const userData = path.join(home, "ui");
  write(path.join(coreHome, "config.json"), '{"releaseVersion":"5.0.4"}');
  assert.throws(() => assertDistributionAccess({ coreHome, userData }), /not been approved/);
  assert.equal(fs.readFileSync(path.join(coreHome, "config.json"), "utf8"), '{"releaseVersion":"5.0.4"}');
  assert.equal(fs.existsSync(path.join(coreHome, "distribution-source")), false);
  write(path.join(coreHome, "distribution-source"), `${REPOSITORY}\n`);
  assert.doesNotThrow(() => assertDistributionAccess({ coreHome, userData }));
}));

test("fresh profile receives its publisher receipt; active migration and corrupt receipts fail closed", () => temporary(home => {
  const options = { coreHome: path.join(home, "core"), userData: path.join(home, "ui") };
  assertDistributionAccess(options);
  assert.equal(fs.readFileSync(path.join(options.coreHome, "distribution-source"), "utf8"), `${REPOSITORY}\n`);
  fs.mkdirSync(`${options.coreHome}.migration-lock`);
  assert.throws(() => assertDistributionAccess(options), /in progress/);
  fs.rmdirSync(`${options.coreHome}.migration-lock`);
  write(path.join(options.coreHome, "distribution-source"), "unknown publisher");
  assert.throws(() => assertDistributionAccess(options), /not been approved/);
}));

test("browser data without a core config also requires publisher migration", () => temporary(home => {
  const options = { coreHome: path.join(home, "core"), userData: path.join(home, "ui") };
  write(path.join(options.userData, "Partitions", "cookies"), "private-cookie-fixture");
  assert.throws(() => assertDistributionAccess(options), /not been approved/);
}));

test("B2 retains installed identity and places the migration guard before runtime writes", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "launcher/package.json"), "utf8"));
  assert.equal(manifest.build.appId, "dev.codexwebgpt.launcher");
  assert.equal(manifest.build.nsis.guid, "d1a6026a-6210-588e-9a2b-da3936f94e02");
  assert.equal(manifest.build.nsis.include, "assets/migration.nsh");
  const main = fs.readFileSync(path.join(root, "launcher/electron/main.cjs"), "utf8");
  const start = main.slice(main.indexOf("async function start()"));
  assert.ok(start.indexOf("assertDistributionAccess(") < start.indexOf("runtimeRootProvider()"));
  const packager = fs.readFileSync(path.join(root, "launcher/scripts/package.cjs"), "utf8");
  assert.match(packager, /target === "--mac" && !env.CSC_LINK && !env.CSC_NAME[\s\S]*?identity=-[\s\S]*?CSC_FOR_PULL_REQUEST = "true"/);
  assert.match(packager, /CSC_IDENTITY_AUTO_DISCOVERY = "false"/);
});

function fixture(home, extra = {}) {
  const bin = path.join(home, "fixture-bin");
  const asset = path.join(home, "fixture.AppImage");
  write(asset, `#!/bin/sh
set -eu
[ "$1" = --appimage-extract ]
mkdir -p squashfs-root/usr/share/icons/hicolor/512x512/apps
printf icon > squashfs-root/usr/share/icons/hicolor/512x512/apps/icon.png
mkdir -p squashfs-root/resources/app.asar.unpacked/assets
printf '#!/bin/sh\\nexit 0\\n' > squashfs-root/resources/app.asar.unpacked/assets/linux-appimage-runner.sh
`, 0o755);
  write(path.join(bin, "uname"), '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n', 0o755);
  write(path.join(bin, "pgrep"), '#!/bin/sh\nexit 1\n', 0o755);
  write(path.join(bin, "nohup"), '#!/bin/sh\nexit 0\n', 0o755);
  write(path.join(bin, "curl"), `#!/bin/sh
set -eu
url= out=
while [ "$#" -gt 0 ]; do
 case "$1" in https:*) url="$1";; -o) shift; out="$1";; esac
 shift
done
case "$url" in
 */checksums.txt)
  digest="$(sha256sum "$FIXTURE_ASSET" | cut -d ' ' -f1)"
  if [ "\${FIXTURE_BAD_CHECKSUM:-}" = 1 ]; then digest=bad; fi
  printf '%s  codex-web-gpt-5.0.5-linux-x64.AppImage\\n' "$digest" > "$out";;
 *) cp "$FIXTURE_ASSET" "$out";;
esac
`, 0o755);
  write(path.join(bin, "install"), `#!/bin/sh
case "$*" in
 *linux-appimage-runner*) if [ "\${FIXTURE_FAIL_RUNNER:-}" = 1 ]; then echo 'simulated runner install failure' >&2; exit 9; fi;;
esac
exec /usr/bin/install "$@"
`, 0o755);
  const core = path.join(home, ".codex-chatgpt-web");
  const data = path.join(home, ".config/Codex Web GPT");
  const library = path.join(home, ".local/lib/codex-web-gpt");
  write(path.join(core, "config.json"), '{"version":3,"releaseVersion":"5.0.4"}');
  write(path.join(core, "secrets/tunnel-runtime.key"), "private-key-fixture");
  write(path.join(data, "launcher-state.json"), '{"version":1,"language":"zh-CN"}');
  write(path.join(data, "Partitions/cookies"), "private-cookie-fixture");
  write(path.join(home, ".codex/config.toml"), 'openai_base_url = "old route"\n');
  write(path.join(library, "5.0.4/Codex Web GPT.AppImage"), "old app");
  write(path.join(home, ".local/bin/codex-web-gpt"), "old wrapper", 0o755);
  const env = { ...process.env, HOME: home, PATH: `${bin}:/usr/bin:/bin`, FIXTURE_ASSET: asset,
    CODEX_WEB_GPT_VERSION: "5.0.5", CODEX_WEB_GPT_ACCEPT_MIGRATION: "1", ...extra };
  for (const key of ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "CODEX_HOME", "CODEX_CHATGPT_WEB_HOME",
    "CODEX_WEB_GPT_LAUNCHER_DATA_DIR", "CODEX_WEB_GPT_LIB_DIR", "CODEX_WEB_GPT_BIN_DIR", "CODEX_WEB_GPT_REPOSITORY", "CODEX_WEB_GPT_BACKUP_DIR"]) {
    if (!(key in extra)) delete env[key];
  }
  const run = () => spawnSync("/bin/sh", [path.join(root, "scripts/install-launcher.sh")], { env, encoding: "utf8", timeout: 20_000 });
  const backups = () => fs.readdirSync(path.join(home, ".codex-web-gpt-migration-backups"))
    .map(name => path.join(home, ".codex-web-gpt-migration-backups", name));
  return { core, data, library, env, run, backups };
}

const linuxOnly = { skip: process.platform !== "linux" };
test("actual POSIX installer backs up, takes over, and restores paths containing quotes", linuxOnly, () => temporary(home => {
  const f = fixture(home); const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(fs.readFileSync(path.join(f.core, "distribution-source"), "utf8"), `${REPOSITORY}\n`);
  assert.equal(fs.readFileSync(path.join(f.data, "Partitions/cookies"), "utf8"), "private-cookie-fixture");
  const [backup] = f.backups();
  assert.equal(fs.statSync(backup).mode & 0o777, 0o700);
  assert.equal(fs.readFileSync(path.join(backup, "core-home/secrets/tunnel-runtime.key"), "utf8"), "private-key-fixture");
  write(path.join(home, ".codex/config.toml"), "post-migration edit");
  const restored = spawnSync("/bin/sh", [path.join(backup, "restore.sh"), "--confirm"], { env: f.env, encoding: "utf8", timeout: 20_000 });
  assert.equal(restored.status, 0, restored.stderr);
  assert.equal(fs.existsSync(path.join(f.core, "distribution-source")), false);
  assert.equal(fs.readFileSync(path.join(home, ".local/bin/codex-web-gpt"), "utf8"), "old wrapper");
  assert.equal(fs.readFileSync(path.join(home, ".codex/config.toml"), "utf8"), 'openai_base_url = "old route"\n');
  assert.ok(fs.readdirSync(backup).some(name => name.startsWith("before-restore-")));
}));

test("partial POSIX installation failure restores the old application and retains recovery", linuxOnly, () => temporary(home => {
  const f = fixture(home, { FIXTURE_FAIL_RUNNER: "1" }); const result = f.run();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /restoring/);
  assert.equal(fs.existsSync(path.join(f.library, "5.0.5")), false);
  assert.equal(fs.readFileSync(path.join(f.library, "5.0.4/Codex Web GPT.AppImage"), "utf8"), "old app");
  assert.equal(fs.readFileSync(path.join(home, ".local/bin/codex-web-gpt"), "utf8"), "old wrapper");
  assert.equal(fs.existsSync(path.join(f.core, "distribution-source")), false);
  assert.equal(f.backups().length, 1);
}));

test("corrupted backup is refused before any restoration write", linuxOnly, () => temporary(home => {
  const f = fixture(home); assert.equal(f.run().status, 0);
  const [backup] = f.backups(); write(path.join(backup, "core-home/config.json"), "corrupted");
  write(path.join(home, ".codex/config.toml"), "keep current");
  const restored = spawnSync("/bin/sh", [path.join(backup, "restore.sh"), "--confirm"], { env: f.env, encoding: "utf8" });
  assert.notEqual(restored.status, 0);
  assert.equal(fs.readFileSync(path.join(home, ".codex/config.toml"), "utf8"), "keep current");
  assert.equal(fs.readFileSync(path.join(f.core, "distribution-source"), "utf8"), `${REPOSITORY}\n`);
}));

test("checksum failure and repository overrides never touch the installation", linuxOnly, () => temporary(home => {
  for (const extra of [{ FIXTURE_BAD_CHECKSUM: "1" }, { CODEX_WEB_GPT_REPOSITORY: "miuuyy/codex-chatgpt-web" }]) {
    const f = fixture(home, extra); assert.notEqual(f.run().status, 0);
    assert.equal(fs.existsSync(path.join(home, ".codex-web-gpt-migration-backups")), false);
    assert.equal(fs.readFileSync(path.join(home, ".local/bin/codex-web-gpt"), "utf8"), "old wrapper");
  }
}));

test("an overlapping backup destination fails before creating it", linuxOnly, () => temporary(home => {
  const overlap = path.join(home, ".codex-chatgpt-web/backups");
  const f = fixture(home, { CODEX_WEB_GPT_BACKUP_DIR: overlap }); const result = f.run();
  assert.notEqual(result.status, 0); assert.match(result.stderr, /overlaps/);
  assert.equal(fs.existsSync(overlap), false);
}));

test("an active owner or a concurrent installer blocks migration", linuxOnly, () => temporary(home => {
  const f = fixture(home);
  write(path.join(f.core, "runtime/launcher-supervisor.json"), JSON.stringify({ ownerPid: process.pid, daemonPid: null, tunnelPid: null }));
  const busy = f.run(); assert.notEqual(busy.status, 0); assert.match(busy.stderr, /still running/);
  assert.equal(fs.existsSync(`${f.core}.migration-lock`), false);
  fs.rmSync(path.join(f.core, "runtime"), { recursive: true });
  fs.mkdirSync(`${f.core}.migration-lock`);
  const locked = f.run(); assert.notEqual(locked.status, 0); assert.match(locked.stderr, /migration may be active/);
  assert.equal(fs.existsSync(`${f.core}.migration-lock`), true);
}));
