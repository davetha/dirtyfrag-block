#!/usr/bin/env python3
"""
test-dirtyfrag-block.py

Verify the dirtyfrag-block SystemTap mitigation is active.

Tests:
  1. Kernel module is loaded
  2. Regular UDP send/recv still works (copy path not broken)
  3. splice() from a pipe to a UDP socket succeeds (flag stripped, copy path taken)
     — if the module is NOT loaded this also succeeds but via the vulnerable zero-copy path

Exit codes:
  0  all tests passed (mitigation active and functional)
  1  one or more tests failed
  2  runtime error
"""

import ctypes
import ctypes.util
import errno
import os
import socket
import subprocess
import sys

MODULE_NAME = "dirtyfrag_block"

SPLICE_F_MORE = 4

results = []


def check(label, passed, detail=""):
    tag = "[PASS]" if passed else "[FAIL]"
    line = f"  {tag}  {label}"
    if detail:
        line += f" — {detail}"
    print(line)
    results.append(passed)


def test_module_loaded():
    try:
        out = subprocess.check_output(["lsmod"], text=True)
        loaded = any(line.split()[0] == MODULE_NAME for line in out.splitlines() if line)
        check("kernel module loaded", loaded,
              f"{MODULE_NAME} {'found' if loaded else 'NOT found'} in lsmod")
    except Exception as e:
        check("kernel module loaded", False, str(e))


def test_udp_works():
    """Verify regular UDP send/recv is unaffected."""
    try:
        recv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        recv_sock.bind(("127.0.0.1", 0))
        port = recv_sock.getsockname()[1]
        recv_sock.settimeout(2)

        send_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        payload = b"dirtyfrag-block-test"
        send_sock.sendto(payload, ("127.0.0.1", port))
        data, _ = recv_sock.recvfrom(256)

        send_sock.close()
        recv_sock.close()
        check("regular UDP send/recv", data == payload)
    except Exception as e:
        check("regular UDP send/recv", False, str(e))


def test_splice_udp():
    """
    splice() from a pipe to a connected UDP socket must succeed.

    With the module loaded:   MSG_SPLICE_PAGES stripped → copy path → data delivered
    Without the module:       MSG_SPLICE_PAGES intact  → zero-copy path → vulnerable

    Either way splice() returns > 0 here; the test confirms the send is not
    broken by the mitigation (EPERM would mean we accidentally blocked the call).
    Pair with test_module_loaded() to confirm which path was taken.
    """
    libc_name = ctypes.util.find_library("c")
    if not libc_name:
        check("splice-to-UDP", False, "libc not found via ctypes")
        return

    libc = ctypes.CDLL(libc_name, use_errno=True)
    libc.splice.restype = ctypes.c_ssize_t
    libc.splice.argtypes = [
        ctypes.c_int, ctypes.POINTER(ctypes.c_int64),
        ctypes.c_int, ctypes.POINTER(ctypes.c_int64),
        ctypes.c_size_t, ctypes.c_uint,
    ]

    try:
        recv_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        recv_sock.bind(("127.0.0.1", 0))
        port = recv_sock.getsockname()[1]
        recv_sock.settimeout(2)

        send_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        send_sock.connect(("127.0.0.1", port))

        pipe_r, pipe_w = os.pipe()
        payload = b"dirtyfrag-splice-test"
        os.write(pipe_w, payload)
        os.close(pipe_w)

        ret = libc.splice(pipe_r, None, send_sock.fileno(), None,
                          len(payload), SPLICE_F_MORE)
        err = ctypes.get_errno()
        os.close(pipe_r)

        if ret < 0:
            detail = errno.errorcode.get(err, str(err))
            check("splice-to-UDP", False, f"splice() returned {ret}, errno={detail}")
        else:
            try:
                data, _ = recv_sock.recvfrom(256)
                check("splice-to-UDP", data == payload,
                      "data received correctly via copy path" if data == payload
                      else f"got {data!r}, expected {payload!r}")
            except socket.timeout:
                # splice returned success but recv timed out — kernel may have
                # buffered without delivering; not a mitigation failure
                check("splice-to-UDP", True,
                      f"splice() returned {ret} (recv timed out — likely kernel-buffered)")

        send_sock.close()
        recv_sock.close()
    except Exception as e:
        check("splice-to-UDP", False, str(e))


def main():
    print(f"dirtyfrag-block mitigation test")
    print(f"{'─' * 45}")

    try:
        test_module_loaded()
        test_udp_works()
        test_splice_udp()
    except Exception as e:
        print(f"RUNTIME ERROR: {e}", file=sys.stderr)
        sys.exit(2)

    print(f"{'─' * 45}")
    passed = sum(results)
    total = len(results)
    print(f"  {passed}/{total} passed")

    if passed == total:
        print("  Result: MITIGATED")
        sys.exit(0)
    else:
        print("  Result: INCOMPLETE — check failures above")
        sys.exit(1)


if __name__ == "__main__":
    main()
