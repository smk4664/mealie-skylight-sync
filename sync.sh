#!/usr/bin/env bash
# Mirror Mealie meal plans onto a Skylight Calendar meal board.
# Stateless: each cycle fetches both sides, diffs, applies.
# Spec: .superpowers/docs/specs/2026-10-06-mealie-skylight-sync-design.md
#
# API findings (discovered 2026-10-06 against go-skylight v0.2.6):
# - SKYLIGHT_FRAME_ID env var is BROKEN in v0.2.6; --frame-id flag works.
# - meal categories/recipes/sittings return FLAT JSON arrays (no envelope).
# - Recipe title lives in "summary"; category name in "label".
# - Sittings: date (YYYY-MM-DD), recipe_id, meal_category_id, summary, id.
set -euo pipefail

: "${MEALIE_URL:?MEALIE_URL required}"
: "${MEALIE_TOKEN:?MEALIE_TOKEN required}"
: "${SKYLIGHT_FRAME_ID:?SKYLIGHT_FRAME_ID required}"
WINDOW_DAYS="${WINDOW_DAYS:-14}"
SYNC_AT="${SYNC_AT:-05:00}"
RUN_MODE="${RUN_MODE:-loop}"
DRY_RUN="${DRY_RUN:-never}"

SKY_BIN="$(command -v skylight || command -v go-skylight || true)"
[[ -n "$SKY_BIN" ]] || { echo "FATAL: skylight binary not found"; exit 1; }

# Logs go to STDERR: several callers capture function stdout via $(...),
# and a stdout log line would corrupt the captured value (recipe ids etc).
log() { printf '%s | %s\n' "$(date '+%F %T')" "$*" >&2; }

# v0.2.6 ignores SKYLIGHT_FRAME_ID env; always pass the flag.
sky() { "$SKY_BIN" "$@" --frame-id "$SKYLIGHT_FRAME_ID" --output json --quiet; }

# --- date helpers: GNU (container/linux) vs BSD (macOS local testing) ---
if date -d tomorrow >/dev/null 2>&1; then GNU_DATE=1; else GNU_DATE=; fi
date_plus_days() {  # N -> YYYY-MM-DD
  if [[ -n "$GNU_DATE" ]]; then date -d "+$1 days" +%F; else date -v"+$1d" +%F; fi
}
epoch_at() {  # HH:MM on today|tomorrow -> epoch seconds
  local day="$1" hm="$2"
  if [[ -n "$GNU_DATE" ]]; then
    date -d "$day $hm" +%s
  else
    local base; base="$(date +%F)"
    [[ "$day" == "tomorrow" ]] && base="$(date -v+1d +%F)"
    date -j -f "%Y-%m-%d %H:%M" "$base $hm" +%s
  fi
}
epoch_fmt() {  # epoch -> readable
  if [[ -n "$GNU_DATE" ]]; then date -d "@$1" '+%F %T'; else date -r "$1" '+%F %T'; fi
}

ensure_auth() {
  # Persisted config (rotated token) outranks a possibly-stale env token.
  [[ -f "$HOME/.skylight/config" ]] && unset SKYLIGHT_REFRESH_TOKEN
  sky meal categories >/dev/null 2>&1 && return 0
  if [[ -n "${SKYLIGHT_EMAIL:-}" && -n "${SKYLIGHT_PASSWORD:-}" ]]; then
    log "No working auth; running login (token saved to config volume)"
    "$SKY_BIN" login --email "$SKYLIGHT_EMAIL" \
      --password "$SKYLIGHT_PASSWORD" --save >/dev/null 2>&1 || true
    sky meal categories >/dev/null 2>&1 && return 0
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
    id="$(sky meal create-category --name "$name" | jq -r '.id')"
    CATEGORIES="$(sky meal categories)"
  fi
  echo "$id"
}

# ensure_recipe TITLE DESC URL -> id (creates if missing; matches by title)
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
  end="$(date_plus_days "$WINDOW_DAYS")"
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

  # Desired state: breakfast/lunch/dinner entries become sittings; "side"
  # entries fold into that date's dinner summary; snack/drink/dessert skip.
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
  [[ "$skipped" != "0" ]] && log "Skipping $skipped snack/drink/dessert entries (no Skylight equivalent)"

  # Ensure categories + recipes exist; annotate desired rows with ids.
  local annotated="[]" row etype title desc url cat_id rid
  while IFS= read -r row; do
    etype="$(jq -r '.entryType' <<<"$row")"
    title="$(jq -r '.title' <<<"$row")"
    desc="$(jq -r '.desc' <<<"$row")"
    url="$(jq -r '.url' <<<"$row")"
    cat_id="$(ensure_category "$(tr '[:lower:]' '[:upper:]' <<<"${etype:0:1}")${etype:1}")"
    rid="$(ensure_recipe "$title" "$desc" "$url")"
    annotated="$(jq -c --argjson r "$row" --arg cat "$cat_id" --arg rid "$rid" \
      '. + [$r + {cat: $cat, rid: $rid}]' <<<"$annotated")"
  done < <(jq -c '.[]' <<<"$desired")

  # Diff by (date, category).
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
  [[ "$actions" == "[]" ]] && { log "In sync - no changes."; return 0; }

  local act a date cat summary id
  while IFS= read -r act; do
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
        local cargs=(meal create-sitting --recipe-id "$rid" --date "$date" --meal-category-id "$cat")
        [[ -n "$summary" ]] && cargs+=(--summary "$summary")
        sky "${cargs[@]}" >/dev/null
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
  local t; t="$(epoch_at today "$SYNC_AT")"
  (( t > $(date +%s) )) && { echo "$t"; return; }
  epoch_at tomorrow "$SYNC_AT"
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
    log "Next sync: $(epoch_fmt "$next") (sleeping $((next-now))s)"
    sleep $(( next - now ))
  done
}
main "$@"
