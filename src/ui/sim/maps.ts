// The game's maps (UiMap), read once: the zones a character can stand in, by name
import { useEffect, useState } from "react";
import { api } from "./api.ts";
import type { UiMap } from "./types.ts";

export type Maps = {
  /** Zones and smaller (type 3 and up), by name */
  zones: readonly UiMap[];
};

const EMPTY: Maps = { zones: [] };
const ZONE_TYPE = 3;

let loaded: Promise<Maps> | null = null;

const loadMaps = (): Promise<Maps> => {
  loaded ??= api
    .maps()
    .then((maps) => ({
      zones: maps
        .filter((map) => map.type >= ZONE_TYPE)
        .sort((first, second) => first.name.localeCompare(second.name) || first.id - second.id),
    }))
    .catch(() => {
      loaded = null; // (tried again by the next one who asks)
      return EMPTY;
    });
  return loaded;
};

export const useMaps = (): Maps => {
  const [maps, setMaps] = useState<Maps>(EMPTY);
  useEffect(() => {
    let isCurrent = true;
    void loadMaps().then((found) => {
      if (isCurrent) setMaps(found);
    });
    return () => {
      isCurrent = false;
    };
  }, []);
  return maps;
};
