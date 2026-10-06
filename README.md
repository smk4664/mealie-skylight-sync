# mealie-skylight-sync

Mirror your [Mealie](https://mealie.io) meal plan onto a
[Skylight Calendar](https://www.ourskylight.com)'s meal board, so the
family sees the week's dinners on the frame without opening an app.

One-way sync: **Mealie is the source of truth.** Within a rolling window
(default 14 days) the sync creates, updates, and deletes Skylight meal
sittings to exactly match the Mealie meal plan. Runs as a small Docker
container (arm64/amd64) on a daily schedule — built for homelab
deployment (tested with [Komodo](https://komo.do) on a Raspberry Pi 5).

> **Disclaimer:** Uses the unofficial
> [go-skylight](https://github.com/sebrandon1/go-skylight) CLI against
> Skylight's undocumented API. Not affiliated with Skylight or Mealie.
> Behavior may change without notice.

## How it maps

| Mealie | Skylight |
|---|---|
| breakfast / lunch / dinner entry with a recipe | recipe sitting (recipe auto-created on Skylight, matched by title, linked back to Mealie) |
| note-only entry (no recipe) | text sitting |
| `side` entry | text sitting ("Side: ...") in the Dinner category |
| snack / drink / dessert | skipped (no Skylight equivalent) |

Sittings are matched by `date + category + (recipe or text)`. A changed
meal is a delete + create. Reruns are no-ops (fully idempotent, no local
state). A sanity brake refuses to delete more than `WINDOW_DAYS + 2`
sittings in one run, so a bad Mealie read can't wipe the board.

## Setup

### 1. Mealie API token

Mealie → user profile → **API Tokens** → create one.

### 2. Skylight auth (pick one)

- **Email + password (easiest):** set `SKYLIGHT_EMAIL` and
  `SKYLIGHT_PASSWORD`. On first run the container logs in and saves the
  OAuth refresh token to its config volume; after that the stored token
  is used and rotated automatically.
- **Refresh token:** set `SKYLIGHT_REFRESH_TOKEN` (get one by running
  `skylight login` anywhere and reading `~/.skylight/config`).

Either way, the rotated token lives in the `skylight-config` volume.
**Don't share one login's config between two installs** (e.g. your
laptop and the container) — token rotation makes them invalidate each
other. Logging in twice (once per install) gives each its own token.

### 3. Frame ID

```bash
skylight frame list --output json | jq -r '.[] | .id + "  " + .name'
```

(Note: go-skylight v0.2.6 ignores the `SKYLIGHT_FRAME_ID` env var —
this sync passes `--frame-id` explicitly on every call.)

### 4. Configure

Copy `.env.example` to `.env` (or set the variables in your
orchestrator). All variables:

| Variable | Default | Meaning |
|---|---|---|
| `MEALIE_URL` | — | Base URL of your Mealie instance |
| `MEALIE_TOKEN` | — | Mealie API token |
| `SKYLIGHT_FRAME_ID` | — | Target frame |
| `SKYLIGHT_REFRESH_TOKEN` | — | Auth option A |
| `SKYLIGHT_EMAIL` / `SKYLIGHT_PASSWORD` | — | Auth option B |
| `WINDOW_DAYS` | `14` | Mirror window: today → today+N |
| `SYNC_AT` | `05:00` | Daily sync time (in `TZ`) |
| `RUN_MODE` | `loop` | `loop` (sync now, then daily) or `oneshot` |
| `DRY_RUN` | `never` | `never` \| `always` \| `once` (first cycle dry, then live) |
| `TZ` | `America/Chicago` | Container timezone |

### 5. Run

```bash
docker compose up -d --build
docker compose logs -f   # watch the first sync
```

The sync runs immediately on start/restart, then daily at `SYNC_AT` —
so restarting the container doubles as a manual "sync now".

**First deploy tip:** set `DRY_RUN=once`. The first cycle only logs
what it *would* do; review the diff in the logs, and the next scheduled
cycle (or a restart with `DRY_RUN=never`) goes live.

### Komodo deployment

1. **Stacks → New Stack**, point it at this repo (it builds the
   Dockerfile on your host — arm64 works natively; `pull_policy: build`
   keeps Komodo's image pre-pull from looking for it on Docker Hub).
2. Add the environment variables above in the stack's Environment
   (put `MEALIE_TOKEN` and the Skylight credentials in Komodo
   secrets/variables). Set `DRY_RUN=once` for the first deploy.
3. Deploy, then check the container log for the dry-run diff.
4. Happy? Set `DRY_RUN=never` and redeploy. Done — restarts of the
   stack double as manual syncs.

## Local testing (no Docker)

```bash
# needs: bash, curl, jq, and the skylight binary on PATH
set -a; source .env; set +a
RUN_MODE=oneshot DRY_RUN=always ./sync.sh
```

Works on macOS (BSD date) and Linux (GNU date).

## Credits

- [sebrandon1/go-skylight](https://github.com/sebrandon1/go-skylight) —
  the CLI doing all the Skylight heavy lifting.
- [Mealie](https://mealie.io) — the recipe manager worth self-hosting.

MIT licensed. PRs welcome.
