#!/bin/sh
# Runs the pgTAP tests on the linked project without Docker (`supabase test db` needs Docker for
# pg_prove). `supabase db query` only returns the last result, so each TAP line is collected into a
# temp table and printed at the end. The tests roll themselves back.
# Usage: supabase/tests/run-linked.sh [test file ...]
set -eu
cd "$(dirname "$0")/../.."
[ $# -gt 0 ] || set -- supabase/tests/database/*.test.sql
status=0
tmp=$(mktemp "${TMPDIR:-/tmp}/strewn-tap.XXXXXX")
trap 'rm -f "$tmp"' EXIT
for f in "$@"; do
  perl -0pe '
    s/^select plan\((\d+)\);/create temp table tap_out (n serial, line text);\ngrant insert on tap_out to authenticated, anon;\ngrant usage on sequence tap_out_n_seq to authenticated, anon;\ninsert into tap_out (line) select plan($1);/m;
    s/\bselect (is|isnt|ok|throws_ok|lives_ok|results_eq)\(/insert into tap_out (line) select $1(/g;
    s/^select \* from finish\(\);/reset role;\ninsert into tap_out (line) select * from finish();\nselect string_agg(line, chr(10) order by n) as tap from tap_out;/m;
  ' "$f" > "$tmp"
  echo "# $f"
  out=$(supabase db query --linked -o json --file "$tmp" 2>&1 | grep -v -e '^Initialising' -e '^A new version of Supabase CLI' -e '^We recommend updating' || true)
  tap=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["tap"])' 2>/dev/null) || { echo "$out"; status=1; continue; }
  echo "$tap"
  if printf '%s\n' "$tap" | grep -q -e '^not ok' -e 'Looks like'; then status=1; fi
done
exit $status
