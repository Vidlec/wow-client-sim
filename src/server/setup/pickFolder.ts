// The system's own dialog for choosing a folder (or LuaJIT's executable), opened on this computer when the setup's
// Browse button is pressed: a browser page cannot learn a folder's path itself. The server runs on the user's own
// computer (it listens on 127.0.0.1 only), so the dialog opens in front of them.
import type { FolderPick, FolderPickRequest } from "../../shared/setup.ts";

const TITLES: Record<FolderPickRequest["kind"], string> = {
  addons: "Choose the game's Interface\\AddOns folder",
  interface: "Choose the interface source's Interface folder",
  luajit: "Choose LuaJIT's executable",
};

/** A text for a PowerShell single-quoted string */
const quotePowerShell = (text: string): string => `'${text.replaceAll("'", "''")}'`;
/** A text for an AppleScript string */
const quoteAppleScript = (text: string): string => `"${text.replaceAll("\\", "\\\\").replaceAll('"', '\\"')}"`;

const windowsCommand = (request: FolderPickRequest): string[] => {
  const title = quotePowerShell(TITLES[request.kind]);
  const start = quotePowerShell(request.startPath ?? "");
  // An owner form kept on top: without it the dialog may open behind the browser
  const script =
    request.kind === "luajit"
      ? `$d = New-Object System.Windows.Forms.OpenFileDialog; $d.Title = ${title}; $d.Filter = 'LuaJIT|luajit*.exe|All files|*.*'; if (${start}) { $d.InitialDirectory = ${start} }; $result = $d.ShowDialog($owner); $chosen = $d.FileName`
      : `$d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = ${title}; $d.ShowNewFolderButton = $false; if (${start}) { $d.SelectedPath = ${start} }; $result = $d.ShowDialog($owner); $chosen = $d.SelectedPath`;
  return [
    "powershell.exe",
    "-NoProfile",
    "-STA",
    "-Command",
    `[Console]::OutputEncoding = [Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }; ${script}; if ($result -eq 'OK') { [Console]::Out.Write($chosen) }`,
  ];
};

const macCommand = (request: FolderPickRequest): string[] => {
  const what = request.kind === "luajit" ? "file" : "folder";
  const start = request.startPath ? ` default location (POSIX file ${quoteAppleScript(request.startPath)})` : "";
  return [
    "osascript",
    "-e",
    `POSIX path of (choose ${what} with prompt ${quoteAppleScript(TITLES[request.kind])}${start})`,
  ];
};

const linuxCommand = (request: FolderPickRequest): string[] | null => {
  const title = TITLES[request.kind];
  if (Bun.which("zenity")) {
    return ["zenity", "--file-selection", `--title=${title}`, ...(request.kind === "luajit" ? [] : ["--directory"])];
  }
  if (Bun.which("kdialog")) {
    const start = request.startPath ?? ".";
    return request.kind === "luajit"
      ? ["kdialog", "--title", title, "--getopenfilename", start]
      : ["kdialog", "--title", title, "--getexistingdirectory", start];
  }
  return null;
};

/** The command that shows this system's dialog (null: there is none) */
export const pickFolderCommand = (request: FolderPickRequest): string[] | null =>
  process.platform === "win32"
    ? windowsCommand(request)
    : process.platform === "darwin"
      ? macCommand(request)
      : linuxCommand(request);

export const pickFolder = async (request: FolderPickRequest): Promise<FolderPick> => {
  const command = pickFolderCommand(request);
  if (!command) {
    return { path: null, error: "No folder dialog on this system (zenity or kdialog); type the path instead" };
  }
  try {
    const child = Bun.spawn(command, { stdin: "ignore", stdout: "pipe", stderr: "pipe", windowsHide: true });
    const [output] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text()]);
    await child.exited;
    const path = output.trim().replace(/[\\/]$/, "");
    return { path: path || null };
  } catch (error) {
    return { path: null, error: error instanceof Error ? error.message : String(error) };
  }
};
