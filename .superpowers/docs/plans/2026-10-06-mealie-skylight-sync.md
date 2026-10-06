# Mealie → Skylight Sync Implementation Plan

> **For agentic workers:** Execute task-by-task with verification between
> tasks. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Containerized bash script that mirrors Mealie meal plans onto a
Skylight Calendar meal board, deployed via Komodo on an arm64 RPi 5.

**Architecture:** Single bash script (`sync.sh`) wrapping the go-skylight
CLI for Skylight and curl/jq for Mealie. Stateless mirror within a date
window. Docker image built FROM sebrandon1/go-skylight (alpine). Spec:
`.superpowers/docs/specs/2026-10-06-mealie-skylight-sync-design.md`.

**Tech Stack:** bash, jq, curl, go-skylight CLI v0.2.6, Docker (arm64), Komodo.

## Global Constraints

- Mealie v3.9.2 at `$MEALIE_URL`; plan entries from
  `GET /api/households/mealplans?start_date&end_date` (Bearer token).
- Skylight JSON field quirks: recipe title serializes as `summary`;
  sittings read back `recipe_id` but are created with `meal_recipe_id`
  (CLI flags hide this); categories use `label` for name.
- Binary name: `skylight` (release tarballs) vs `go-skylight` (Docker
  image) — script resolves whichever exists.
- Alpine needs `coreutils` for GNU `date -d`, plus `bash curl jq tzdata`.
- `/root/.skylight` must be a named volume (refresh tokens ROTATE).
- DRY_RUN tri-state: `never` (default) | `always` | `once` (first cycle
  dry, then live); `1`/`true` accepted as `always`.
- Delete sanity brake: abort if a cycle would delete > WINDOW_DAYS + 2
  sittings.
- I (Claude) never type or echo Stephen's Skylight password — login is
  a USER ACTION step in his own terminal.

---

### Task 1: Scaffold

**Files:** Create `.gitignore`, `.env.example`, `LICENSE` (MIT), `bin/.gitkeep`.

- [ ] **Step 1:** `.gitignore`:

```
.env
bin/skylight
*.tar.gz
.DS_Store
```

- [ ] **Step 2:** `.env.example`:

```bash
# --- Mealie ---
MEALIE_URL=https://meals.example.com
MEALIE_TOKEN=            # Mealie: user profile -> API Tokens

# --- Skylight ---
SKYLIGHT_FRAME_ID=       # `skylight frame info` after login, or from app URL
# Auth (pick ONE; persisted config in the volume wins once it exists):
SKYLIGHT_REFRESH_TOKEN=  # option A: bring your own refresh token
SKYLIGHT_EMAIL=          # option B: email+password; the container runs
SKYLIGHT_PASSWORD=       #   `skylight login --save` once, then uses config

# --- Sync behavior ---
WINDOW_DAYS=14           # mirror window: today .. today+N
SYNC_AT=05:00            # daily sync time (TZ below)
RUN_MODE=loop            # loop | oneshot
DRY_RUN=never            # never | always | once
TZ=America/Chicago
```

- [ ] **Step 3:** MIT LICENSE (standard text, 2026, Stephen Kiely).
- [ ] **Step 4:** Commit: `git add -A && git commit -m "chore: scaffold"`

### Task 2: Local CLI + auth (USER ACTION) + API discovery

- [ ] **Step 1:** Download the darwin_arm64 v0.2.6 release binary to
  `bin/skylight` (gitignored) via
  `gh release download v0.2.6 --repo sebrandon1/go-skylight --pattern '*darwin_arm64*'`,
  extract, `chmod +x`.
- [ ] **Step 2 (USER ACTION — Stephen, in his own terminal):**
  `bin/skylight login --email <email> --password <password> --save`
  (writes `~/.skylight/config`; Claude never sees the password).
- [ ] **Step 3:** Verify auth + discover IDs (Claude):
  `bin/skylight status`, `bin/skylight frame info --output json` → record
  FRAME_ID; `bin/skylight meal categories --output json` → confirm
  Breakfast/Lunch/Dinner labels + exact JSON envelope;
  `bin/skylight meal recipes --output json` and
  `meal sittings --date-min --date-max --output json` → capture REAL
  output shapes (array vs wrapped) and adjust Task 3 jq paths to match.
- [ ] **Step 4:** Document findings as comments at the top of sync.sh.

### Task 3: sync.sh

**Files:** Create `sync.sh` (complete content below; adjust jq paths per
Task 2 findings).

**Interfaces — env in:** all `.env.example` vars. **Out:** stdout logs
`YYYY-MM-DD HH:MM:SS | message`; exit 0/1 in oneshot.

- [ ] **Step 1:** Write `sync.sh`:

```bash
#!/usr/bin/env bash
# Mirror Mealie meal plans onto a Skylight Calendar meal board.
# Stateless: each cycle fetches both sides, diffs, applies. See spec.
set -euo pipefail

: "${MEALIE_URL:?MEALIE_URL required}"
: "${MEALIE_TOKEN:?MEALIE_TOKEN required}"
: "${SKYLIGHT_FRAME_ID:?SKYLIGHT_FRAME_ID required}"
WINDOW_DAYS="${WINDOW_DAYS:-14}"
SYNC_AT="${SYNC_AT:-05:00}"
RUN_MODE="${RUN_MODE:-loop}"
DRY_RUN="${DRY_RUN:-never}"
export SKYLIGHT_FRAME_ID

SKY_BIN="$(command -v skylight || command -v go-skylight || true)"
[[ -n "$SKY_BIN" ]] || { echo "FATAL: skylight binary not found"; exit 1; }

log() { printf '%s | %s\n' "$(date '+%F %T')" "$*"; }
sky() { "$SKY_BIN" "$@" --output json --quiet; }

ensure_auth() {
  # Persisted config (rotated token) outranks possibly-stale env token.
  [[ -f "$HOME/.skylight/config" ]] && unset SKYLIGHT_REFRESH_TOKEN
  "$SKY_BIN" status >/dev/null 2>&1 && return 0
  if [[ -n "${SKYLIGHT_EMAIL:-}" && -n "${SKYLIGHT_PASSWORD:-}" ]]; then
    log "No working auth; running login (token saved to config volume)"
    "$SKY_BIN" login --email "$SKYLIGHT_EMAIL" \
      --password "$SKYLIGHT_PASSWORD" --save >/dev/null 2>&1 || true
    "$SKY_BIN" status >/dev/null 2>&1 && return 0
  fi
  log "ERROR: Skylight auth failed (config/refresh token/credentials all unusable)"
  return 1
}

# ensure_category NAME -> id (creates if missing)
ensure_category() {
  local name="$1" id
  id="$(jq -r --arg n "$name" \
    'map(select((.label|ascii_downcase)==($n|ascii_downcase)))|.[0].id // empty' \
    <<<"$CATEGORIES")"
  if [[ -z "$id" ]]; then
    if [[ -n "$EFFECTIVE_DRY" ]]; then
      log "DRY: would create meal category '$name'"; echo "DRY-CAT"; return
    fi
    log "Creating meal category: $name"
    id="$("$SKY_BIN" meal create-category --name "$name" --output json --quiet | jq -r '.id')"
    CATEGORIES="$(sky meal categories)"
  fi
  echo "$id"
}

# ensure_recipe TITLE DESC URL -> id (creates if missing)
ensure_recipe() {
  local title="$1" desc="$2" url="$3" id
  id="$(jq -r --arg t "$title" 'map(select(.summary==$t))|.[0].id // empty' <<<"$RECIPES")"
  if [[ -z "$id" ]]; then
    if [[ -n "$EFFECTIVE_DRY" ]]; then
      log "DRY: would create recipe '$title'"; echo "DRY-RID"; return
    fi
    log "Creating Skylight recipe: $title"
    local args=(meal create-recipe --title "$title")
    [[ -n "$desc" ]] && args+=(--description "$desc")
    [[ -n "$url" ]] && args+=(--url "$url")
    id="$(sky "${args[@]}" | jq -r '.id')"
    RECIPES="$(sky meal recipes)"
  fi
  echo "$id"
}

run_sync() {
  local start end mealie
  start="$(date +%F)"
  end="$(date -d "+${WINDOW_DAYS} days" +%F)"
  log "Sync window $start..$end (dry=${EFFECTIVE_DRY:-no})"

  mealie="$(curl -sS --fail-with-body -G \
    -H "Authorization: Bearer $MEALIE_TOKEN" \
    --data-urlencode "start_date=$start" \
    --data-urlencode "end_date=$end" \
    --data-urlencode "perPage=200" \
    "$MEALIE_URL/api/households/mealplans")" \
    || { log "ERROR: Mealie fetch failed"; return 1; }

  CATEGORIES="$(sky meal categories)" || { log "ERROR: categories fetch failed"; return 1; }
  RECIPES="$(sky meal recipes)" || { log "ERROR: recipes fetch failed"; return 1; }
  local sittings
  sittings="$(sky meal sittings --date-min "$start" --date-max "$end")" \
    || { log "ERROR: sittings fetch failed"; return 1; }

  # Desired state from Mealie: breakfast/lunch/dinner entries; sides fold
  # into that date's dinner summary; snack/drink/dessert skipped.
  local desired
  desired="$(jq -c --arg mealie_url "$MEALIE_URL" '
    ([.items[] | select(.entryType=="side")
      | {date, note: (.recipe.name // .title // "side")}]
     | group_by(.date)
     | map({key: .[0].date, value: (map(.note) | join("; "))})
     | from_entries) as $sides
    | [.items[]
       | select(.entryType=="breakfast" or .entryType=="lunch" or .entryType=="dinner")
       | {date,
          entryType,
          title: (if .recipe then .recipe.name else (.title // "Untitled") end),
          url:   (if .recipe then ($mealie_url + "/g/home/r/" + .recipe.slug) else "" end),
          desc:  (if .recipe then ((.recipe.description // "")[0:180]) else (.text // "") end)}
       | . + {summary:
           (if .entryType=="dinner" and $sides[.date] then ("side: " + $sides[.date]) else "" end)}]
  ' <<<"$mealie")"

  local skipped
  skipped="$(jq -r '[.items[] | select(.entryType=="snack" or .entryType=="drink" or .entryType=="dessert")] | length' <<<"$mealie")"
  [[ "$skipped" != "0" ]] && log "Skipping $skipped snack/drink/dessert entries (unsupported)"

  # Ensure categories + recipes exist; annotate desired with their ids.
  local annotated="[]"
  while IFS= read -r row; do
    local etype title desc url cat_id rid
    etype="$(jq -r '.entryType' <<<"$row")"
    title="$(jq -r '.title' <<<"$row")"
    desc="$(jq -r '.desc' <<<"$row")"
    url="$(jq -r '.url' <<<"$row")"
    cat_id="$(ensure_category "${etype^}")"       # Breakfast/Lunch/Dinner
    rid="$(ensure_recipe "$title" "$desc" "$url")"
    annotated="$(jq -c --argjson row "$row" --arg cat "$cat_id" --arg rid "$rid" \
      '. + [$row + {cat: $cat, rid: $rid}]' <<<"$annotated")"
  done < <(jq -c '.[]' <<<"$desired")

  # Diff: key = date|category_id
  local actions
  actions="$(jq -cn --argjson want "$annotated" --argjson have "$sittings" '
    ($have | map({key: ((.date[0:10]) + "|" + .meal_category_id), value: .}) | from_entries) as $h
    | ($want | map(.date + "|" + .cat)) as $wkeys
    | ([ $want[] | (.date + "|" + .cat) as $k
        | if ($h[$k] | not)
          then {a:"create", date, cat, rid, title, summary}
          elif ($h[$k].recipe_id != .rid) or (($h[$k].summary // "") != .summary)
          then {a:"update", id: $h[$k].id, date, cat, rid, title, summary}
          else empty end ]
      + [ $h | to_entries[] | select(.key as $k | $wkeys | index($k) | not)
          | {a:"delete", id: .value.id, date: (.value.date[0:10]), title: (.value.summary // "?")} ])
  ')"

  local n_create n_update n_delete
  n_create="$(jq -r 'map(select(.a=="create"))|length' <<<"$actions")"
  n_update="$(jq -r 'map(select(.a=="update"))|length' <<<"$actions")"
  n_delete="$(jq -r 'map(select(.a=="delete"))|length' <<<"$actions")"
  log "Diff: $n_create create, $n_update update, $n_delete delete"

  if (( n_delete > WINDOW_DAYS + 2 )); then
    log "ERROR: sanity brake - refusing to delete $n_delete sittings in one run"
    return 1
  fi

  if [[ "$actions" == "[]" ]]; then log "In sync - no changes."; return 0; fi

  while IFS= read -r act; do
    local a date cat rid title summary id
    a="$(jq -r '.a' <<<"$act")"
    date="$(jq -r '.date // ""' <<<"$act")"
    title="$(jq -r '.title // ""' <<<"$act")"
    if [[ -n "$EFFECTIVE_DRY" ]]; then
      log "DRY: would $a sitting $date '$title'"
      continue
    fi
    case "$a" in
      create)
        cat="$(jq -r '.cat' <<<"$act")"; rid="$(jq -r '.rid' <<<"$act")"
        summary="$(jq -r '.summary' <<<"$act")"
        log "Create sitting: $date '$title'"
        local args=(meal create-sitting --recipe-id "$rid" --date "$date" --meal-category-id "$cat")
        [[ -n "$summary" ]] && args+=(--summary "$summary")
        sky "${args[@]}" >/dev/null
        ;;
      update)
        id="$(jq -r '.id' <<<"$act")"; cat="$(jq -r '.cat' <<<"$act")"
        rid="$(jq -r '.rid' <<<"$act")"; summary="$(jq -r '.summary' <<<"$act")"
        log "Update sitting: $date '$title'"
        sky meal update-sitting --sitting-id "$id" --date "$date" \
          --recipe-id "$rid" --meal-category-id "$cat" --summary "$summary" >/dev/null
        ;;
      delete)
        id="$(jq -r '.id' <<<"$act")"
        log "Delete sitting: $date '$title'"
        sky meal delete-sitting --sitting-id "$id" --yes >/dev/null
        ;;
    esac
  done < <(jq -c '.[]' <<<"$actions")
  log "Cycle complete."
}

next_sync_epoch() {
  local t; t="$(date -d "today ${SYNC_AT}" +%s)"
  (( t > $(date +%s) )) && { echo "$t"; return; }
  date -d "tomorrow ${SYNC_AT}" +%s
}

main() {
  local first=1 rc=0
  while :; do
    EFFECTIVE_DRY=""
    case "$DRY_RUN" in
      always|1|true) EFFECTIVE_DRY=1 ;;
      once) (( first )) && EFFECTIVE_DRY=1 ;;
    esac
    rc=0
    if ensure_auth; then run_sync || rc=$?; else rc=1; fi
    (( rc != 0 )) && log "ERROR: sync cycle failed (rc=$rc)"
    first=0
    [[ "$RUN_MODE" == "oneshot" ]] && exit "$rc"
    local next now; next="$(next_sync_epoch)"; now="$(date +%s)"
    log "Next sync: $(date -d "@$next" '+%F %T') (sleeping $((next-now))s)"
    sleep $(( next - now ))
  done
}
main "$@"
```

- [ ] **Step 2:** `chmod +x sync.sh`; run `shellcheck sync.sh` (brew
  install if missing); fix findings.
- [ ] **Step 3:** Dry oneshot against real APIs:
  `set -a; source .env; set +a; RUN_MODE=oneshot DRY_RUN=always PATH="$PWD/bin:$PATH" ./sync.sh`
  Expected: window log, diff counts, DRY lines, exit 0. Fix jq paths to
  the real CLI envelopes found in Task 2.
- [ ] **Step 4:** Commit.

### Task 4: Mutation verification (live, against the real frame)

- [ ] **Step 1:** Seed: in meal-planner, add a test entry
  (`scripts/mealie.sh mealplan-note` or `mealplan-add` for tomorrow).
- [ ] **Step 2:** Live oneshot run → expect recipe+sitting created; verify
  via `bin/skylight meal sittings` and Stephen eyeballs the frame/app.
- [ ] **Step 3:** Rerun immediately → expect "In sync - no changes."
  (idempotency).
- [ ] **Step 4:** Move the Mealie entry +1 day; rerun → expect 1 create +
  1 delete (or update). Delete the Mealie entry; rerun → expect delete.
- [ ] **Step 5:** Clean up test entries both sides; commit any fixes.

### Task 5: Dockerfile + compose.yaml

- [ ] **Step 1:** `Dockerfile`:

```dockerfile
FROM sebrandon1/go-skylight:0.2.6
RUN apk add --no-cache bash curl jq coreutils tzdata
COPY sync.sh /usr/local/bin/sync.sh
RUN chmod +x /usr/local/bin/sync.sh
ENTRYPOINT ["/usr/local/bin/sync.sh"]
```

- [ ] **Step 2:** `compose.yaml`:

```yaml
services:
  mealie-skylight-sync:
    build: .
    image: mealie-skylight-sync:local
    restart: unless-stopped
    environment:
      - MEALIE_URL=${MEALIE_URL}
      - MEALIE_TOKEN=${MEALIE_TOKEN}
      - SKYLIGHT_FRAME_ID=${SKYLIGHT_FRAME_ID}
      - SKYLIGHT_REFRESH_TOKEN=${SKYLIGHT_REFRESH_TOKEN:-}
      - SKYLIGHT_EMAIL=${SKYLIGHT_EMAIL:-}
      - SKYLIGHT_PASSWORD=${SKYLIGHT_PASSWORD:-}
      - WINDOW_DAYS=${WINDOW_DAYS:-14}
      - SYNC_AT=${SYNC_AT:-05:00}
      - RUN_MODE=${RUN_MODE:-loop}
      - DRY_RUN=${DRY_RUN:-never}
      - TZ=${TZ:-America/Chicago}
    volumes:
      - skylight-config:/root/.skylight
volumes:
  skylight-config:
```

- [ ] **Step 3:** If docker available locally: `docker compose build` +
  `docker compose run --rm -e RUN_MODE=oneshot -e DRY_RUN=always
  mealie-skylight-sync`; expect same dry output as Task 3. If no local
  docker, note it — Komodo builds on the RPi (arm64-native).
- [ ] **Step 4:** Commit.

### Task 6: README

- [ ] **Step 1:** Write README.md: what/why, disclaimer (unofficial
  Skylight API via go-skylight), setup (Mealie token, Skylight auth
  options incl. one-time login and the rotation/volume explanation),
  env table (incl. DRY_RUN tri-state semantics), Komodo deploy steps,
  verification (`DRY_RUN=once` first deploy), credits to
  sebrandon1/go-skylight.
- [ ] **Step 2:** Commit.

### Task 7: Publish

- [ ] **Step 1 (confirm with Stephen it's ready):**
  `gh repo create mealie-skylight-sync --public --source . --push`
- [ ] **Step 2:** Verify repo page renders; paste link.

### Task 8: Komodo deploy (USER ACTION with checklist)

- [ ] **Step 1:** Provide Stephen the Komodo checklist: new Stack →
  repo URL → env vars (secrets as Komodo secrets; DRY_RUN=once for
  first deploy) → deploy → check logs for the dry diff → set
  DRY_RUN=never → redeploy.
- [ ] **Step 2:** Post-deploy: confirm start-sync fired, volume persists
  across a restart (`docker volume ls` on the RPi / Komodo UI), and the
  frame shows the current plan.

## Self-review notes

- Spec coverage: R1-R7 → Tasks 3 (algorithm, auth, dry tri-state),
  5 (volume, image), 4 (idempotency/mutation), 8 (deploy). Sanity brake
  in Task 3 code. ✓
- jq paths are best-guess against lib structs; Task 2 Step 3 exists
  precisely to correct them before they're exercised. ✓
- No placeholders; all code complete. ✓
