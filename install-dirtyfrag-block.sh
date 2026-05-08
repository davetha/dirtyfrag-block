#!/usr/bin/env bash
# install-dirtyfrag-block.sh
#
# Install, build, manage, and remove the dirtyfrag-block SystemTap mitigation.
#
# Usage: ./install-dirtyfrag-block.sh {install|install-deps|build|test|status|uninstall}

set -euo pipefail

MODNAME="dirtyfrag_block"
STP_SRC="dirtyfrag-block.stp"
SERVICE_SRC="dirtyfrag-block.service"
TEST_SRC="test-dirtyfrag-block.py"

INSTALL_DIR="/etc/dirtyfrag-block"
LIB_DIR="/var/lib/dirtyfrag-block"
SERVICE_DST="/etc/systemd/system/dirtyfrag-block.service"
STP_DST="${INSTALL_DIR}/${STP_SRC}"
KO_DST="${LIB_DIR}/${MODNAME}.ko"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

require_root() {
    [[ $EUID -eq 0 ]] || die "must be run as root"
}

require_tool() {
    command -v "$1" &>/dev/null || die "'$1' not found — run: $0 install-deps"
}

cmd_install_deps() {
    require_root
    info "Installing SystemTap and kernel debug packages"
    PKG_MGR=yum
    command -v dnf &>/dev/null && PKG_MGR=dnf
    $PKG_MGR install -y systemtap systemtap-runtime "kernel-devel-$(uname -r)"
    # kernel-debuginfo lives in a debuginfo repo; debuginfo-install handles the repo enable
    if command -v dnf &>/dev/null; then
        dnf debuginfo-install -y "kernel-$(uname -r)"
    else
        yum install -y "kernel-debuginfo-$(uname -r)"
    fi
}

cmd_build() {
    require_root
    require_tool stap
    [[ -f "$STP_DST" ]] || die "source not installed — run: $0 install first"

    info "Compiling SystemTap module for kernel $(uname -r)"
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    # stap -p4 -m writes modname.ko to CWD regardless of -o; cd into TMPDIR first
    pushd "$TMPDIR" >/dev/null
    stap -p4 -m "$MODNAME" -g "$STP_DST" -r "$(uname -r)" \
        || { popd >/dev/null; die "stap compilation failed"; }
    popd >/dev/null

    [[ -f "${TMPDIR}/${MODNAME}.ko" ]] || die "stap produced no .ko — check stap output above"
    mkdir -p "$LIB_DIR"
    install -m 600 "${TMPDIR}/${MODNAME}.ko" "$KO_DST"
    info "Module installed to $KO_DST"
}

cmd_install() {
    require_root
    require_tool stap
    require_tool staprun
    require_tool systemctl

    for f in "$STP_SRC" "$SERVICE_SRC" "$TEST_SRC"; do
        [[ -f "$f" ]] || die "missing source file: $f (run from the repo directory)"
    done

    info "Installing source and service files"
    mkdir -p "$INSTALL_DIR" "$LIB_DIR"
    install -m 640 "$STP_SRC"     "$STP_DST"
    install -m 644 "$SERVICE_SRC" "$SERVICE_DST"
    install -m 755 "$TEST_SRC"    "${INSTALL_DIR}/${TEST_SRC}"

    cmd_build

    info "Enabling and starting dirtyfrag-block service"
    systemctl daemon-reload
    systemctl enable --now dirtyfrag-block.service

    info "Verifying"
    sleep 2
    cmd_status
    python3 "${INSTALL_DIR}/${TEST_SRC}"
}

cmd_test() {
    TEST_SCRIPT="${INSTALL_DIR}/${TEST_SRC}"
    [[ -f "$TEST_SCRIPT" ]] || TEST_SCRIPT="./${TEST_SRC}"
    [[ -f "$TEST_SCRIPT" ]] || die "test script not found"
    python3 "$TEST_SCRIPT"
}

cmd_status() {
    echo "--- systemd service ---"
    systemctl status dirtyfrag-block.service --no-pager || true
    echo ""
    echo "--- kernel module ---"
    if lsmod | awk '{print $1}' | grep -qx "$MODNAME"; then
        echo "  ${MODNAME}: LOADED"
    else
        echo "  ${MODNAME}: NOT LOADED"
    fi
}

cmd_uninstall() {
    require_root

    info "Stopping and disabling service"
    systemctl stop    dirtyfrag-block.service 2>/dev/null || true
    systemctl disable dirtyfrag-block.service 2>/dev/null || true
    rm -f "$SERVICE_DST"
    systemctl daemon-reload

    info "Unloading kernel module"
    if lsmod | awk '{print $1}' | grep -qx "$MODNAME"; then
        staprun -d "$MODNAME" 2>/dev/null || rmmod "$MODNAME" || true
    fi

    info "Removing installed files"
    rm -rf "$INSTALL_DIR" "$LIB_DIR"

    # Verify clean
    if lsmod | awk '{print $1}' | grep -qx "$MODNAME"; then
        die "module still loaded after uninstall — reboot may be required"
    fi
    info "Uninstall complete"
}

case "${1:-}" in
    install)       cmd_install      ;;
    install-deps)  cmd_install_deps ;;
    build)         cmd_build        ;;
    test)          cmd_test         ;;
    status)        cmd_status       ;;
    uninstall)     cmd_uninstall    ;;
    *)
        echo "Usage: $0 {install|install-deps|build|test|status|uninstall}"
        exit 1
        ;;
esac
