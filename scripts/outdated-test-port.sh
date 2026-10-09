#!/bin/bash
# Creates a local dummy MacPorts port so the Outdated tab can be tested.
#   setup  - create local repo, register it, install ports-test-dummy 1.0
#   bump   - publish version 1.1 (the installed 1.0 is now outdated)
#   clean  - uninstall the port, unregister and delete the local repo
set -euo pipefail

REPO="$HOME/ports-test"
PORTDIR="$REPO/sysutils/ports-test-dummy"
SOURCES=/opt/local/etc/macports/sources.conf
LINE="file://$REPO"
PORT=/opt/local/bin/port

write_portfile() {
  mkdir -p "$PORTDIR"
  cat > "$PORTDIR/Portfile" <<EOF
PortSystem          1.0
name                ports-test-dummy
version             $1
revision            0
categories          sysutils
maintainers         nomaintainer
license             MIT
platforms           any
supported_archs     noarch
description         Dummy port for testing the Ports app
long_description    \${description}
homepage            https://example.com
distfiles
use_configure       no
build               {}
destroot {
    xinstall -d \${destroot}\${prefix}/share/ports-test-dummy
    system "echo \${version} > \${destroot}\${prefix}/share/ports-test-dummy/version"
}
EOF
  (cd "$REPO" && /opt/local/bin/portindex >/dev/null)
}

case "${1:-}" in
  setup)
    write_portfile 1.0
    if ! grep -qF "$LINE" "$SOURCES"; then
      # the local source must come before the default rsync source
      sudo sed -i '' "1,/^rsync:/ s|^rsync:|$LINE\\
rsync:|" "$SOURCES"
    fi
    sudo "$PORT" install ports-test-dummy
    ;;
  bump)
    write_portfile 1.1
    echo "Published 1.1. Refresh the Outdated tab."
    ;;
  clean)
    sudo "$PORT" uninstall ports-test-dummy || true
    sudo sed -i '' "\|^$LINE\$|d" "$SOURCES"
    rm -rf "$REPO"
    ;;
  *) echo "usage: $0 setup|bump|clean"; exit 1 ;;
esac
