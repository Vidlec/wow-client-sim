// The page opened in the user's browser as the app starts (the system's own way to open a link)
const commandFor = (url: string): string[] => {
  // (rundll32's protocol handler: no shell between, so the link is never parsed as a command line)
  if (process.platform === "win32") return ["rundll32.exe", "url.dll,FileProtocolHandler", url];
  if (process.platform === "darwin") return ["open", url];
  return ["xdg-open", url];
};

export const openBrowser = (url: string): void => {
  try {
    const child = Bun.spawn(commandFor(url), {
      stdin: "ignore",
      stdout: "ignore",
      stderr: "ignore",
      windowsHide: true,
    });
    child.unref();
  } catch {
    // No browser to open: the banner gives the link
  }
};
