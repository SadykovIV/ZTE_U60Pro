#!/bin/sh
# fw3's include handles firewall reload; this also covers netifd reconnects.
case "${ACTION:-}" in
    ifup|ifupdate|ifdown)
        (
            test -f /data/zte-imei-ttl/boot.sh && test ! -L /data/zte-imei-ttl/boot.sh || exit 1
            test "$(sha256sum /data/zte-imei-ttl/boot.sh | awk '{print $1}')" = d13e69f8b9471ac6ab11fbace62cac1d5b64a16770c02d728bbebae3bd898040 || exit 1
            sh /data/zte-imei-ttl/boot.sh
        ) >&2
        ;;
esac
