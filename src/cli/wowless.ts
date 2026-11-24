// Fetches wowless's API data into cache/wowless/<product>/ (see src/server/wowless.ts):
//
//   bun run src/cli/wowless.ts [product] [git ref]
//
// The product defaults to the settings' flavour's ("wowf" for WoW: Forever; a "wowlessProduct" setting overrides it),
// the ref to the one the flavour is pinned to (what the server fetches); name another (main) to try a newer one.
import { CACHE_DIR, loadConfig } from "../server/config.ts";
import { findFlavour } from "../server/flavours/index.ts";
import { updateWowless } from "../server/wowless.ts";

const readProduct = (): string => {
  const product = loadConfig().wowlessProduct;
  return typeof product === "string" && product ? product : "wowf";
};

const product = process.argv[2] ?? readProduct();
const ref = process.argv[3] ?? findFlavour(loadConfig().flavour).wowlessRef;
await updateWowless(CACHE_DIR, product, ref, (line) => console.log(line));
