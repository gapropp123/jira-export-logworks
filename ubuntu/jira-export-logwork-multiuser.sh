#!/usr/bin/env bash
set -euo pipefail

CONF=""
DOMAIN="${DOMAIN:-}"
AUTH_EMAIL="${JIRA_EMAIL:-${AUTH_EMAIL:-}}"
AUTH_TOKEN="${JIRA_API_TOKEN:-${API_TOKEN:-${AUTH_TOKEN:-}}}"
SCOPE_JQL="${SCOPE_JQL:-}"
FROM_DATE="${FROM_DATE:-}"
TO_DATE="${TO_DATE:-}"
OUT_PARENT="${OUT_PARENT:-}"
PARALLEL="${PARALLEL:-8}"
MAX_RESULTS="${MAX_RESULTS:-100}"

declare -a TARGET_USERS=()

usage() {
  cat <<'EOF'
Usage:
  ./jira-export-logwork-multiuser.sh [-c path/to/config.conf]

Config keys supported:
  DOMAIN=
  AUTH_EMAIL=auth@company.com
  AUTH_TOKEN=xxxxx        (or API_TOKEN / JIRA_API_TOKEN)
  SCOPE_JQL=project = ABC
  FROM_DATE=YYYY-MM-DD
  TO_DATE=YYYY-MM-DD
  OUT_PARENT=/path/to/output_parent
  PARALLEL=8
  MAX_RESULTS=100
  USERS=a@x.com;b@y.com   (or comma)
  USER=a@x.com            (repeatable)

Outputs:
  <OUT_PARENT>/<user>/summary.csv
  <OUT_PARENT>/<user>/detail.csv

Dependencies:
  bash, curl, jq, awk
EOF
}

need_cmd(){ command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

sanitize_folder() {
  local s="$1"
  s="${s//\\/ _}"
  s="${s//\//_}"
  s="${s//:/_}"
  s="${s//\*/_}"
  s="${s//\?/_}"
  s="${s//\"/_}"
  s="${s//</_}"
  s="${s//>/_}"
  s="${s//|/_}"
  s="${s//@/_}"
  s="${s//./_}"
  printf '%s' "$s"
}

csv_quote() {
  local s="${1//$'\r'/}"
  s="${s//$'\n'/\\n}"
  s="${s//\"/\"\"}"
  printf '"%s"' "$s"
}

uri_encode() { jq -rn --arg v "$1" '$v|@uri'; }

api_get() {
  local url="$1"
  local attempt=0
  while true; do
    attempt=$((attempt+1))
    local http_and_body http_code body
    http_and_body="$(curl -sS -u "${AUTH_EMAIL}:${AUTH_TOKEN}" -H "Accept: application/json" -w $'\n%{http_code}' "$url" || true)"
    http_code="$(tail -n1 <<<"$http_and_body")"
    body="$(sed '$d' <<<"$http_and_body")"

    if [[ "$http_code" == "200" ]]; then echo "$body"; return 0; fi
    if [[ "$http_code" == "429" || "$http_code" =~ ^5 ]]; then
      (( attempt >= 6 )) && { echo "GET failed HTTP $http_code: $body" >&2; exit 1; }
      sleep $((attempt * 2))
      continue
    fi
    echo "GET failed HTTP $http_code: $body" >&2
    exit 1
  done
}

api_post() {
  local url="$1"
  local json="$2"
  local attempt=0
  while true; do
    attempt=$((attempt+1))
    local http_and_body http_code body
    http_and_body="$(curl -sS -u "${AUTH_EMAIL}:${AUTH_TOKEN}" -H "Accept: application/json" -H "Content-Type: application/json" \
      -d "$json" -w $'\n%{http_code}' "$url" || true)"
    http_code="$(tail -n1 <<<"$http_and_body")"
    body="$(sed '$d' <<<"$http_and_body")"

    if [[ "$http_code" == "200" ]]; then echo "$body"; return 0; fi
    if [[ "$http_code" == "429" || "$http_code" =~ ^5 ]]; then
      (( attempt >= 6 )) && { echo "POST failed HTTP $http_code: $body" >&2; exit 1; }
      sleep $((attempt * 2))
      continue
    fi
    echo "POST failed HTTP $http_code: $body" >&2
    exit 1
  done
}

load_conf() {
  local conf="$1"
  [[ -f "$conf" ]] || { echo "ERROR: config not found: $conf" >&2; exit 1; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    if [[ "$line" == *" #"* ]]; then line="${line%%\ #*}"; fi
    if [[ "$line" == *$'\t#'* ]]; then line="${line%%$'\t#'*}"; fi
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue

    local key="${line%%=*}"
    local val="${line#*=}"
    key="$(trim "$key")"
    val="$(trim "$val")"
    local ukey="${key^^}"

    case "$ukey" in
      DOMAIN) [[ -z "$DOMAIN" ]] && DOMAIN="$val" ;;
      AUTH_EMAIL|JIRA_EMAIL) [[ -z "$AUTH_EMAIL" ]] && AUTH_EMAIL="$val" ;;
      AUTH_TOKEN|API_TOKEN|JIRA_API_TOKEN) [[ -z "$AUTH_TOKEN" ]] && AUTH_TOKEN="$val" ;;
      SCOPE_JQL) [[ -z "$SCOPE_JQL" ]] && SCOPE_JQL="$val" ;;
      FROM|FROM_DATE) [[ -z "$FROM_DATE" ]] && FROM_DATE="$val" ;;
      TO|TO_DATE) [[ -z "$TO_DATE" ]] && TO_DATE="$val" ;;
      OUT_PARENT|OUTDIR) [[ -z "$OUT_PARENT" ]] && OUT_PARENT="$val" ;;
      PARALLEL) PARALLEL="$val" ;;
      MAX_RESULTS) MAX_RESULTS="$val" ;;
      USERS)
        local IFS=';,'
        read -ra arr <<<"$val"
        for u in "${arr[@]}"; do
          u="$(trim "$u")"
          [[ -n "$u" ]] && TARGET_USERS+=("$u")
        done
        ;;
      USER)
        [[ -n "$val" ]] && TARGET_USERS+=("$val")
        ;;
      *)
        ;;
    esac
  done < "$conf"
}

validate() {
  [[ -n "$DOMAIN" ]] || { echo "ERROR: DOMAIN missing" >&2; exit 1; }
  [[ -n "$AUTH_EMAIL" ]] || { echo "ERROR: AUTH_EMAIL/JIRA_EMAIL missing" >&2; exit 1; }
  [[ -n "$AUTH_TOKEN" ]] || { echo "ERROR: AUTH_TOKEN/API_TOKEN/JIRA_API_TOKEN missing" >&2; exit 1; }
  ((${#TARGET_USERS[@]} > 0)) || { echo "ERROR: no target users. Set USERS=... or USER=... in conf" >&2; exit 1; }

  if [[ -n "$FROM_DATE" && ! "$FROM_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: FROM_DATE must be YYYY-MM-DD" >&2; exit 1
  fi
  if [[ -n "$TO_DATE" && ! "$TO_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: TO_DATE must be YYYY-MM-DD" >&2; exit 1
  fi
  if [[ -n "$FROM_DATE" && -n "$TO_DATE" && "$FROM_DATE" > "$TO_DATE" ]]; then
    echo "ERROR: FROM_DATE must be <= TO_DATE" >&2; exit 1
  fi
}

resolve_account_id_by_email() {
  local user_email="$1"
  local enc url resp
  enc="$(uri_encode "$user_email")"
  url="https://${DOMAIN}/rest/api/3/user/search?query=${enc}&maxResults=50"
  resp="$(api_get "$url")"

  local exact
  exact="$(jq -r --arg em "$user_email" '
    map(select(.emailAddress? == $em)) | .[0].accountId // empty
  ' <<<"$resp")"

  if [[ -n "$exact" ]]; then
    echo "$exact"
    return 0
  fi

  local count
  count="$(jq 'length' <<<"$resp")"
  if [[ "$count" -eq 1 ]]; then
    jq -r '.[0].accountId' <<<"$resp"
    return 0
  fi

  echo "WARN: Cannot resolve accountId for '$user_email' (email hidden / multiple matches)." >&2
  jq -r '.[] | "  - displayName=\(.displayName) accountId=\(.accountId) email=\(.emailAddress // "N/A")"' <<<"$resp" >&2
  return 1
}

build_jql() {
  local accountId="$1"
  local jql="worklogAuthor in (\"${accountId}\")"
  if [[ -n "$FROM_DATE" ]]; then
    jql="${jql} AND worklogDate >= \"${FROM_DATE}\""
  fi
  if [[ -n "$TO_DATE" ]]; then
    jql="${jql} AND worklogDate <= \"${TO_DATE}\""
  fi
  if [[ -n "$SCOPE_JQL" ]]; then
    jql="(${SCOPE_JQL}) AND (${jql})"
  fi
  echo "${jql} ORDER BY key ASC"
}

fetch_issue_key_and_summary_by_jql() {
  local jql="$1"
  local url="https://${DOMAIN}/rest/api/3/search/jql"
  local nextPageToken=""
  local isLast="false"

  while [[ "$isLast" != "true" ]]; do
    local body resp
    if [[ -n "$nextPageToken" ]]; then
      body="$(jq -nc --arg jql "$jql" --arg npt "$nextPageToken" --argjson mr "$MAX_RESULTS" \
        '{jql:$jql, fields:["key","summary"], maxResults:$mr, nextPageToken:$npt}')"
    else
      body="$(jq -nc --arg jql "$jql" --argjson mr "$MAX_RESULTS" \
        '{jql:$jql, fields:["key","summary"], maxResults:$mr}')"
    fi

    resp="$(api_post "$url" "$body")"

    jq -r '
      .issues[]
      | [
          .key,
          ((.fields.summary // "")
            | gsub("\t";" ")
            | gsub("\r";" ")
            | gsub("\n";" "))
        ]
      | @tsv
    ' <<<"$resp"

    isLast="$(jq -r '.isLast // "true"' <<<"$resp")"
    nextPageToken="$(jq -r '.nextPageToken // ""' <<<"$resp")"

    [[ "$isLast" != "true" && -z "$nextPageToken" ]] && break
  done
}

fetch_worklogs_one_issue() {
  local issue="$1"
  local accountId="$2"
  local issue_summary="$3"
  local tmpdir="$4"

  local detail_file="${tmpdir}/detail_${issue}.csv"
  local summary_file="${tmpdir}/summary_${issue}.csv"
  : > "$detail_file"
  : > "$summary_file"

  local startAt=0
  local total=0

  while true; do
    local url="https://${DOMAIN}/rest/api/3/issue/${issue}/worklog?startAt=${startAt}&maxResults=${MAX_RESULTS}"
    local resp
    resp="$(api_get "$url")"

    local tsv
    tsv="$(jq -r --arg aid "$accountId" --arg from "$FROM_DATE" --arg to "$TO_DATE" '
      .worklogs[]
      | select(.author.accountId == $aid)
      | select(
          ($from == "" or (.started[0:10] >= $from)) and
          ($to == "" or (.started[0:10] <= $to))
        )
      | [
          (.id|tostring),
          (.author.displayName // ""),
          (.author.accountId // ""),
          (.started // ""),
          ((.timeSpentSeconds // 0)|tostring),
          (.created // ""),
          (.updated // "")
        ]
      | @tsv
    ' <<<"$resp")"

    if [[ -n "$tsv" ]]; then
      while IFS=$'\t' read -r wid author aid started secs hours created updated; do
        total=$(( total + secs ))
        hours="$(awk -v s="$secs" 'BEGIN { printf "%.4f", (s/3600) }')"
        {
          csv_quote "$issue"; printf ','
          csv_quote "$issue_summary"; printf ','
          csv_quote "$wid"; printf ','
          csv_quote "$author"; printf ','
          csv_quote "$aid"; printf ','
          csv_quote "$started"; printf ','
          csv_quote "$secs"; printf ','
          csv_quote "$hours"; printf ','
          csv_quote "$created"; printf ','
          csv_quote "$updated"
          printf '\n'
        } >> "$detail_file"
      done <<<"$tsv"
    fi

    local page_count
    page_count="$(jq '.worklogs | length' <<<"$resp")"
    [[ "$page_count" -lt "$MAX_RESULTS" ]] && break
    startAt=$((startAt + MAX_RESULTS))
  done

  local hours
  hours="$(awk -v s="$total" 'BEGIN { printf "%.4f", (s/3600) }')"
  {
    csv_quote "$issue"; printf ','
    csv_quote "$issue_summary"; printf ','
    csv_quote "$total"; printf ','
    csv_quote "$hours"
    printf '\n'
  } >> "$summary_file"
}

run_for_user() {
  local user_email="$1"
  local accountId

  echo ""
  echo "=== User: $user_email ==="

  if ! accountId="$(resolve_account_id_by_email "$user_email")"; then
    echo "SKIP user (cannot resolve accountId): $user_email" >&2
    return 0
  fi
  echo "accountId: $accountId"

  local jql
  jql="$(build_jql "$accountId")"
  echo "JQL: $jql"

  local safe_user
  safe_user="$(sanitize_folder "$user_email")"

  local user_dir="${OUT_PARENT}/${safe_user}"
  mkdir -p "$user_dir"
  local tmpdir="${user_dir}/tmp"
  mkdir -p "$tmpdir"

  local SUMMARY="${user_dir}/summary.csv"
  local DETAIL="${user_dir}/detail.csv"
  echo "IssueKey,IssueSummary,TotalSeconds,TotalHours" > "$SUMMARY"
  echo "IssueKey,IssueSummary,WorklogId,Author,AccountId,Started,TimeSpentSeconds,TimeSpentHours,Created,Updated" > "$DETAIL"

  mapfile -t issue_lines < <(fetch_issue_key_and_summary_by_jql "$jql")
  echo "Found ${#issue_lines[@]} issues"

  local -a pids=()
  local running=0

  for line in "${issue_lines[@]}"; do
    IFS=$'\t' read -r issue isummary <<<"$line"

    fetch_worklogs_one_issue "$issue" "$accountId" "$isummary" "$tmpdir" &
    pids+=("$!")
    running=$((running+1))

    if (( running >= PARALLEL )); then
      # wait oldest
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
      running=$((running-1))
    fi
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  cat "$tmpdir"/summary_*.csv >> "$SUMMARY" 2>/dev/null || true
  cat "$tmpdir"/detail_*.csv  >> "$DETAIL" 2>/dev/null || true
  local grand_secs grand_hours
  grand_secs="$(awk '
    NR==1 { next }                          # skip header
    $0 ~ /^"TOTAL"/ { next }                # avoid double-count if re-run / merged
    match($0, /,"([0-9]+)","([0-9.]+)"$/, m) { s += m[1] }
    END { printf "%.0f", (s+0) }
  ' "$SUMMARY")"

  grand_hours="$(awk -v s="$grand_secs" 'BEGIN { printf "%.4f", (s/3600) }')"

  {
    csv_quote "TOTAL"; printf ','
    csv_quote "Grand total"; printf ','
    csv_quote "$grand_secs"; printf ','
    csv_quote "$grand_hours"
    printf '\n'
  } >> "$SUMMARY"

  local detail_secs detail_hours
  detail_secs="$(awk '
    NR==1 { next }
    $0 ~ /^"TOTAL"/ { next }
    match($0, /,"([0-9]+)","([0-9.]+)","[^"]*","[^"]*"$/, m) { s += m[1] }
    END { printf "%.0f", (s+0) }
  ' "$DETAIL")"
  detail_hours="$(awk -v s="$detail_secs" 'BEGIN { printf "%.4f", (s/3600) }')"

  {
    csv_quote "TOTAL"; printf ','
    csv_quote "Grand total"; printf ','
    csv_quote ""; printf ','      # WorklogId
    csv_quote ""; printf ','      # Author
    csv_quote ""; printf ','      # AccountId
    csv_quote ""; printf ','      # Started
    csv_quote "$detail_secs"; printf ','
    csv_quote "$detail_hours"; printf ','
    csv_quote ""; printf ','      # Created
    csv_quote ""                  # Updated
    printf '\n'
  } >> "$DETAIL"
  echo "Done -> $user_dir"
}

main() {
  need_cmd curl
  need_cmd jq
  need_cmd awk

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--conf) CONF="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *) echo "Unknown arg: $1" >&2; usage; exit 1;;
    esac
  done

  if [[ -z "$CONF" ]]; then
    CONF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jira-export-logwork.conf"
  fi

  load_conf "$CONF"
  validate

  if [[ -z "$OUT_PARENT" ]]; then
    OUT_PARENT="./jira_worklogs_export_$(date +%Y%m%d_%H%M%S)"
  fi
  mkdir -p "$OUT_PARENT"

  echo "Output parent: $OUT_PARENT"
  echo "Parallel: $PARALLEL | MaxResults: $MAX_RESULTS"
  echo "Targets: ${#TARGET_USERS[@]} users"

  TARGET_USERS=($(printf "%s\n" "${TARGET_USERS[@]}" | awk '!seen[$0]++'))

  for u in "${TARGET_USERS[@]}"; do
    run_for_user "$u"
  done

  echo ""
  echo "ALL DONE: $OUT_PARENT"
}

main "$@"
