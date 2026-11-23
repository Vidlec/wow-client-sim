// The clients the simulator can be. Adding one: a file like forever.ts, listed here.
import type { FlavourInfo } from "../../shared/setup.ts";
import { forever } from "./forever.ts";
import type { Flavour } from "./types.ts";

export type { Flavour } from "./types.ts";

export const FLAVOURS: readonly Flavour[] = [forever];
export const DEFAULT_FLAVOUR: Flavour = forever;

/** The flavour by id; the default one for an unknown id (a setting from a newer version) */
export const findFlavour = (id: string | undefined): Flavour =>
  FLAVOURS.find((flavour) => flavour.id === id) ?? DEFAULT_FLAVOUR;

export const isKnownFlavour = (id: string): boolean => FLAVOURS.some((flavour) => flavour.id === id);

export const interfaceSourceUrl = (flavour: Flavour): string =>
  `https://github.com/${flavour.interfaceSource.repository}/tree/${flavour.interfaceSource.branch}`;

/** The archive GitHub makes of the branch (a gzipped tar, which Bun.Archive unpacks) */
export const interfaceArchiveUrl = (flavour: Flavour): string =>
  `https://codeload.github.com/${flavour.interfaceSource.repository}/tar.gz/refs/heads/${flavour.interfaceSource.branch}`;

export const describeFlavour = (flavour: Flavour): FlavourInfo => ({
  id: flavour.id,
  name: flavour.name,
  description: flavour.description,
  clientVersion: flavour.client.version,
  clientBuild: flavour.client.buildNumber,
  interfaceSource: { ...flavour.interfaceSource, url: interfaceSourceUrl(flavour) },
});
