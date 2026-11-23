// Numbers as the page writes them

/** A size in bytes: "812 B", "34 KB", "2.1 MB" */
export const formatBytes = (bytes: number): string =>
  bytes >= 1048576
    ? `${(bytes / 1048576).toFixed(1)} MB`
    : bytes >= 1024
      ? `${Math.round(bytes / 1024)} KB`
      : `${bytes} B`;
