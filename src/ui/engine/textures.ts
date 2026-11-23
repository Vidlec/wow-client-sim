// Where the game's art is served: by file id or path from the game's files (/art), an addon's own from its folder
// (/media)

/** A file id's picture */
export const artUrl = (fileId: number | string): string => `/art?p=${fileId}`;

/** The URL of a texture as the scene names it (a file id, or a path); null for none */
export const textureUrl = (texture: string | number | null | undefined): string | null => {
  if (texture === null || texture === undefined) return null;
  if (typeof texture === "number") return artUrl(texture);
  if (/^\d+$/.test(texture)) return artUrl(texture);
  if (/^interface[\\/]addons[\\/]/i.test(texture)) return `/media?p=${encodeURIComponent(texture)}`;
  return `/art?p=${encodeURIComponent(texture)}`;
};
