#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
test_directory="$(mktemp -d -t twainbridge-receiver.XXXXXX)"
server_log="${test_directory}/server.log"
response_file="${test_directory}/response.json"
fixture_file="${test_directory}/fixture.pdf"
server_pid=""

cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill -TERM "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${test_directory}"
}
trap cleanup EXIT INT TERM

command -v curl >/dev/null || {
  print -u2 "curl is required for the reference receiver smoke test."
  exit 2
}
command -v jq >/dev/null || {
  print -u2 "jq is required for the reference receiver smoke test."
  exit 2
}

print -n '%PDF-1.4 TwainBridge receiver fixture' >"${fixture_file}"
python3 "${project_directory}/ReferenceReceiver/server.py" --http --port 0 >"${server_log}" 2>&1 &
server_pid=$!

for _ in {1..50}; do
  if rg -q 'Listening on http://127\.0\.0\.1:[0-9]+' "${server_log}"; then
    break
  fi
  if ! kill -0 "${server_pid}" 2>/dev/null; then
    print -u2 "Reference receiver exited before becoming ready."
    sed -n '1,80p' "${server_log}" >&2
    exit 3
  fi
  sleep 0.1
done

port="$(sed -nE 's/.*127\.0\.0\.1:([0-9]+).*/\1/p' "${server_log}" | head -1)"
[[ -n "${port}" ]] || {
  print -u2 "Reference receiver did not report a listening port."
  exit 3
}
base_url="http://127.0.0.1:${port}"

curl --silent --show-error "${base_url}/health" | jq -e '.success == true' >/dev/null

http_status="$(curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
  --form-string 'document_id=document-success' \
  --form-string 'batch_id=batch-success' \
  --form "file=@${fixture_file};type=application/pdf" \
  "${base_url}/upload?mode=success")"
[[ "${http_status}" == 200 ]]
jq -e '.success == true and .documents[0].document_id == "document-success"' "${response_file}" >/dev/null

for expected_status in 503 503 200; do
  http_status="$(curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
    --header 'Idempotency-Key: retry-operation' \
    --form-string 'document_id=document-retry' \
    --form "file=@${fixture_file};type=application/pdf" \
    "${base_url}/upload?mode=retry&failures=2&retry_after=0")"
  [[ "${http_status}" == "${expected_status}" ]]
done
jq -e '.success == true' "${response_file}" >/dev/null

http_status="$(curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
  --header 'Idempotency-Key: partial-operation' \
  --form-string 'batch_id=batch-partial' \
  --form-string 'manifest={"documents":[{"document_id":"document-a"},{"document_id":"document-b"}]}' \
  --form "files[]=@${fixture_file};type=application/pdf" \
  "${base_url}/upload?mode=partial")"
[[ "${http_status}" == 200 ]]
jq -e '.success == true and (.documents | length) == 2 and .documents[0].success == true and .documents[1].success == false' "${response_file}" >/dev/null

http_status="$(curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
  --header 'Idempotency-Key: malformed-operation' \
  --form-string 'document_id=document-malformed' \
  --form "file=@${fixture_file};type=application/pdf" \
  "${base_url}/upload?mode=malformed")"
[[ "${http_status}" == 200 && "$(<"${response_file}")" == '{not-json' ]]

http_status="$(curl --silent --show-error --output "${response_file}" --write-out '%{http_code}' \
  --header 'Idempotency-Key: rejection-operation' \
  --form-string 'document_id=document-rejected' \
  --form "file=@${fixture_file};type=application/pdf" \
  "${base_url}/upload?mode=reject")"
[[ "${http_status}" == 422 ]]
jq -e '.success == false' "${response_file}" >/dev/null

curl --silent --show-error "${base_url}/state" | jq -e '
  (.operations | length) == 3
  and any(.operations[]; .idempotency_key == "retry-operation" and .attempts == 3)
  and all(.operations[]; all(.files[]; (.sha256 | length) == 64))
' >/dev/null

print "Reference receiver smoke test passed: health, success, idempotent retry, partial result, malformed response, rejection, and metadata-only state."
