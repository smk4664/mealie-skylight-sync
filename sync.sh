#!/usr/bin/env bash
# Mirror Mealie meal plans onto a Skylight Calendar meal board.
# Stateless: each cycle fetches both sides, diffs, applies.
# Spec: .superpowers/docs/specs/2026-10-06-mealie-skylight-sync-design.md
#
# API findings (discovered 2026-10-06 against go-skylight v0.2.6 / live API):
# - SKYLIGHT_FRAME_ID env var is BROKEN in v0.2.6; --frame-id flag works.
# - meal categories/recipes/sittings list as FLAT JSON arrays (no envelope);
#   create responses come back ARRAY-WRAPPED.
# - Recipe title lives in "summary"; category name in "label".
# - Recipes REQUIRE meal_category (422 otherwise).
# - Sittings are EITHER recipe sittings (recipe_id, summary must be blank)
#   OR text sittings (summary, no recipe). Hence: Mealie recipe entries ->
#   recipe sittings; Mealie note entries -> text sittings; Mealie "side"
#   entries -> text sittings ("Side: ...") in the Dinner category.
# - Sync identity = date|category|(R:recipe_id or N:summary). Any change is
#   delete+create; there is no update operation.
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
epoch_at() {  # today|tomorrow HH:MM -> epoch seconds
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
    id="$(sky meal create-category --name "$name" \
      | jq -r 'if type=="array" then .[0] else . end | .id // empty')" || id=""
    [[ -n "$id" && "$id" != "null" ]] || { log "ERROR: category create failed for '$name'"; return 1; }
    CATEGORIES="$(sky meal categories)"
  fi
  echo "$id"
}

# ensure_recipe TITLE DESC URL CAT_ID -> id (creates if missing; matches
# by title). Skylight REQUIRES meal_category on recipes (422 otherwise).
ensure_recipe() {
  local title="$1" desc="$2" url="$3" cat_id="$4" id
  id="$(jq -r --arg t "$title" 'map(select(.summary==$t))|.[0].id // empty' <<<"$RECIPES")"
  if [[ -z "$id" ]]; then
    if [[ -n "$EFFECTIVE_DRY" ]]; then
      log "DRY: would create recipe '$title'"; echo "DRY-RID"; return
    fi
    log "Creating Skylight recipe: $title"
    local args=(meal create-recipe --title "$title" --meal-category-id "$cat_id")
    [[ -n "$desc" ]] && args+=(--description "$desc")
    [[ -n "$url" ]] && args+=(--url "$url")
    id="$(sky "${args[@]}" \
      | jq -r 'if type=="array" then .[0] else . end | .id // empty')" || id=""
    [[ -n "$id" && "$id" != "null" ]] || { log "ERROR: recipe create failed for '$title'"; return 1; }
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

  # Desired rows. kind=recipe -> recipe sitting; kind=note -> text sitting.
  # Mealie "side" entries become "Side: ..." text sittings under Dinner.
  local desired
  desired="$(jq -c '
    [.items[]
     | if .entryType=="breakfast" or .entryType=="lunch" or .entryType=="dinner" then
         (if .recipe
          then {date, cat_name: .entryType, kind: "recipe",
                title: .recipe.name, slug: .recipe.slug,
                desc: ((.recipe.description // "")[0:180])}
          else {date, cat_name: .entryType, kind: "note",
                title: (.title // "Untitled"),
                summary: (.title // "Untitled")}
          end)
       elif .entryType=="side" then
         {date, cat_name: "dinner", kind: "note",
          title: ("Side: " + (.recipe.name // .title // "side")),
          summary: ("Side: " + (.recipe.name // .title // "side"))}
       else empty end]
  ' <<<"$mealie")"

  local skipped
  skipped="$(jq -r '[.items[] | select(.entryType=="snack" or .entryType=="drink" or .entryType=="dessert")] | length' <<<"$mealie")"
  [[ "$skipped" != "0" ]] && log "Skipping $skipped snack/drink/dessert entries (no Skylight equivalent)"

  # Resolve categories + recipes; annotate rows with cat/rid.
  local annotated="[]" row kind cat_name title cat_id rid
  while IFS= read -r row; do
    kind="$(jq -r '.kind' <<<"$row")"
    cat_name="$(jq -r '.cat_name' <<<"$row")"
    cat_id="$(ensure_category "$(tr '[:lower:]' '[:upper:]' <<<"${cat_name:0:1}")${cat_name:1}")" || return 1
    rid=""
    if [[ "$kind" == "recipe" ]]; then
      title="$(jq -r '.title' <<<"$row")"
      rid="$(ensure_recipe "$title" "$(jq -r '.desc' <<<"$row")" \
        "$MEALIE_URL/g/home/r/$(jq -r '.slug' <<<"$row")" "$cat_id")" || return 1
    fi
    annotated="$(jq -c --argjson r "$row" --arg cat "$cat_id" --arg rid "$rid" \
      '. + [$r + {cat: $cat, rid: $rid}]' <<<"$annotated")"
  done < <(jq -c '.[]' <<<"$desired")

  # Identity diff: date|cat|R:<recipe_id> or date|cat|N:<summary>.
  # No updates - a changed meal is a delete + create.
  local actions
  actions="$(jq -cn --argjson want "$annotated" --argjson have "$sittings" '
    ($want | map(. + {k: (.date + "|" + .cat + "|" +
        (if .kind=="recipe" then "R:" + .rid else "N:" + .summary end))})) as $w
    | ($have | map(. + {k: ((.date[0:10]) + "|" + .meal_category_id + "|" +
        (if (.recipe_id // "") != "" then "R:" + .recipe_id else "N:" + (.summary // "") end))})) as $h
    | ($w | map(.k)) as $wkeys
    | ($h | map(.k)) as $hkeys
    | ([ $w[] | select(.k as $k | $hkeys | index($k) | not)
        | {a:"create", kind, date, cat, rid, title, summary: (.summary // "")} ]
      + [ $h[] | select(.k as $k | $wkeys | index($k) | not)
        | {a:"delete", id, date: (.date[0:10]), title: (.summary // .recipe_id // "?")} ])
  ')"

  local n_create n_delete
  n_create="$(jq -r 'map(select(.a=="create"))|length' <<<"$actions")"
  n_delete="$(jq -r 'map(select(.a=="delete"))|length' <<<"$actions")"
  log "Diff: $n_create create, $n_delete delete"

  if (( n_delete > WINDOW_DAYS + 2 )); then
    log "ERROR: sanity brake - refusing to delete $n_delete sittings in one run"
    return 1
  fi
  [[ "$actions" == "[]" ]] && { log "In sync - no changes."; return 0; }

  local act a date cat summary id kind2
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
        kind2="$(jq -r '.kind' <<<"$act")"
        cat="$(jq -r '.cat' <<<"$act")"
        log "Create sitting: $date '$title'"
        if [[ "$kind2" == "recipe" ]]; then
          sky meal create-sitting --recipe-id "$(jq -r '.rid' <<<"$act")" \
            --date "$date" --meal-category-id "$cat" >/dev/null \
            || { log "ERROR: create sitting failed ($date '$title')"; return 1; }
        else
          # CLI marks --recipe-id required, but the API accepts text-only
          # sittings; an empty value satisfies the flag check (v0.2.6).
          summary="$(jq -r '.summary' <<<"$act")"
          sky meal create-sitting --recipe-id "" --date "$date" \
            --meal-category-id "$cat" --summary "$summary" >/dev/null \
            || { log "ERROR: create sitting failed ($date '$title')"; return 1; }
        fi
        ;;
      delete)
        id="$(jq -r '.id' <<<"$act")"
        log "Delete sitting: $date '$title'"
        sky meal delete-sitting --sitting-id "$id" --date "$date" --yes >/dev/null \
          || { log "ERROR: delete sitting failed ($date '$title')"; return 1; }
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
