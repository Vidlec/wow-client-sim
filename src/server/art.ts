// What the server needs of the game's art and data (assets/index.ts's Assets has it all): named here so the host and
// the routes depend on these calls, not on how the art is fetched and kept.

export type AtlasInfo = Record<string, unknown>;
export type Served = { data: Uint8Array; contentType: string };

export type ArtSource = {
  isReady: () => boolean;
  image: (target: string | number) => Promise<Served | null>;
  atlas: (name: string) => AtlasInfo | null;
  loadAtlases: () => Promise<Record<string, AtlasInfo> | null>;
  media: (addonsRoot: string, path: string) => Promise<Served | null>;
  font: (path: string) => Promise<Uint8Array | null>;
  raw: (target: string | number) => Promise<Uint8Array | null>;
  db2Path: (table: string) => Promise<string | null>;
  getDb2Rows: (table: string) => Promise<Record<string, string>[] | null>;
  exportFileIds: (path: string) => Promise<string | null>;
};
