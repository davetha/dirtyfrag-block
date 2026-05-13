# dirtyfrag-block

> **Warning: this is largely untested. Use with caution and verify in a non-production environment first.**

Runtime mitigation for the DirtyFrag / Copy-Fail-2 Linux kernel vulnerability. Uses SystemTap to strip `MSG_SPLICE_PAGES` from UDP and RxRPC sendmsg calls before the zero-copy splice path can attach externally-backed pipe pages to skb frags. ESP in-place decrypt then operates on kernel-owned memory instead of page-cache pages, closing the arbitrary page-cache write primitive.

Blocks:
- [V4bel/dirtyfrag](https://github.com/V4bel/dirtyfrag) — xfrm ESP-in-UDP variant (requires userns)
- [0xdeadbeefnetwork/Copy_Fail2-Electric_Boogaloo](https://github.com/0xdeadbeefnetwork/Copy_Fail2-Electric_Boogaloo) — no-userns variant
- [v12-security/fragnesia](https://github.com/v12-security/pocs/tree/main/fragnesia) — xfrm ESP-in-TCP variant (espintcp ULP). **Untested** — probe is optional and silently skipped if `CONFIG_INET_ESPINTCP` is not enabled; verify on a kernel that has it before relying on this leg.

Affected kernels: 6.5 and later (where `MSG_SPLICE_PAGES` UDP support was introduced).

## How it works

The upstream fix ([f4c50a4](https://github.com/torvalds/linux/commit/f4c50a4034e62ab75f1d5cdd191dd5f9c77fdff4)) adds a `SKBFL_SHARED_FRAG` marker on the producer side and checks it on the consumer side to force `skb_cow_data()`. This mitigation intercepts at the producer — probing `udp_sendmsg` and `udpv6_sendmsg` at entry and clearing `MSG_SPLICE_PAGES` from `msg->msg_flags` before `__ip_append_data` runs. The kernel falls back to the copy path and the send still succeeds; only the zero-copy optimisation is lost.

`rxrpc_sendmsg` is probed with the same logic and is silently skipped if `rxrpc.ko` is not loaded. `espintcp_sendmsg` is probed the same way for the ESP-in-TCP (fragnesia) variant and silently skipped if espintcp is not built into the kernel — this leg has not been validated against a live PoC yet.

## Files

| File | Purpose |
|---|---|
| `dirtyfrag-block.stp` | SystemTap mitigation script |
| `dirtyfrag-block.service` | systemd unit for boot-time loading |
| `install-dirtyfrag-block.sh` | Install/build/manage wrapper |
| `test-dirtyfrag-block.py` | Verification test harness |

## Requirements

- Linux kernel 6.5+
- `systemtap` and `systemtap-runtime`
- `kernel-devel` and `kernel-debuginfo` matching the running kernel

## Install

```bash
sudo ./install-dirtyfrag-block.sh install-deps
sudo ./install-dirtyfrag-block.sh install
```

The installer compiles the SystemTap script into a kernel module pinned to the running kernel, installs a systemd service that loads it at boot, and runs the test harness to confirm the mitigation is active.

## Management

```bash
sudo ./install-dirtyfrag-block.sh status     # service and module state
sudo ./install-dirtyfrag-block.sh test       # run verification tests
sudo ./install-dirtyfrag-block.sh build      # rebuild after a kernel upgrade
sudo ./install-dirtyfrag-block.sh uninstall  # remove everything
```

## After a kernel upgrade

The compiled `.ko` is pinned to a specific kernel. After upgrading, rebuild before rebooting:

```bash
sudo ./install-dirtyfrag-block.sh build
```

Or rebuild and restart in one step:

```bash
sudo ./install-dirtyfrag-block.sh build && sudo systemctl restart dirtyfrag-block
```

## Confirming the mitigation is active

The strip counter is printed when the module unloads:

```
dirtyfrag-block: disarmed — stripped MSG_SPLICE_PAGES N time(s)
```

To see the flag being stripped live:

```bash
stap -g -e 'probe kernel.function("udp_sendmsg") { printf("flags: %x\n", $msg->msg_flags) }'
```

Run this before and after loading the module while triggering a splice-to-UDP — the `MSG_SPLICE_PAGES` bit (0x8000000) should be absent when the module is loaded.

## Treat as temporary

This is a stopgap until the host receives a patched kernel. The upstream fix is `f4c50a4` ("xfrm: esp: avoid in-place decrypt on shared skb frags"). Track your distribution's security advisories for the backport.
