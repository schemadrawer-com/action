#!/usr/bin/env bash
#
# Uploads the migration files of a directory to schemadrawer.com, waits for the diagram and writes
# it to a file. What the composite action's "draw" step runs; runnable by hand as well:
#
#   SQL_DIRECTORY=db/migration OUTPUT_PATH=docs/schema.svg API_BASE_URL=http://localhost/api/v1 \
#     MIGRATION_TYPE=FLYWAY DATABASE_TYPE=POSTGRESQL DATABASE_VERSION=18 \
#     REPOSITORY=me/my-project _action/scripts/draw.sh
#
# Environment:
#   SQL_DIRECTORY     directory holding the migration files; every file in it is uploaded
#   OUTPUT_PATH       where the SVG is written
#   API_BASE_URL      up to and including /api/v1 (default: https://app.schemadrawer.com/api/v1)
#   MIGRATION_TYPE    the migration tool the files are written for, e.g. FLYWAY
#   DATABASE_TYPE     the database engine, e.g. POSTGRESQL
#   DATABASE_VERSION  its version, e.g. 18
#   USER_ID           UUID of the user; derived from REPOSITORY when empty
#   TIMEOUT_SECONDS   how long to wait for the diagram (default: 300)
#   AUDIENCE          whom the token GitHub signs for this run is meant for; the server accepts
#                     tokens for its own audience only (default: schemadrawer.com)
#   REPOSITORY, RUN_ID, RUN_ATTEMPT
#                     what the ids are derived from: one repository is always the same user, and
#                     one run attempt always the same Request-Id, so a retried upload is not drawn twice
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN
#                     set by GitHub when the workflow grants `id-token: write`; where the token GitHub
#                     signs for this run - repository, workflow, commit - is fetched from
set -euo pipefail

API_BASE_URL="${API_BASE_URL:-https://app.schemadrawer.com/api/v1}"
USER_ID="${USER_ID:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
AUDIENCE="${AUDIENCE:-schemadrawer.com}"
REPOSITORY="${REPOSITORY:-local/schemadrawer}"
RUN_ID="${RUN_ID:-$(date +%s)}"
RUN_ATTEMPT="${RUN_ATTEMPT:-1}"
POLL_SECONDS=3

fail() {
  echo "::error::$1" >&2
  exit 1
}

# The API's error message from a JSON answer, or the answer itself when it is not one.
message_of() {
  jq -r '.message // .' "$1" 2>/dev/null || cat "$1"
}

uuid5() {
  python3 -c "import uuid, sys; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))" "$1"
}

# The OIDC token GitHub signs for this run, so that the server knows - not just hears - which
# repository, workflow and commit are asking. Empty outside GitHub Actions and when the workflow
# does not grant `id-token: write`.
github_actions_token() {
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    return 0
  fi
  curl -sS --fail --max-time 30 \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}" | jq -r '.value // empty'
}

# A composite action does not enforce `required` on its inputs, so the script does.
[ -n "${SQL_DIRECTORY:-}" ] || fail "SQL_DIRECTORY is not set."
[ -n "${OUTPUT_PATH:-}" ] || fail "OUTPUT_PATH is not set."
[ -n "${MIGRATION_TYPE:-}" ] || fail "MIGRATION_TYPE is not set: name the migration tool, e.g. FLYWAY."
[ -n "${DATABASE_TYPE:-}" ] || fail "DATABASE_TYPE is not set: name the database engine, e.g. POSTGRESQL."
[ -n "${DATABASE_VERSION:-}" ] || fail "DATABASE_VERSION is not set: name the engine's version, e.g. 18."
[ -d "$SQL_DIRECTORY" ] || fail "sql-directory '$SQL_DIRECTORY' does not exist."

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(cd "$SQL_DIRECTORY" && find . -type f | sed 's#^\./##' | sort)
[ "${#files[@]}" -gt 0 ] || fail "No files found in '$SQL_DIRECTORY'."

echo "Uploading ${#files[@]} file(s) from '$SQL_DIRECTORY' as a $MIGRATION_TYPE migration for $DATABASE_TYPE $DATABASE_VERSION:"
printf ' - %s\n' "${files[@]}"

# Names relative to the directory, so that nested layouts (Prisma's one directory per migration,
# say) reach the migration tool as they are.
form_args=()
for f in "${files[@]}"; do
  form_args+=(-F "files=@${SQL_DIRECTORY}/${f};filename=${f}")
done

user_id="${USER_ID:-$(uuid5 "https://github.com/${REPOSITORY}")}"
request_id=$(uuid5 "https://github.com/${REPOSITORY}/actions/runs/${RUN_ID}/attempts/${RUN_ATTEMPT}")

token=$(github_actions_token) || fail "Could not get the token GitHub signs for this run."
# Expanded with the ${array[@]+...} idiom: an empty array trips `set -u` on bash 3 (macOS).
auth_args=()
if [ -n "$token" ]; then
  auth_args=(-H "Authorization: Bearer ${token}")
  echo "The upload carries the token GitHub signed for this run of ${REPOSITORY} (audience: ${AUDIENCE})."
elif [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "::warning::The upload is not signed by GitHub: grant the workflow 'id-token: write' for the server to know which repository is asking."
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

http_code=$(curl -sS --max-time 120 \
  -o "$work_dir/job.json" -w '%{http_code}' \
  -X POST "${API_BASE_URL}/drawing" \
  -H "Request-Id: ${request_id}" \
  ${auth_args[@]+"${auth_args[@]}"} \
  -F "userId=${user_id}" \
  -F "migrationType=${MIGRATION_TYPE}" \
  -F "databaseType=${DATABASE_TYPE}" \
  -F "version=${DATABASE_VERSION}" \
  "${form_args[@]}")
[ "$http_code" = "202" ] || fail "POST /drawing returned HTTP $http_code: $(message_of "$work_dir/job.json")"

job_id=$(jq -r '.jobId' "$work_dir/job.json")
echo "Drawing queued as job $job_id"

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
failed_polls=0
while :; do
  http_code=$(curl -sS --max-time 30 -o "$work_dir/status.json" -w '%{http_code}' "${API_BASE_URL}/drawing/${job_id}")
  if [ "$http_code" = "200" ]; then
    failed_polls=0
    status=$(jq -r '.status' "$work_dir/status.json")
    case "$status" in
      SUCCESS) break ;;
      ERROR) fail "Drawing failed: $(jq -r '.errorMessage // "unknown error"' "$work_dir/status.json")" ;;
    esac
  else
    # A gateway between here and the server may answer for it now and then; a job that is gone is
    # something else.
    failed_polls=$(( failed_polls + 1 ))
    [ "$failed_polls" -lt 3 ] || fail "GET /drawing/$job_id returned HTTP $http_code: $(message_of "$work_dir/status.json")"
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "The diagram was not ready within ${TIMEOUT_SECONDS} seconds (job $job_id is ${status:-unknown})."
  sleep "$POLL_SECONDS"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"
curl -sS --max-time 60 -o "$OUTPUT_PATH" "$(jq -r '.diagramUrl' "$work_dir/status.json")"
grep -q "<svg" "$OUTPUT_PATH" || fail "The file downloaded for job $job_id is not an SVG diagram."
echo "Diagram written to $OUTPUT_PATH"
