// What switching addons on and off brings with it, for the server (which applies it) and the page (which shows it
// before): one switched on brings the addons it needs, and theirs; one switched off takes the addons that need it
// with it, as they could not load without it. The game's own addons (Blizzard_*) are always there.

/** What this needs of an addon */
export type DependencyInfo = { name: string; dependencies: readonly string[] };

export type AddonPlan = {
  /** The addons on after the change, in the order they were on (new ones after, each after what it needs) */
  addons: string[];
  /** Switched on because something switched on needs them */
  broughtIn: string[];
  /** Switched off because they need something switched off */
  takenOut: string[];
  /** Needed by an addon switched on but not installed: it will not load */
  missing: { addon: string; needs: string }[];
};

const lower = (name: string): string => name.toLowerCase();

/** The game's own addons: always there, never asked for */
export const isGameAddon = (name: string): boolean => /^blizzard_/i.test(name);

/**
 * The addons on after switching some on and some off. Unknown names are dropped; an addon not for this game is kept
 * off by the caller (it is not in the catalog's loadable list).
 */
export const planAddons = (
  catalog: readonly DependencyInfo[],
  current: readonly string[],
  turnOn: readonly string[],
  turnOff: readonly string[],
): AddonPlan => {
  const byName = new Map(catalog.map((entry) => [lower(entry.name), entry]));
  const result: string[] = [];
  const isOn = new Set<string>();
  const add = (name: string): void => {
    const entry = byName.get(lower(name));
    if (!entry || isOn.has(lower(entry.name))) return;
    isOn.add(lower(entry.name));
    result.push(entry.name);
  };
  for (const name of current) add(name);
  // Off first: what is switched off, then (repeatedly) whatever needs something off
  const off = new Set(turnOff.map(lower));
  const takenOut: string[] = [];
  let isChanged = true;
  while (isChanged) {
    isChanged = false;
    for (const name of result) {
      const key = lower(name);
      if (off.has(key)) continue;
      const entry = byName.get(key);
      if (entry?.dependencies.some((dependency) => off.has(lower(dependency)))) {
        off.add(key);
        takenOut.push(name);
        isChanged = true;
      }
    }
  }
  const kept = result.filter((name) => !off.has(lower(name)));
  isOn.clear();
  for (const name of kept) isOn.add(lower(name));
  const addons = [...kept];
  // On: each with what it needs before it, depth first
  const broughtIn: string[] = [];
  const missing: { addon: string; needs: string }[] = [];
  const asked = new Set(turnOn.map(lower));
  const visiting = new Set<string>();
  const bring = (name: string, neededBy: string | null): void => {
    const entry = byName.get(lower(name));
    if (!entry) {
      if (neededBy && !isGameAddon(name)) missing.push({ addon: neededBy, needs: name });
      return;
    }
    const key = lower(entry.name);
    if (isOn.has(key) || visiting.has(key)) return;
    visiting.add(key);
    for (const dependency of entry.dependencies) bring(dependency, entry.name);
    visiting.delete(key);
    isOn.add(key);
    addons.push(entry.name);
    if (!asked.has(key)) broughtIn.push(entry.name);
  };
  for (const name of turnOn) bring(name, null);
  // (an addon already on whose dependency is missing still counts: it will not load either)
  for (const name of addons) {
    const entry = byName.get(lower(name));
    for (const dependency of entry?.dependencies ?? []) {
      if (!byName.has(lower(dependency)) && !isGameAddon(dependency)) {
        if (!missing.some((item) => item.addon === entry?.name && item.needs === dependency)) {
          missing.push({ addon: entry?.name ?? name, needs: dependency });
        }
      }
    }
  }
  return { addons, broughtIn, takenOut, missing };
};

/** The addons switched on that need this one (directly) */
export const neededBy = (catalog: readonly DependencyInfo[], enabled: ReadonlySet<string>, name: string): string[] =>
  catalog
    .filter(
      (entry) =>
        enabled.has(lower(entry.name)) && entry.dependencies.some((dependency) => lower(dependency) === lower(name)),
    )
    .map((entry) => entry.name);

/**
 * Whether the client lists an addon by its TOC's "## Interface" (one number or several): not when every number is
 * another game line's (120105 is Retail's, 50504 MoP Classic's; Forever's 16001 is line 1). An older number of the
 * same line is an out-of-date addon, listed. No Interface line: listed. As lua/addons.lua's isForThisGame.
 */
export const isForThisGame = (interfaceText: string | undefined, clientInterface: number): boolean => {
  const numbers = (interfaceText ?? "").match(/\d+/g);
  if (!numbers) return true;
  const line = Math.floor(clientInterface / 10000);
  return numbers.some((number) => Math.floor(Number(number) / 10000) === line);
};
