# AddonSim in Docker

The image is AddonSim built from these sources, with everything it runs on inside: Bun, LuaJIT 2.1 (built from its
sources) and the native core (Rust). Nothing else is installed on the machine running it. There are no binary
releases: build the image from a checkout.

## Start it

```
docker compose up --build
```

Then open http://localhost:8765/ and finish the setup in the page: choose your AddOns folder with **Browse…** (the
page's own folder browser; it points out AddOns folders and the game's install), and download the game's interface
source with its button. The first start fetches the game's art and tables (a few minutes), then the simulator starts.

A container sees only the host folders given to it. `compose.yaml` gives it your home folder, read-only, at `/host`:
that is where the browser starts, and where the setup looks for the game's install by itself. When the game (or your
addons) is somewhere else, name that folder instead:

```
ADDONSIM_FOLDER=/path/to/games docker compose up --build          (macOS, Linux)
$env:ADDONSIM_FOLDER = "R:\"; docker compose up --build             (Windows PowerShell)
```

Without Compose, the same by hand:

```
docker build -t addonsim .
docker run --rm -p 127.0.0.1:8765:8765 -v addonsim-data:/data -v "<a folder with your addons in it>:/host:ro" addonsim
```

The page is published to this machine only (`127.0.0.1:`): its folder browser lists the folders mounted, so it should
not be reachable from the network.

## What is kept where

Everything the app keeps is in `/data` (the `addonsim-data` volume): a new container with the same volume picks up
where the last one stopped. Your addons are only read (the mount is read-only); saved variables go to `/data/saved`.

| In `/data` | What |
| --- | --- |
| `cache/` | The game's files from wago.tools, the boot cache, the native core's loaded copy |
| `saved/` | The addons' saved variables and the simulator's own state |
| `interface/` | The interface source the setup downloaded |
| `config/addonsim/settings.json` | The settings (the page's setup and settings change them) |

`docker volume rm addonsim-data` starts from nothing.

## A project's scenarios

A project (a folder with an `addonsim.config.ts`, as WowAddons is) runs its scenarios in the image with the CLI. Mount
it at `/project`, give its own `node_modules` an empty volume (a link made on another machine would point nowhere:
the image has the `addonsim` package its config imports), and the folder its installed addons are in at `/host`:

```
docker run --rm -v addonsim-data:/data -v "<the project>:/project" -v /project/node_modules -w /project \
  -v "<a folder with your addons in it>:/host:ro" addonsim addonsim test
```

Any CLI command works the same way (`addonsim run <scenario>`, `addonsim eval '<lua>'`); the data volume is shared
with the page's container, so the game's files are fetched once. The picture tools (`addonsim shot`, `bun run shots`)
need Chrome, which the image does not have.

## Settings for the container

The image sets these (`docker run -e` changes them):

| Variable | In the image | What |
| --- | --- | --- |
| `ADDONSIM_HOST` | `0.0.0.0` | The address the page is served on inside the container (outside one: `127.0.0.1`) |
| `ADDONSIM_NO_BROWSER` | `1` | Never open a browser (there is none in the container) |
| `ADDONSIM_BROWSE` | `/host` | Where the page's folder browser starts, and where the setup looks for the game |
| `XDG_CONFIG_HOME` | `/data/config` | Where the settings are kept |

The port inside is the settings' (8765); publish another outside with `-p 127.0.0.1:9000:8765`.
