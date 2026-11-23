// Fetches wowless's API data into cache/wowless/<product>/ (see src/server/wowless.ts):
//
//   bun run src/cli/wowless.ts [product] [git ref]
//
// The product defaults to the settings' flavour's ("wowf" for WoW: Forever; a "wowlessProduct" setting overrides it),
// the ref to main.
import { CACHE_DIR, loadConfig } from "../server/config.ts";
import { updateWowless } from "../server/wowless.ts";

const readProduct = (): string => {
  const product = loadConfig().wowlessProduct;
  return typeof product === "string" && product ? product : "wowf";
};

const product = process.argv[2] ?? readProduct();
const ref = process.argv[3] ?? "main";
await updateWowless(CACHE_DIR, product, ref, (line) => console.log(line));
