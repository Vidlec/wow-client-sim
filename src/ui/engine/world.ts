// Behind the interface, where the game draws its world: the loading screen of the continent the character is on (the
// wide one, as the game shows it), found from the map's parents (/api/maps, read once for the page)
import { artUrl } from "./textures.ts";

type UiMap = { id: number; name: string; type: number; parent: number };

const LOADING_SCREENS = { kalimdor: 343002, eastern: 343001 } as const;
const CONTINENT_TYPE = 2;
const MAX_DEPTH = 8;

let maps: Promise<Map<number, UiMap>> | null = null;
const loadMaps = (): Promise<Map<number, UiMap>> => {
  maps ??= fetch("/api/maps")
    .then((response) => response.json() as Promise<UiMap[]>)
    .then((rows) => new Map(rows.map((map) => [map.id, map])))
    .catch(() => {
      maps = null; // (asked again next time)
      return new Map<number, UiMap>();
    });
  return maps;
};

/** The loading screen's file id for a map, or null (no continent with one) */
export const loadingScreenOf = async (uiMapId: number): Promise<number | null> => {
  const byId = await loadMaps();
  let continent = byId.get(uiMapId);
  for (let depth = 0; continent && continent.type > CONTINENT_TYPE && depth < MAX_DEPTH; depth++) {
    continent = byId.get(continent.parent);
  }
  const name = continent ? continent.name.toLowerCase() : "";
  return name.includes("kalimdor")
    ? LOADING_SCREENS.kalimdor
    : name.includes("eastern")
      ? LOADING_SCREENS.eastern
      : null;
};

/** The world element shows the picture, or nothing; the latest call wins */
export const createWorldBackdrop = (world: HTMLElement): ((uiMapId: number | null) => void) => {
  let asked = 0;
  return (uiMapId) => {
    asked += 1;
    const call = asked;
    const show = (picture: number | null): void => {
      if (call !== asked) return;
      world.style.background = picture ? `url("${artUrl(picture)}") center / cover no-repeat` : "";
      world.style.filter = picture ? "brightness(0.6)" : "";
    };
    if (uiMapId === null) show(null);
    else void loadingScreenOf(uiMapId).then(show);
  };
};
