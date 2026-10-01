# Public source export has no nested .git. Pin the actual lpac version.
set(LPAC_VERSION "v2.3.0-stdio-backports")
configure_file(${SRC} ${DST} @ONLY)
