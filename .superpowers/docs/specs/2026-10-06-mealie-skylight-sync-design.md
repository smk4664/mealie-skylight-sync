# Mealie → Skylight Meal Sync — Design

**Date:** 2026-10-06
**Status:** Approved pending final spec review
**Owner:** Stephen Kiely

## 1. Purpose

A containerized sync that mirrors Mealie meal plans onto a Skylight
Calendar's meal board, so the family sees the week's dinners on the
frame without anyone touching the Skylight app. Runs in Stephen's
homelab (RPi 5, arm64) as a Komodo-managed stack. Public GitHub repo —
secrets stay in Komodo env.

## 2. Requirements (as agreed)

| # | Requirement | Decision |
|---|---|---|
| R1 | Direction | One-way: Mealie is the single source of truth. |
| R2 | Policy | Full mirror within a window: create, update, AND delete Skylight sittings to match Mealie. Direct edits on Skylight get overwritten. |
| R3 | Window | Today → +14 days (`WINDOW_DAYS=14`). |
| R4 | Cadence | On container start/restart (immediate), then daily at `SYNC_AT` (default 05:00 local). Restarting the stack doubles as "sync now". |
| R5 | Auth bootstrap | Precedence: persisted config file > `SKYLIGHT_REFRESH_TOKEN` env > `SKYLIGHT_EMAIL`+`SKYLIGHT_PASSWORD` (runs `skylight login --save` once). Config dir persisted in a named volume because go-skylight ROTATES refresh tokens. |
| R6 | Implementation | Bash script wrapping the `skylight` CLI (go-skylight) + `curl`/`jq` for Mealie. No Go code of our own. |
| R7 | Deployment | Public GitHub repo `mealie-skylight-sync`; Komodo builds the Dockerfile (arm64-native on the RPi). |

## 3. Architecture

```
mealie-skylight-sync/
├── Dockerfile        # multi-stage: skylight binary from sebrandon1/go-skylight
│                     #   (publishes linux/arm64) onto alpine + bash curl jq tzdata
├── sync.sh           # mirror logic (below); also the container entrypoint loop
├── compose.yaml      # Komodo stack: one service, env-driven, named volume
├── .env.example      # every variable documented; no secrets
├── .superpowers/docs/specs/   # this design doc
└── README.md         # setup: Skylight login, Mealie token, Komodo deploy
```

### 3.1 Configuration (env)

```
MEALIE_URL=https://meals.snjnet.icu
MEALIE_TOKEN=<Mealie API token>
SKYLIGHT_FRAME_ID=<frame id>
SKYLIGHT_REFRESH_TOKEN=<optional; see auth precedence>
SKYLIGHT_EMAIL=<optional>
SKYLIGHT_PASSWORD=<optional>
WINDOW_DAYS=14
SYNC_AT=05:00
RUN_MODE=loop            # loop | oneshot
DRY_RUN=                 # non-empty = log actions without applying
TZ=America/Chicago
```

### 3.2 Container behavior

- `RUN_MODE=loop` (default): sync immediately on start, then sleep
  until the next `SYNC_AT`, repeat. A failed cycle logs loudly and
  waits for the next cycle — it does NOT crash-loop the container.
- `RUN_MODE=oneshot`: single sync, exit code reflects success. Used
  for local testing and ad-hoc runs (`docker compose run sync`).
- `DRY_RUN`: prints every create/update/delete it WOULD do. First
  deploy runs dry to review the diff before letting it write.
- Named volume mounted at `/root/.skylight` so rotated refresh tokens
  survive restarts (R5).

## 4. Sync algorithm (stateless; no DB, no local cache)

1. **Fetch Mealie plan**: `GET /api/households/mealplans?start_date=<today>&end_date=<today+WINDOW_DAYS>`.
2. **Fetch Skylight state**: `skylight meal sittings --date-min --date-max`,
   `skylight meal recipes`, `skylight meal categories` (all `--output json`).
3. **Map entry types → Skylight meal categories** by case-insensitive
   name: breakfast → Breakfast, lunch → Lunch, dinner → Dinner.
   `side` entries fold into the same date's dinner sitting summary
   ("side: ..."). snack/drink/dessert are skipped (logged once).
4. **Ensure recipes**: match Mealie recipe → Skylight recipe by exact
   title. Create missing ones with title, truncated description, and
   the Mealie recipe URL. Note-only Mealie entries (no recipe) get a
   minimal Skylight recipe named after the note title (sittings
   require a recipe-id).
5. **Diff per (date, category)** and apply:
   - missing in Skylight → `meal create-sitting`
   - wrong recipe/summary → `meal update-sitting`
   - in Skylight but not Mealie (within window) → `meal delete-sitting --yes`
6. **Log** every action to stdout (Komodo log view). Exit nonzero on
   failure in oneshot mode.

### 4.1 Idempotency

A second run immediately after a successful run makes zero writes.
All matching is by (date, category) and exact recipe title — no state
files, so the container is disposable.

## 5. Error handling

- Any Mealie/Skylight API failure: log the HTTP status/stderr, skip
  the apply phase (never mirror from a partial read), fail the cycle.
- Auth failure after login attempts: actionable log line ("refresh
  token invalid and no credentials provided — re-run skylight login").
- Deletes are bounded by the window: the script refuses to delete
  more than `WINDOW_DAYS + 2` sittings in one run (sanity brake
  against a bad Mealie read wiping the board).

## 6. Verification

1. Local oneshot `DRY_RUN=1` against the real frame: diff output
   reviewed by hand against the current Mealie plan (week of 10/01).
2. Local oneshot live: sittings appear on the frame; rerun is a no-op.
3. Mutation test: move a Mealie entry a day, rerun, confirm the
   sitting moves; delete it, rerun, confirm the sitting goes.
4. On the RPi via Komodo: deploy, confirm start-sync fires, check
   logs; confirm volume persists config across a restart.

## 7. Out of scope

- Two-way sync (Skylight edits back to Mealie).
- Grocery/Instacart integration (go-skylight supports it; later).
- Syncing Mealie shopping lists (household uses Apple Reminders).
- Photos, chores, rewards — meals only.

## 8. Decision log

| Decision | Choice | Why |
|---|---|---|
| Mirror vs additive | Mirror window | Mealie is source of truth; plan edits must propagate; idempotent |
| Schedule | In-container daily loop + sync-on-start | No Komodo scheduling config; restart = manual sync |
| Language | Bash + skylight CLI | CLI already handles auth rotation/retries; ~150 lines vs a Go codebase |
| Repo | New public repo | Homelab deployable separate from personal planning repo; community value |
| Token persistence | Named volume for /root/.skylight | go-skylight rotates refresh tokens; ephemeral loss = auth death spiral |
