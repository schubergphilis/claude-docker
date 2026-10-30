#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# harness.sh — the --egress-allowlist squid rules against the real squid
# (openspec change egress-allowlist, tasks 0.1-0.4, 0.6, 0.7 and 2.3).
#
#   1. `squid -k parse` on every config tests/bats/run.bats wrote to
#      generated/ (save_for_harness), which must be exactly the set in
#      expected-configs.txt and parse without a WARNING or ERROR. Run the bats
#      suite first.
#   2. The negative group in generated-negative/: endpoint hosts starting with
#      `-` fail closed (a parse error, or an empty ACL that never matches).
#   3. Table-driven requests through squid, run from the proxy image with a
#      dnsmasq stub resolver that answers fixed addresses and logs every
#      query. "allowed" means squid didn't answer 403 (a refused or timed-out
#      connect to the fixed address is still an allow); "refused" means 403
#      and TCP_DENIED. Names off the list must never reach the resolver: a
#      positive control (a listed name must be logged) and a barrier (a last
#      listed lookup that must be logged before the log is read) keep those
#      checks from passing vacuously.
#
# Usage: bash tests/egress-proxy/harness.sh   (docker on PATH)
# Env: CLAUDE_DOCKER_EGRESS_PROXY_IMAGE to use a prebuilt squid image.
# Globals set here are read by the sourced run.sh functions (SC2034).
# shellcheck disable=SC2034

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SUBNET=10.231.0
DNS_IP=$SUBNET.2
SQUID_IP=$SUBNET.3
ID="egress-harness-$$"
NET="$ID-net"
FAILS=0

log() { echo "[egress-harness] $*"; }
fail() { echo "[egress-harness] FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
die() { echo "[egress-harness] FAIL: $*" >&2; exit 1; }

cleanup() {
  docker rm -f "$ID-dns" "$ID-squid" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

# The squid image run.sh uses, built by run.sh's own code if missing.
setup_images() {
  WORK=$(mktemp -d)
  trap cleanup EXIT
  # shellcheck source=../../run.sh
  source "$REPO/run.sh"
  set -euo pipefail
  RUNTIME=docker stage="$WORK"
  ensure_egress_image
  SQUID_IMAGE="$EGRESS_IMAGE"
  HELPER_IMAGE="claude-docker-egress-harness:$(printf '%s' "$EGRESS_PROXY_BASE" | cksum | cut -d' ' -f1)"
  if ! docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
    mkdir -p "$WORK/helper"
    printf 'FROM %s\nRUN apk add --no-cache dnsmasq\n' "$EGRESS_PROXY_BASE" >"$WORK/helper/Containerfile"
    docker build -q -t "$HELPER_IMAGE" -f "$WORK/helper/Containerfile" "$WORK/helper" >/dev/null
  fi
}

# squid -k parse output for config $1.
squid_parse() {
  docker run --rm --user squid -v "$1:/etc/squid/squid.conf:ro" \
    --entrypoint /usr/sbin/squid "$SQUID_IMAGE" -k parse -f /etc/squid/squid.conf 2>&1
}

# 1. Every config the bats suite wrote parses cleanly. `via off` is
# deliberate (the proxy doesn't announce itself) and squid warns about it on
# every config, plain --egress-lock's included; that one warning is allowed.
check_generated() {
  local dir="$HERE/generated" f out want have
  want=$(sed -e '/^#/d' -e '/^$/d' "$HERE/expected-configs.txt" | sort)
  have=$(cd "$dir" 2>/dev/null && ls -1 -- *.conf 2>/dev/null | sort) || true
  [ -n "$have" ] || die "no configs in $dir: run bats tests/bats/run.bats first"
  [ "$want" = "$have" ] || die "configs in $dir differ from expected-configs.txt:
$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$have") || true)"
  for f in $have; do
    out=$(squid_parse "$dir/$f") || { fail "squid -k parse $f exited non-zero: $out"; continue; }
    out=$(grep -v 'WARNING: HTTP requires the use of Via' <<<"$out") || true
    if grep -qE 'WARNING|ERROR' <<<"$out"; then
      fail "squid -k parse $f: $(grep -E 'WARNING|ERROR' <<<"$out" | head -3)"
    else
      log "PASS: $f parses cleanly"
    fi
  done
}

# 2. Endpoint hosts that squid reads as ACL options fail closed.
check_negative() {
  local dir="$HERE/generated-negative" h out rc
  for h in -gw.example.eu --gw.example.eu; do
    rc=0
    out=$(squid_parse "$dir/endpoint$h.conf") || rc=$?
    if [ "$rc" != "0" ] || grep -q ERROR <<<"$out"; then
      log "PASS: endpoint '$h' makes squid -k parse fail"
    else
      fail "endpoint '$h' parsed without an error: $out"
    fi
  done
  for h in -n --; do
    out=$(squid_parse "$dir/endpoint$h.conf") || true
    if grep -qi 'empty ACL' <<<"$out"; then
      log "PASS: endpoint '$h' leaves an empty ACL"
    else
      fail "endpoint '$h' did not warn about an empty ACL: $out"
    fi
  done
}

# 0.1: squid does warn about overlapping dstdomain values, which is why
# run.sh deduplicates them.
check_overlap_warns() {
  local out
  printf 'http_port 3128\npid_filename none\nacl t dstdomain -n .example.com api.example.com\nhttp_access deny t\n' >"$WORK/overlap.conf"
  out=$(squid_parse "$WORK/overlap.conf") || true
  if grep -q WARNING <<<"$out"; then
    log "PASS: 0.1 squid warns about overlapping dstdomain values"
  else
    fail "0.1 squid did not warn about .example.com next to api.example.com: $out"
  fi
}

start_network() {
  docker network create --internal --subnet "$SUBNET.0/24" "$NET" >/dev/null
  # Fixed answers; everything else gets no answer but is still logged.
  docker run -d --name "$ID-dns" --network "$NET" --ip "$DNS_IP" --entrypoint dnsmasq "$HELPER_IMAGE" \
    -k --no-resolv --no-hosts --log-queries --log-facility=- --user=root \
    --host-record=example.com,"$DNS_IP" --host-record=corp.example,"$DNS_IP" \
    --host-record=git.corp.example,10.20.1.2 --host-record=gitlab.corp.example,"$DNS_IP" \
    --host-record=x.internal.example,"$DNS_IP" --host-record=gw.example.eu,"$DNS_IP" \
    --host-record=claude-docker-api-proxy,"$DNS_IP" --host-record=meta.example,169.254.169.254 \
    --host-record=x.example,169.254.169.254 --host-record=y.example,127.0.0.1 \
    --host-record=barrier.example.net,"$DNS_IP" --host-record=control.example.net,"$DNS_IP" \
    --host-record=app.terraform.io,"$DNS_IP" --host-record=github.com,"$DNS_IP" >/dev/null
}

# Start squid with config $1 (plus the harness's resolver and a short
# connect timeout) and wait until it accepts connections.
start_squid() {
  local i=0
  docker rm -f "$ID-squid" >/dev/null 2>&1 || true
  cp "$1" "$WORK/run.conf"
  printf 'dns_nameservers %s\nconnect_timeout 2 seconds\n' "$DNS_IP" >>"$WORK/run.conf"
  docker run -d --name "$ID-squid" --network "$NET" --ip "$SQUID_IP" --user squid --cap-drop ALL \
    -v "$WORK/run.conf:/etc/squid/squid.conf:ro" --entrypoint /usr/sbin/squid "$SQUID_IMAGE" -N >/dev/null
  while [ "$i" -lt 30 ]; do
    docker logs "$ID-squid" 2>&1 | grep -q 'Accepting HTTP Socket connections' && return 0
    sleep 1
    i=$((i + 1))
  done
  docker logs "$ID-squid" 2>&1 | tail -20 >&2
  die "squid did not start with $1"
}

# A config from run.sh's own generator: $1 the endpoint URL, $2 the
# allowlist file's content; API and --glab sidecars as in a real session.
gen_conf() {
  printf '%s' "$2" >"$WORK/team.allow"
  (
    WITH_API=1 WITH_EGRESS_LOCK=1 WITH_EGRESS_ALLOWLIST=1 ANTHROPIC_AUTH_TOKEN=t
    ANTHROPIC_BASE_URL="$1" EGRESS_ALLOWLIST_ARG="$WORK/team.allow" WORKSPACES=("$WORK/ws")
    mkdir -p "$WORK/ws"
    validate_opts
    API_SIDECAR_ACTIVE=1 GLAB_SIDECAR_ACTIVE=1 GLAB_PROXY_HOST=gitlab.corp.example:8443
    gen_egress_squid_conf
  ) >"$WORK/gen.conf"
  printf '%s' "$WORK/gen.conf"
}

# Send the requests in table $1 (lines: expect<TAB>raw request, \r\n
# escapes as printf understands them; expect is allowed, refused or
# blocked) through squid from one client
# container, and compare each answer's status with expect.
run_table() {
  local table="$1" expect req code n=0
  : >"$WORK/requests"
  while IFS=$'\t' read -r expect req; do
    [ -n "$expect" ] || continue
    printf '%s\n' "$req" >>"$WORK/requests"
  done <"$table"
  # One status line per request; nc -w bounds a tunnel that stays open. The
  # sleep keeps the client's side open: squid abandons a request whose
  # client half-closed while its DNS lookup was still pending.
  docker run --rm --network "$NET" -v "$WORK/requests:/requests:ro" --entrypoint sh "$HELPER_IMAGE" -c '
    while IFS= read -r r; do
      s=$({ printf "$r"; sleep 2; } | nc -w 4 '"$SQUID_IP"' 3128 2>/dev/null | head -1 | cut -d" " -f2)
      echo "${s:-none}"
    done </requests' >"$WORK/codes"
  while IFS=$'\t' read -r expect req; do
    [ -n "$expect" ] || continue
    n=$((n + 1))
    code=$(sed -n "${n}p" "$WORK/codes")
    case "$expect:$code" in
      # blocked: a malformed request may get 400 rather than 403.
      refused:403 | blocked:4* | allowed:[!4]* | allowed:none) log "PASS: $expect ($code): $req" ;;
      *) fail "expected $expect, got $code: $req" ;;
    esac
  done <"$table"
}

connect() { printf 'CONNECT %s HTTP/1.1\\r\\nHost: %s\\r\\n\\r\\n' "$1" "$1"; }
get() { printf 'GET http://%s/ HTTP/1.1\\r\\nHost: %s\\r\\n\\r\\n' "$1" "$1"; }

# The resolver's log of the query names it saw.
dns_queries() { docker logs "$ID-dns" 2>&1 | sed -n 's/.*query\[[A-Z]*\] \([^ ]*\) from.*/\1/p'; }

# The listed name $1 was looked up: wait for it (the barrier), or fail.
await_query() {
  local i=0
  while [ "$i" -lt 10 ]; do
    dns_queries | grep -qxF "$1" && return 0
    sleep 1
    i=$((i + 1))
  done
  fail "no DNS query for the listed name $1"
  return 1
}

# 3. The main allowlist session: endpoint on 8443, --api and --glab sidecars.
check_allowlist() {
  local t="$WORK/table" conf q
  conf=$(gen_conf https://gw.example.eu:8443 'example.com
git.corp.example:8443
.corp.example
.internal.example:8443
meta.example
localhost:8080
x.example:8443
y.example:8443
.example.net
')
  start_squid "$conf"
  {
    printf 'allowed\t%s\n' "$(connect control.example.net:443)"
    printf 'allowed\t%s\n' "$(connect example.com:443)"
    printf 'allowed\t%s\n' "$(connect Example.COM:443)"
    printf 'refused\t%s\n' "$(connect example.org:443)"
    printf 'refused\t%s\n' "$(get example.org)"
    printf 'refused\t%s\n' "$(connect example.com:8443)"
    printf 'allowed\t%s\n' "$(connect gw.example.eu:8443)"
    printf 'refused\t%s\n' "$(connect gw.example.eu:9443)"
    printf 'allowed\t%s\n' "$(get claude-docker-api-proxy:8080)"
    printf 'refused\t%s\n' "$(get claude-docker-api-proxy:9999)"
    printf 'allowed\t%s\n' "$(connect gitlab.corp.example:8443)"
    printf 'refused\t%s\n' "$(connect gitlab.corp.example:9443)"
    printf 'allowed\t%s\n' "$(connect git.corp.example:8443)"
    printf 'allowed\t%s\n' "$(connect git.corp.example:443)"
    printf 'refused\t%s\n' "$(connect git.corp.example:9443)"
    printf 'allowed\t%s\n' "$(connect corp.example:443)"
    printf 'allowed\t%s\n' "$(connect x.internal.example:8443)"
    printf 'refused\t%s\n' "$(connect x.internal.example:9443)"
    printf 'refused\t%s\n' "$(connect API.Anthropic.com:443)"
    printf 'refused\t%s\n' "$(connect api.anthropic.com.:443)"
    printf 'refused\t%s\n' "$(get meta.example)"
    printf 'refused\t%s\n' "$(get localhost:8080)"
    printf 'refused\t%s\n' "$(connect x.example:8443)"
    printf 'refused\t%s\n' "$(connect y.example:8443)"
    # IP literals, shorthand IPv4 included (0.4), and names off the list.
    printf 'refused\t%s\n' "$(get 10.0.0.5)"
    printf 'refused\t%s\n' "$(get 2130706433)"
    printf 'refused\t%s\n' "$(get 167772165)"
    printf 'refused\t%s\n' "$(get 10.5)"
    printf 'refused\t%s\n' "$(get 0x7f000001)"
    printf 'refused\t%s\n' "$(get '[2001:db8::1]')"
    printf 'refused\t%s\n' "$(connect secret.attacker.example:443)"
    printf 'refused\t%s\n' "$(get SECRET.attacker.example)"
    printf 'refused\t%s\n' "$(get secret.attacker.example:8080)"
    printf 'refused\t%s\n' "$(connect secret.attacker.example:8443)"
    printf 'refused\t%s\n' "$(connect 1.2.3.4.secret.attacker.example:443)"
    printf 'refused\t%s\n' "$(get unlisted8080.attacker.example:8080)"
    # The barrier: a listed name, last.
    printf 'allowed\t%s\n' "$(connect barrier.example.net:443)"
  } >"$t"
  run_table "$t"
  await_query control.example.net && log "PASS: positive control: a listed name is resolved"
  await_query barrier.example.net
  q=$(dns_queries)
  if grep -qiE 'attacker|arpa|2130706433|167772165|^10\.5$|0x7f|anthropic' <<<"$q"; then
    fail "the resolver saw names off the list: $(grep -iE 'attacker|arpa|2130706433|167772165|^10\.5$|0x7f|anthropic' <<<"$q" | sort -u | tr '\n' ' ')"
  else
    log "PASS: no query, forward or reverse, for a name off the list"
  fi
}

# Credential flags add nothing: an empty file refuses their hosts.
check_empty_file() {
  local t="$WORK/table"
  start_squid "$(gen_conf https://gw.example.eu '')"
  {
    printf 'refused\t%s\n' "$(connect app.terraform.io:443)"
    printf 'refused\t%s\n' "$(connect github.com:443)"
    printf 'allowed\t%s\n' "$(connect gw.example.eu:443)"
  } >"$t"
  run_table "$t"
}

# 0.3: an IPv4 endpoint matches as a literal.
check_ipv4_endpoint() {
  local t="$WORK/table"
  start_squid "$(gen_conf https://10.0.0.5:8443 '')"
  {
    printf 'allowed\t%s\n' "$(connect 10.0.0.5:8443)"
    printf 'refused\t%s\n' "$(connect 10.0.0.5:9443)"
    printf 'refused\t%s\n' "$(connect 10.0.0.6:8443)"
  } >"$t"
  run_table "$t"
}

# 0.6: control bytes in a requested host never reach squid's log, which the
# end-of-session summary prints.
check_control_bytes() {
  local t="$WORK/table" bad
  start_squid "$(gen_conf https://gw.example.eu 'example.com')"
  {
    printf 'blocked\t%s\n' 'GET http://a\033[31mb.example:8080/ HTTP/1.1\r\nHost: x\r\n\r\n'
    printf 'blocked\t%s\n' 'GET http://a\037b.example/ HTTP/1.1\r\nHost: x\r\n\r\n'
    printf 'blocked\t%s\n' 'CONNECT a\033[31mb.example:443 HTTP/1.1\r\nHost: x\r\n\r\n'
    printf 'blocked\t%s\n' 'CONNECT a\037b.example:443 HTTP/1.1\r\nHost: x\r\n\r\n'
  } >"$t"
  run_table "$t"
  bad=$(docker logs "$ID-squid" 2>/dev/null | LC_ALL=C tr -d '\n\040-\377' | wc -c)
  if [ "$bad" -eq 0 ]; then
    log "PASS: 0.6 no control byte in squid's access log"
  else
    fail "0.6 squid's access log has $bad control bytes"
  fi
}

main() {
  command -v docker >/dev/null 2>&1 || die "docker is required"
  setup_images
  check_generated
  check_negative
  check_overlap_warns
  start_network
  check_allowlist
  check_empty_file
  check_ipv4_endpoint
  check_control_bytes
  [ "$FAILS" -eq 0 ] || die "$FAILS check(s) failed"
  log "ALL PASS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
