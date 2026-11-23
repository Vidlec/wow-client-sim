// The game's maps (UiMap), read once: the zones a character can stand in, by name, and the continent above each
import { useEffect, useState } from "react";
import { api } from "./api.ts";
import type { UiMap } from "./types.ts";

export type Maps = {
  byId: ReadonlyMap<number, UiMap>;
  /** Zones and smaller (type 3 and up), by name */
  zones: readonly UiMap[];
};

const EMPTY: Maps = { byId: new Map(), zones: [] };
const CONTINENT_TYPE = 2;
const ZONE_TYPE = 3;

let loaded: Promise<Maps> | null = null;

const loadMaps = (): Promise<Maps> => {
  loaded ??= api
    .maps()
    .then((maps) => ({
      byId: new Map(maps.map((map) => [map.id, map])),
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

/** The continent a map lies on (itself if it is one), or null */
export const findContinent = (maps: Maps, uiMapId: number): UiMap | null => {
  let map = maps.byId.get(uiMapId);
  for (let depth = 0; map && map.type > CONTINENT_TYPE && depth < 8; depth++) map = maps.byId.get(map.parent);
  return map && map.type === CONTINENT_TYPE ? map : null;
};
