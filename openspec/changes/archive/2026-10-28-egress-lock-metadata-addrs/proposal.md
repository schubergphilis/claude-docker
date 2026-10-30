# Egress lock: deny the Alibaba Cloud and AWS IPv6 metadata addresses

## Why

Review of #101 (security-reviewer, head `73608a3`): the proxy's "metadata is always denied" rule covers `169.254.0.0/16` and the GCP and Azure metadata names, but not Alibaba Cloud's metadata address `100.100.100.200` or AWS's IPv6 IMDS address `fd00:ec2::254`. Both fall through to `http_access allow all` on port 80, so on such a host a program in a locked session could fetch instance credentials through squid. The default network reaches them without the lock too, so this is not a regression, but the requirement promises metadata is denied above every allow.

## What Changes

- The squid config gets an `egress_metadata_addrs` ACL, `dst 100.100.100.200/32 fd00:ec2::254/128`, denied right after the metadata names and before every allow.
- Only those two addresses, not their ranges: `100.64.0.0/10` (CGNAT, Tailscale) and `fd00::/8` (ULA) are private ranges, which stay reachable.
- `docs/auth.md` lists them under **Always denied**.

## Capabilities

- `api-egress-policy`: MODIFIED (the metadata and loopback requirement).

## Impact

`run.sh`, `tests/bats/run.bats`, `docs/auth.md`.
