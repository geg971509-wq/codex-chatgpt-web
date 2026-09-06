const fs = require("node:fs");
const path = require("node:path");
const { writePrivateFileAtomic } = require("./atomic-file.cjs");

const REPOSITORY = "geg971509-wq/codex-chatgpt-web";
const SOURCE_FILE = "distribution-source";

// Keep the installed application identity for B2 compatibility, but never infer
// consent to a publisher change merely from the presence of an upstream profile.
function assertDistributionAccess({ coreHome, userData }) {
  if (fs.existsSync(`${coreHome}.migration-lock`)) throw new Error("An installer migration is in progress; close it before starting the launcher");
  const marker = path.join(coreHome, SOURCE_FILE);
  let source = null;
  try {
    const stat = fs.lstatSync(marker);
    if (!stat.isFile() || stat.size > 256) throw new Error("Invalid distribution receipt");
    source = fs.readFileSync(marker, "utf8").trim();
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (source === REPOSITORY) return;
  const hasPriorData = [
    path.join(coreHome, "config.json"),
    path.join(coreHome, "codex"),
    path.join(coreHome, "secrets"),
    path.join(userData, "launcher-state.json"),
    path.join(userData, "Partitions"),
  ].some(file => fs.existsSync(file));
  if (source !== null || hasPriorData) {
    throw new Error(
      `This distribution is maintained by ${REPOSITORY}. Existing data has not been approved for migration. `
      + "Quit the old launcher and Codex, then run this repository's install-launcher script to confirm, back up and migrate. "
      + `No runtime migration was started. Instructions: https://github.com/${REPOSITORY}/blob/main/docs/distribution-migration.md`,
    );
  }
  // A genuinely fresh profile has no upstream data to migrate.
  writePrivateFileAtomic(marker, `${REPOSITORY}\n`);
}

module.exports = { REPOSITORY, SOURCE_FILE, assertDistributionAccess };
