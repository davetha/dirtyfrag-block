# dirtyfrag-block

> **Tested on EL10 (kernel 6.12.0-124.55.1.el10_1.x86_64). Verify in a non-production environment before deploying elsewhere.**

Runtime mitigation for the DirtyFrag / Copy-Fail-2 Linux kernel vulnerability. Uses SystemTap to strip `MSG_SPLICE_PAGES` from UDP and RxRPC sendmsg calls before the zero-copy splice path can attach externally-backed pipe pages to skb frags. ESP in-place decrypt then operates on kernel-owned memory instead of page-cache pages, closing the arbitrary page-cache write primitive.

Blocks:
- [V4bel/dirtyfrag](https://github.com/V4bel/dirtyfrag) — xfrm ESP-in-UDP variant (requires userns)
- [0xdeadbeefnetwork/Copy_Fail2-Electric_Boogaloo](https://github.com/0xdeadbeefnetwork/Copy_Fail2-Electric_Boogaloo) — no-userns variant

Affected kernels: 6.5 and later (where `MSG_SPLICE_PAGES` UDP support was introduced).

## How it works

The upstream fix ([f4c50a4](https://github.com/torvalds/linux/commit/f4c50a4034e62ab75f1d5cdd191dd5f9c77fdff4)) adds a `SKBFL_SHARED_FRAG` marker on the producer side and checks it on the consumer side to force `skb_cow_data()`. This mitigation intercepts at the producer — probing `udp_sendmsg` and `udpv6_sendmsg` at entry and clearing `MSG_SPLICE_PAGES` from `msg->msg_flags` before `__ip_append_data` runs. The kernel falls back to the copy path and the send still succeeds; only the zero-copy optimisation is lost.

`rxrpc_sendmsg` is probed with the same logic and is silently skipped if `rxrpc.ko` is not loaded.

## Files

| File | Purpose |
|---|---|
| `dirtyfrag-block.stp` | SystemTap mitigation script |
| `dirtyfrag-block.service` | systemd unit for boot-time loading |
| `install-dirtyfrag-block.sh` | Install/build/manage wrapper |
| `test-dirtyfrag-block.py` | Verification test harness |

## Mitigation

### Primary: disable the vulnerable modules

If `esp4`, `esp6`, and `rxrpc` are all built as loadable modules on your system, the fastest mitigation is to blacklist and unload them:

```bash
sh -c "printf 'install esp4 /bin/false\ninstall esp6 /bin/false\ninstall rxrpc /bin/false\n' > /etc/modprobe.d/dirtyfrag.conf; rmmod esp4 esp6 rxrpc 2>/dev/null; true"
sync && echo 3 > /proc/sys/vm/drop_caches
```

The `rmmod` line unloads the modules from the running kernel immediately; the `modprobe.d` entry prevents them from reloading across reboots. The `drop_caches` flush evicts any page-cache state that could otherwise be reused before the modules finish tearing down. The trailing `true` ensures the command succeeds even if one or more modules were not loaded.

> **Check first:** run `grep -E '^(CONFIG_XFRM_ESP|CONFIG_AF_RXRPC)' /boot/config-$(uname -r)` and look for `=y` vs `=m`. A `=y` entry means the module is compiled directly into the kernel and cannot be unloaded.

### Fallback: SystemTap probe (built-in modules or mixed config)

If any of `esp4`, `esp6`, or `rxrpc` are compiled into the kernel (`=y`), they cannot be removed at runtime. Use the SystemTap mitigation in this repo instead — it intercepts at `udp_sendmsg`/`udpv6_sendmsg`/`rxrpc_sendmsg` and strips `MSG_SPLICE_PAGES` before the vulnerable zero-copy path runs, without requiring the modules to be absent.

The SystemTap probe works regardless of whether the modules are loadable or built-in. The `printf` approach is simply faster to deploy and has no dependencies — prefer it when your kernel config allows.

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

To verify live that `skb_splice_from_iter` (the page-attachment step) is suppressed:

```bash
stap -T 10 -e 'probe kernel.function("skb_splice_from_iter") { printf("page attached — mitigation NOT blocking\n") }'
```

Run that while triggering a splice-to-UDP. If the mitigation is working, you will see no output.

To observe flag stripping directly:

```bash
stap -g -e '
%{ #include <linux/socket.h>
   #ifndef MSG_SPLICE_PAGES
   #define MSG_SPLICE_PAGES 0x8000000
   #endif %}
probe kernel.function("udp_sendmsg") {
    if ($msg->msg_flags & %{ MSG_SPLICE_PAGES %})
        printf("MSG_SPLICE_PAGES present — being stripped\n")
}'
```

### Liveness warning on CONFIG_RETPOLINE kernels

On kernels built with `CONFIG_RETPOLINE=y` (most modern distro kernels), SystemTap prints:

```
WARNING: liveness analysis skipped on CONFIG_RETPOLINE kernel: identifier '$msg' at ...
```

This is expected and harmless. The warning means SystemTap could not statically verify whether the `$msg` variable is live at the probe point, but empirical testing confirms the flag is read and cleared correctly — `skb_splice_from_iter` is not called after the probe fires.

## Testing against the known exploits

### ESP/xfrm path (V4bel/dirtyfrag)

With the mitigation active, `exp --force-esp` reports `post-write verify failed (target unchanged)` and exits non-zero. The target binary is unchanged. `skb_splice_from_iter` is never called.

### rxrpc path (Copy_Fail2)

On kernels where `rxrpc` is not compiled in or available as a module (e.g. EL10), `socket(AF_RXRPC)` returns `EAFNOSUPPORT` and the path fails immediately. On kernels where `rxrpc` is available, the mitigation's `rxrpc_sendmsg` probe strips `MSG_SPLICE_PAGES` before the splice reaches the page-cache, and `/etc/passwd` is left unchanged.

### Why the exploit appears to hang

The exploit suppresses stderr by default. When the mitigation is active:
- The ESP path attempts 48 writes, each falls back to a copy (the send succeeds but no page-cache corruption occurs), and then exits with a failure after the verify step.
- The rxrpc path runs a user-space brute-force key search (visible on stderr with `2>&1`) before attempting kernel triggers. This can take up to a minute depending on the machine. It then exits with a failure after the post-trigger sanity check.

Run `./exp 2>&1` to see progress output.

## Treat as temporary

This is a stopgap until the host receives a patched kernel. The upstream fix is `f4c50a4` ("xfrm: esp: avoid in-place decrypt on shared skb frags"). Track your distribution's security advisories for the backport.
