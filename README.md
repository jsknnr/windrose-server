# windrose-server

Container image for running a [Windrose](https://store.steampowered.com/) dedicated game server on Linux under Wine. The entrypoint installs/updates the server via SteamCMD, brings up a headless Xvfb display, applies configuration overrides from environment variables, and then launches the server.

## AI Disclosure

I build these game server images for fun and share them with the community. Most of them I run myself in my Kubernetes environment for my friend group. I've always built them by hand following my own sort of recipe. This time, I decided it would be interesting to see what AI could come up with. So with my guidance, I prompted the AI with very specific instructions and I think it did quite well. Hate it or love it, AI isn't going any where. At the very least, this saved me a bunch of time.

Crafted with Claude Opus 4.6, reviewed and massaged by a human.

## Contents

- [How it works](#how-it-works)
- [Building the image](#building-the-image)
- [Persistence](#persistence)
- [Configuration](#configuration)
  - [Container variables](#container-variables)
  - [Server variables (`ServerDescription.json`)](#server-variables-serverdescriptionjson)
  - [World variables (`WorldDescription.json`)](#world-variables-worlddescriptionjson)
- [Finding your invite code](#finding-your-invite-code)
- [Running with Docker](#running-with-docker)
- [Running with Docker Compose](#running-with-docker-compose)
- [Running with Podman](#running-with-podman)

## How it works

On every start the entrypoint:

1. Updates the server files via SteamCMD (app id `4129620`).
2. Starts Xvfb on `:0` (unless `DISPLAY` is already set) and initializes a Wine prefix.
3. If `SKIP_CONFIG` is **not** `true` and the config files are missing, it starts the server briefly to let it write defaults, then stops that bootstrap process.
4. Applies every `WINDROSE_*` environment variable that is set to `ServerDescription.json` / `WorldDescription.json`. Unset variables are left alone.
5. Launches the server in the foreground and forwards `SIGINT` / `SIGTERM` for graceful shutdown.

Configuration overrides are re-applied on every start, so the environment is the source of truth. Set `SKIP_CONFIG=true` if you want to manage the JSON files by hand.

## Building the image

```sh
make build
# or directly:
docker build -f container/Containerfile -t windrose-server:latest container
```

## Persistence

The server install lives at `/home/steam/windrose` (also where the generated configs live under `R5/`). Mount a volume there to persist the game install, world saves, and configuration across restarts:

```sh
-v windrose-data:/home/steam/windrose
```

Without a volume, SteamCMD will re-download the server on every run and every world will be fresh.

## Configuration

### Container variables

| Variable | Default | Description |
|---|---|---|
| `SKIP_CONFIG` | `false` | If `true`, the entrypoint will not modify config files. Startup fails if `ServerDescription.json` or `WorldDescription.json` is missing. |
| `BOOTSTRAP_TIMEOUT_SECS` | `300` | Max seconds to wait for the server to generate defaults during first-boot bootstrap. |
| `BOOTSTRAP_SETTLE_SECS` | `3` | Seconds to wait after config files appear before stopping the bootstrap server. |

### Server variables (`ServerDescription.json`)

| Variable | Type | Constraints |
|---|---|---|
| `WINDROSE_SERVER_NAME` | string | Free-form display name. |
| `WINDROSE_INVITE_CODE` | string | At least 6 characters, `0-9`/`a-z`/`A-Z` only, case-sensitive. |
| `WINDROSE_PASSWORD` | string | Non-empty value sets `IsPasswordProtected=true`; empty string disables password protection. Leave unset to keep whatever is already in the file. |
| `WINDROSE_MAX_PLAYERS` | integer | Max simultaneous players. |
| `WINDROSE_P2P_PROXY_ADDRESS` | string | Listen address for the P2P relay socket (e.g. `127.0.0.1`). |

`PersistentServerId` and `WorldIslandId` are intentionally not exposed — the game manages them and the vendor docs warn against editing them.

### World variables (`WorldDescription.json`)

| Variable | Type | Constraints / Default |
|---|---|---|
| `WINDROSE_WORLD_NAME` | string | World display name. |
| `WINDROSE_WORLD_PRESET` | enum | `Easy`, `Medium`, `Hard`, or `Custom`. Any custom parameter below will cause the game to force the preset to `Custom` on next launch. |
| `WINDROSE_WORLD_COOP_QUESTS` | bool | Default `true`. Shared co-op quest completion. |
| `WINDROSE_WORLD_EASY_EXPLORE` | bool | Default `false`. Disables map markers for points of interest. |
| `WINDROSE_WORLD_MOB_HEALTH_MULTIPLIER` | float | Default `1.0`; range `[0.2, 5.0]`. |
| `WINDROSE_WORLD_MOB_DAMAGE_MULTIPLIER` | float | Default `1.0`; range `[0.2, 5.0]`. |
| `WINDROSE_WORLD_SHIP_HEALTH_MULTIPLIER` | float | Default `1.0`; range `[0.4, 5.0]`. |
| `WINDROSE_WORLD_SHIP_DAMAGE_MULTIPLIER` | float | Default `1.0`; range `[0.2, 2.5]`. |
| `WINDROSE_WORLD_BOARDING_DIFFICULTY_MULTIPLIER` | float | Default `1.0`; range `[0.2, 5.0]`. |
| `WINDROSE_WORLD_COOP_STATS_CORRECTION_MODIFIER` | float | Default `1.0`; range `[0.0, 2.0]`. Scales enemy HP/posture by player count. |
| `WINDROSE_WORLD_COOP_SHIP_STATS_CORRECTION_MODIFIER` | float | Default `0.0`; range `[0.0, 2.0]`. Scales enemy ship HP by player count. |
| `WINDROSE_WORLD_COMBAT_DIFFICULTY` | enum | `Easy`, `Normal`, or `Hard`. Default `Normal`. |

Booleans accept `true`/`false`/`1`/`0`/`yes`/`no`/`on`/`off` (case-insensitive). Numeric values are written to JSON verbatim — invalid numbers will fail fast at startup.

## Finding your invite code

Once the server is running, read the generated code out of the config file:

```sh
docker exec windrose-server \
  jq -r '.ServerDescription_Persistent.InviteCode' \
  /home/steam/windrose/R5/ServerDescription.json
```

Paste it into the game client under **Play → Connect to Server**.

## Running with Docker

First run (server generates defaults, then your overrides are applied):

```sh
docker volume create windrose-data

docker run -d \
  --name windrose-server \
  -v windrose-data:/home/steam/windrose \
  -e WINDROSE_SERVER_NAME="My Crew" \
  -e WINDROSE_MAX_PLAYERS=4 \
  -e WINDROSE_PASSWORD="hunter2" \
  -e WINDROSE_WORLD_NAME="Spice Route" \
  -e WINDROSE_WORLD_PRESET=Custom \
  -e WINDROSE_WORLD_COMBAT_DIFFICULTY=Hard \
  -e WINDROSE_WORLD_MOB_DAMAGE_MULTIPLIER=1.5 \
  sknnr/windrose-server:latest
```

Tail logs:

```sh
docker logs -f windrose-server
```

Stop gracefully (the entrypoint forwards the signal to the server and waits for it):

```sh
docker stop windrose-server
```

Using an env file:

```sh
docker run -d \
  --name windrose-server \
  --env-file windrose.env \
  -v windrose-data:/home/steam/windrose \
  sknnr/windrose-server:latest
```

The `Makefile` wraps this pattern — `make run ENV_FILE=windrose.env VOLUME_ARGS="-v windrose-data:/home/steam/windrose"`.

## Running with Docker Compose

`docker-compose.yml`:

```yaml
services:
  windrose:
    image: sknnr/windrose-server:latest
    container_name: windrose-server
    restart: unless-stopped
    volumes:
      - windrose-data:/home/steam/windrose
    environment:
      WINDROSE_SERVER_NAME: "My Crew"
      WINDROSE_MAX_PLAYERS: "4"
      WINDROSE_PASSWORD: "hunter2"
      WINDROSE_WORLD_NAME: "Spice Route"
      WINDROSE_WORLD_PRESET: "Custom"
      WINDROSE_WORLD_COMBAT_DIFFICULTY: "Hard"
      WINDROSE_WORLD_MOB_HEALTH_MULTIPLIER: "1.25"
      WINDROSE_WORLD_COOP_STATS_CORRECTION_MODIFIER: "1.0"

volumes:
  windrose-data:
```

```sh
docker compose up -d
docker compose logs -f windrose
docker compose down
```

To freeze the configuration after you've hand-edited the JSON files in the volume, set `SKIP_CONFIG: "true"`:

```yaml
    environment:
      SKIP_CONFIG: "true"
```

## Running with Podman

Podman uses the same flags as Docker. As a rootless user:

```sh
podman volume create windrose-data

podman run -d \
  --name windrose-server \
  -v windrose-data:/home/steam/windrose \
  -e WINDROSE_SERVER_NAME="My Crew" \
  -e WINDROSE_MAX_PLAYERS=4 \
  -e WINDROSE_WORLD_PRESET=Medium \
  docker.io/sknnr/windrose-server:latest
```

Generate a systemd unit for auto-start on a host machine:

```sh
podman generate systemd --new --name windrose-server \
  > ~/.config/systemd/user/windrose-server.service
systemctl --user daemon-reload
systemctl --user enable --now windrose-server.service
```

## Running with Kubernetes

I've built a Helm chart and have included it in the `helm` directory within this repo. Modify the `values.yaml` file to your liking and install the chart into your cluster.

The chart in this repo is also hosted in my helm-charts repository [here](https://jsknnr.github.io/helm-charts)

To install this chart from my helm-charts repository:

```bash
helm repo add jsknnr https://jsknnr.github.io/helm-charts
helm repo update
```

To install the chart from the repo:

```bash
helm install windrose jsknnr/windrose-server --values myvalues.yaml
# Where myvalues.yaml is your copy of the Values.yaml file with the settings that you want
```
