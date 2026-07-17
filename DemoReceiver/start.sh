#!/bin/zsh
set -euo pipefail

demo_script_directory="${0:A:h}"
demo_host="${TWAINBRIDGE_DEMO_HOST:-127.0.0.1}"
demo_port="${TWAINBRIDGE_DEMO_PORT:-9080}"
demo_data_directory="${TWAINBRIDGE_DEMO_DATA_DIR:-${demo_script_directory}/data}"
demo_browser_host="${demo_host}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  print "Usage: DemoReceiver/start.sh"
  print ""
  print "Environment overrides:"
  print "  TWAINBRIDGE_DEMO_HOST      Bind host (default: 127.0.0.1)"
  print "  TWAINBRIDGE_DEMO_PORT      Port (default: 9080)"
  print "  TWAINBRIDGE_DEMO_DATA_DIR  Persistent library directory"
  exit 0
fi

if (( $# > 0 )); then
  print -u2 "Unknown argument: $1. Run DemoReceiver/start.sh --help for usage."
  exit 2
fi

if [[ "${demo_host}" == "127.0.0.1" || "${demo_host}" == "0.0.0.0" || "${demo_host}" == "::" || "${demo_host}" == "::1" ]]; then
  demo_browser_host="localhost"
fi

command -v python3 >/dev/null || {
  print -u2 "Python 3 is required to run the TwainBridge demo receiver."
  exit 2
}

if [[ ! "${demo_port}" =~ '^[0-9]+$' ]] || (( demo_port < 1 || demo_port > 65535 )); then
  print -u2 "TWAINBRIDGE_DEMO_PORT must be a number between 1 and 65535."
  exit 2
fi

demo_website_url="http://${demo_browser_host}:${demo_port}"
demo_upload_url="${demo_website_url}/upload"

print ""
print "TwainBridge Demo Receiver"
print "  Website:         ${demo_website_url}"
print "  Upload endpoint: ${demo_upload_url}"
print ""
print "Add the Upload endpoint above as the Destination URL in TwainBridge."
print "Press Control-C to stop the receiver."
print ""

exec python3 "${demo_script_directory}/server.py" \
  --http \
  --host "${demo_host}" \
  --port "${demo_port}" \
  --data-dir "${demo_data_directory}" \
  --public-origin "${demo_website_url}"
