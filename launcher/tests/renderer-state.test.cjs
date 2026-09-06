const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { pathToFileURL } = require("node:url");
const ts = require("typescript");

const appPath = path.join(__dirname, "..", "src", "App.tsx");
const compilerOptions = { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX };
const copyModule = { exports: {} };
vm.runInNewContext(ts.transpileModule(
  fs.readFileSync(path.join(__dirname, "..", "src", "i18n.ts"), "utf8"),
  { compilerOptions },
).outputText, { exports: copyModule.exports, module: copyModule });
const copy = copyModule.exports.copyFor("en");
const appCode = ts.transpileModule(
  fs.readFileSync(appPath, "utf8").replaceAll("import.meta.url", JSON.stringify(pathToFileURL(appPath).href))
    + "\nexport { SetupSurface, McpSurface, SettingsSurface };\n",
  { compilerOptions },
).outputText;

// Execute real component handlers with isolated hook state. This deliberately
// does not emulate DOM layout, animation, or the native Electron browser view.
function renderer(api = {}) {
  const values = [];
  const effects = [];
  let cursor = 0;
  let mounted = false;
  const hooks = {
    useState(initial) {
      const index = cursor++;
      if (!(index in values)) values[index] = typeof initial === "function" ? initial() : initial;
      return [values[index], (next) => { values[index] = typeof next === "function" ? next(values[index]) : next; }];
    },
    useEffect(effect) { if (!mounted) effects.push(effect); },
    useLayoutEffect() {},
    useCallback: (callback) => callback,
    useMemo: (factory) => factory(),
    useRef: (current) => ({ current }),
  };
  const jsx = (type, props) => ({ type, props });
  const module = { exports: {} };
  vm.runInNewContext(appCode, {
    module, exports: module.exports, URL, console,
    window: { codexWebLauncher: api },
    document: { documentElement: {} },
    require(name) {
      if (name === "react") return hooks;
      if (name === "react/jsx-runtime") return { jsx, jsxs: jsx, Fragment: "fragment" };
      if (name === "react-dom") return { createPortal: (child) => child };
      if (name === "motion/react") return { motion: new Proxy({}, { get: (_, key) => key }), AnimatePresence: "animation" };
      if (name === "./i18n") return copyModule.exports;
      if (name === "./icons") return { Icon: "icon" };
      throw new Error(`Unexpected renderer import: ${name}`);
    },
  });
  return {
    render(name, props) {
      cursor = 0;
      const element = module.exports[name](props);
      mounted = true;
      return element;
    },
    mountEffects() { return effects.splice(0).map((effect) => effect()); },
  };
}

function elements(root, predicate) {
  if (Array.isArray(root)) return root.flatMap((child) => elements(child, predicate));
  if (!root || typeof root !== "object") return [];
  return [...(predicate(root) ? [root] : []), ...elements(root.props?.children, predicate)];
}
const named = (name) => (element) => element.type?.name === name;
const flush = () => new Promise((resolve) => setImmediate(resolve));
const noop = () => {};
const subscriptions = Object.fromEntries([
  "onStateChanged", "onBrowserState", "onOperation", "onLog", "onUpdateState",
].map((name) => [name, () => noop]));
function snapshot(overrides = {}) {
  return {
    state: { language: "en", onboardingComplete: true, browserInteractionMode: "manual", mcpGuideStep: 1 },
    profile: "production", platform: "linux", version: "5.0.4", logs: [], browser: null,
    operation: null, update: { status: "disabled" }, smokePassed: false,
    mcpCredentialsConfigured: false, connectorNames: { manual: "Codex Zero Risk" }, urls: {},
    ...overrides,
  };
}

function setupProps(next) {
  return { snapshot: next, copy, browser: null, operation: null, devProfile: false,
    activateBrowser: async () => {}, showMcp: noop, updateState: noop, updateSnapshot: noop, setError: noop };
}

test("initial snapshot rejection replaces loading with the actual failure", async () => {
  const ui = renderer({ ...subscriptions, snapshot: async () => { throw new Error("Snapshot unavailable"); } });
  assert.equal(ui.render("App").type.name, "LaunchLoading");
  ui.mountEffects();
  await flush();
  const failed = ui.render("App");
  assert.equal(failed.type.name, "FatalMessage");
  assert.match(failed.props.message, /Snapshot unavailable/);
});

test("cold manual setup routes to MCP instead of a disabled automatic installation", async () => {
  let opened = 0;
  let installed = 0;
  const ui = renderer({ setupCore: async () => { installed += 1; } });
  const props = { ...setupProps(snapshot()), showMcp: () => { opened += 1; } };
  const [row] = elements(ui.render("SetupSurface", props), named("SetupRow"));
  assert.equal(row.props.disabled, false);
  assert.equal(row.props.action, copy.configureMcp);
  await row.props.onAction();
  assert.equal(opened, 1);
  assert.equal(installed, 0);
});

test("automatic first install still requires smoke; installed manual mode remains reinstallable", () => {
  for (const [mode, installed, smoke, expected] of [
    ["automatic", false, false, true], ["automatic", false, true, false], ["manual", true, false, false],
  ]) {
    const next = snapshot({ state: { browserInteractionMode: mode, coreSetupComplete: installed }, smokePassed: smoke });
    const ui = renderer();
    const rows = elements(ui.render("SetupSurface", setupProps(next)), named("SetupRow"));
    assert.equal(rows.at(-1).props.disabled, expected);
  }
});

test("MCP install publishes the full fresh snapshot so remount reuses saved credentials", async () => {
  let current = snapshot();
  const api = { ...subscriptions, snapshot: async () => current, setMcpStep: async () => current.state,
    setupMcp: async () => { current = snapshot({ mcpCredentialsConfigured: true }); } };
  const app = renderer(api);
  app.render("App"); app.mountEffects(); await flush();
  const shell = elements(app.render("App"), named("LauncherShell"))[0];
  const ui = renderer(api);
  const props = { ...setupProps(current), ...shell.props, interactionMode: "manual", onDone: noop };
  let tree = ui.render("McpSurface", props);
  const fields = elements(tree, (element) => element.type === "input");
  fields[0].props.onChange({ target: { value: "tunnel_test" } });
  fields[1].props.onChange({ target: { value: "key_test" } });
  tree = ui.render("McpSurface", props);
  elements(tree, named("PrimaryButton"))[0].props.onClick();
  await flush();
  const refreshed = elements(app.render("App"), named("LauncherShell"))[0].props.snapshot;
  assert.equal(refreshed.mcpCredentialsConfigured, true);
  const reopened = renderer(api).render("McpSurface", { ...props, snapshot: refreshed });
  assert.equal(elements(reopened, (element) => element.props?.className === "saved-credentials").length, 1);
});

test("uninstall clears stale credential metadata, not only the persisted UI flags", async () => {
  const fresh = snapshot();
  let refreshed;
  const ui = renderer({ uninstallIntegration: async () => ({ state: fresh.state }), snapshot: async () => fresh });
  const props = { ...setupProps(snapshot({ mcpCredentialsConfigured: true })), language: "en",
    configureInteractionMode: noop, updateSnapshot: (next) => { refreshed = next; } };
  const tree = ui.render("SettingsSurface", props);
  const action = elements(tree, (element) => element.type === "button"
    && elements(element, (child) => child.type === "strong" && child.props.children === copy.uninstallIntegration).length > 0)[0];
  assert.ok(action, "the uninstall action is present");
  action.props.onClick();
  await flush();
  assert.equal(refreshed?.mcpCredentialsConfigured, false);
});
