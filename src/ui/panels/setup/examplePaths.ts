// The paths the setup's fields show as examples, as they look on the system the server runs on (Windows, macOS,
// Linux; a container is Linux)
import type { SetupState } from "../../sim/setup.ts";

type ExampleKind = "addons" | "interface" | "luajit" | "addonFolder";

const WINDOWS: Record<ExampleKind, string> = {
  addons: "C:\\Program Files\\World of Warcraft\\_forever_\\Interface\\AddOns",
  interface: "C:\\wow-ui-source\\Interface",
  luajit: "C:\\LuaJIT\\bin\\luajit.exe",
  addonFolder: "C:\\Addons, or one addon's folder",
};

const MAC: Record<ExampleKind, string> = {
  addons: "/Applications/World of Warcraft/_forever_/Interface/AddOns",
  interface: "/Users/you/wow-ui-source/Interface",
  luajit: "/opt/homebrew/bin/luajit",
  addonFolder: "/Users/you/Addons, or one addon's folder",
};

const LINUX: Record<ExampleKind, string> = {
  addons: "/home/you/Games/World of Warcraft/_forever_/Interface/AddOns",
  interface: "/home/you/wow-ui-source/Interface",
  luajit: "/usr/local/bin/luajit",
  addonFolder: "/home/you/Addons, or one addon's folder",
};

export const getExamplePath = (setup: SetupState | null, kind: ExampleKind): string => {
  if (setup?.platform === "win32") return WINDOWS[kind];
  if (setup?.platform === "darwin") return MAC[kind];
  return LINUX[kind];
};
