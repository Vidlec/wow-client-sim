// The SDK's picture page: the page's own picture renderer (src/ui/engine/picture.ts, ?shot=) alone, without the shell,
// so the page the SDK serves is small and quick to build.
import { runPicturePage } from "../../ui/engine/picture.ts";

const root = document.getElementById("root");
if (root) runPicturePage(root);
