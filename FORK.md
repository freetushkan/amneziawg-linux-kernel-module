# About this fork

[![compat](https://img.shields.io/endpoint?url=https://freetushkan.github.io/amneziawg-linux-kernel-module/badge/compat.json)](https://freetushkan.github.io/amneziawg-linux-kernel-module/)
[![tested on](https://img.shields.io/endpoint?url=https://freetushkan.github.io/amneziawg-linux-kernel-module/badge/kernels.json)](https://freetushkan.github.io/amneziawg-linux-kernel-module/)
[![upstream](https://img.shields.io/endpoint?url=https://freetushkan.github.io/amneziawg-linux-kernel-module/badge/upstream.json)](https://freetushkan.github.io/amneziawg-linux-kernel-module/)

**[Latest compatibility report](https://freetushkan.github.io/amneziawg-linux-kernel-module/)**: every client generation against every scenario, per kernel, with history.

This is [AmneziaWG kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
(AmneziaWG 3.x) with **per-peer backward compatibility**: a server configured for
the newest protocol keeps serving clients running AmneziaWG 2.x, 1.x and vanilla
WireGuard, each in its own format, on the same interface. Peers that speak the
full protocol are handled exactly as upstream does.

The changes live in their own files
(`src/awg_fallback.[ch]`) plus a few small hooks, so the fork follows upstream
with few conflicts.

- [Compatibility](#compatibility)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Installation and updates](#installation-and-updates)
- [Testing](#testing)
- [Other changes](#other-changes)
- [Limitations](#limitations)

## Compatibility

With the server configured as AmneziaWG 3.x (header protection, random
trailers, content padding, S1-S4, H1-H4 ranges):

| Client | Works | What the server sends it |
|---|---|---|
| AmneziaWG 3.x | ✅ | full protocol |
| AmneziaWG 3.x without HeaderProtectionKey | ✅ | no header protection |
| AmneziaWG 2.x | ✅ | ranged headers, S1-S4, no 3.x features |
| AmneziaWG 2.x without S3/S4 | ✅ | ranged headers, S1/S2 |
| AmneziaWG 1.x / 1.5 | ✅ | fixed headers, S1/S2 |
| WireGuard | ✅ | plain WireGuard |

No client changes are needed. The server works out each peer's format by itself.

## Configuration

The server is configured for the newest protocol as usual. Clients only need to
share the parameters their version knows about:

| Client | Must match the server |
|---|---|
| 3.x | everything, including `HeaderProtectionKey` (or leave it out) |
| 2.x | `S1`, `S2`, `S3`, `S4` (or `S3`/`S4` = 0) and the **same** `H1`-`H4` ranges |
| 1.x / 1.5 | `S1`, `S2`; `H1`-`H4` = the **low bound** of the server's ranges |
| WireGuard | nothing |

- **Junk, signature packets and timers do not need to match.** That covers `Jc`/`Jmin`/`Jmax`, `I1`-`I5`, the rekey/keepalive ranges, `MaxHandshakeAttempts` and `DisableCookies`.
- **Header protection needs `S1`-`S4` ≥ 12**: the first 12 padding bytes are its nonce.
- **2.x clients need the same ranges, not just overlapping ones.** They check the server's random header values against their own range.

### Module parameter

`compat` (runtime: `/sys/module/amneziawg/parameters/compat`):

| Value | Behaviour |
|---|---|
| `0` | plain upstream behaviour |
| `1` (default) | detect older peers; when the server initiates to an unknown peer, probe AWG 3.x → 2.x → 1.x |
| `2` | as 1, and also probe vanilla WireGuard (puts a plain WireGuard handshake on the wire) |

Persist it with `deploy.sh --compat N` or `options amneziawg compat=N` in
`/etc/modprobe.d/amneziawg.conf`.

### Logs

When the server learns that a peer needs a fallback, it says so once:

```
amneziawg: awg0: peer 12 (203.0.113.7:51820) speaks AmneziaWG 1.x
amneziawg: awg0: peer 15 (198.51.100.4:40312) speaks AmneziaWG 2.x without S3/S4
amneziawg: awg0: peer 3 (192.0.2.10:51820) speaks WireGuard
```

Peers speaking the full protocol are not logged.

## How it works

- **Sending.** Every peer has a small mask of the features it lacks. The header
  value, paddings, header protection and trailers of every packet are picked
  from the device configuration minus that mask. An empty mask is exactly upstream.
- **Receiving.** Upstream's classifier runs first. Only packets it rejects are
  tried in the older formats: 3.x without HP, 1.x/2.x without S3/S4, WireGuard.
- **Packets that fit several formats.** The header bytes a format looks at are
  effectively random under another format, so with wide H ranges a packet can fit
  more than one. This also happens in upstream alone: with `RandomTrailers` a
  transport packet is first tested as a handshake message. The fork picks the
  reading under which the packet is consistent: a valid mac1 for initiations, a
  receiver index of ours for everything else. With up-to-date peers only, the
  transport fast path is unchanged.
- **Learning.** The mask is updated only from authenticated packets: a consumed
  handshake message, or a transport packet that decrypted and passed the replay
  check. A spoofed packet cannot downgrade a peer.
- **Server initiates first** (e.g. after a reboot, before the client sent
  anything). Initiations to a peer never heard from cycle through the formats,
  one per rekey timeout. If S4 is not known yet, the session is also confirmed
  with a keepalive in the other S4 format.
- **Two hosts running this fork** announce what their own configuration lacks in
  the first 4 bytes of the handshake padding, so a probe by one side cannot
  drag the other down to an older format. These bytes are a BLAKE2s tag keyed
  with the receiver's mac1 key. Without the receiver's public key they look like
  the random padding they replace, and other implementations ignore them.

## Installation and updates

[`scripts/deploy.sh`](scripts/README.md) builds and installs the module with
DKMS for every kernel that has headers, and handles updates and removal:

```
curl -fsSL https://raw.githubusercontent.com/freetushkan/amneziawg-linux-kernel-module/master/scripts/deploy.sh | bash -s -- install
/usr/src/amneziawg-linux-kernel-module/scripts/deploy.sh update [--reload]
/usr/src/amneziawg-linux-kernel-module/scripts/deploy.sh status
```

The DKMS version is `1.0.0+g<commit>`, so `dkms status` shows what is built.
`--reload` switches to the new build right away by restarting the active
`awg-quick@` units; otherwise it is picked up at the next reboot.

## Testing

- [`src/tests/compat.sh`](src/tests/compat.sh): a server with the full protocol
  against clients of every generation in network namespaces. It covers
  client- and server-initiated handshakes, loss with ambiguous headers (H ranges
  a quarter of the u32 space wide), `compat=0`, and two hosts running the fork.
- [`src/tests/vm/run.sh`](src/tests/vm/run.sh): runs it in a VM with a stock
  Ubuntu kernel, twice. Once with clients on **upstream** built as a second
  module: strict, it accepts only its own format and does not announce itself.
  Once with clients on this module. Works locally (`--kernel hwe`) and in CI.
- [Compatibility workflow](.github/workflows/compat.yml): on every push to
  `master`, every pull request, weekly (to catch upstream changes) and on demand.
  It runs the VM test for the newest Ubuntu 24.04 GA (6.8) and HWE kernels
  against current upstream. The matrix goes to the run summary and, for
  `master`, to the [report page](https://freetushkan.github.io/amneziawg-linux-kernel-module/)
  with history and the badges above.

## Other changes

- **Use-after-free fix in `wg_destruct()`.** The workqueues are flushed before
  the I1-I5 packets are freed.
- **Build on distribution kernels.** The `udp_tunnel` socket API is detected from
  the headers rather than by version, for backports such as Ubuntu 7.0.
- **Upstream issue to be aware of.** Upstream clients with `RandomTrailers` test
  every transport packet as a handshake message first, so they drop some of the
  server's packets when `H1`/`H2` are wide: about 40% at a quarter of the u32
  space, negligible at a width of ~50 000. Keep `H1`-`H3` narrow if you have
  upstream 3.x clients. The fork itself is not affected.

## Limitations

- **There is no per-peer override of the detected format yet.** It is learned
  automatically and kept for the life of the peer: until the peer is removed,
  the interface is recreated or the module is reloaded. After that it is
  learned again from the next handshake.
- **The cookie path under handshake load is not covered by the tests.**
