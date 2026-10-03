# ADB stdin protocol v1. Receive and verify the complete body before execution.
# Octal packets fit legacy PTY canonical lines; no device files are created.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
zte_stream_fail() {
  printf '\n@BEGIN@\nZTE_STREAM_ERROR %s\n\n@RESULT@70\n' "$1"
  exit 0
}
printf '\n@READY@\n'
zte_encoded=
zte_i=0
while test "$zte_i" -lt @CHUNKS@; do
  IFS= read -r zte_line || zte_stream_fail INPUT_INCOMPLETE
  zte_i=$((zte_i + 1))
  zte_size=320
  if test "$zte_i" -eq @CHUNKS@; then zte_size=@LAST_CHARS@; fi
  test "${#zte_line}" -eq "$zte_size" || zte_stream_fail PACKET_SIZE
  case "$zte_line" in *[!01234567\\]*) zte_stream_fail PACKET_ENCODING;; esac
  zte_encoded=$zte_encoded$zte_line
done
IFS= read -r zte_end || zte_stream_fail INPUT_INCOMPLETE
test "$zte_end" = '@END@' || zte_stream_fail INPUT_END
zte_body=$(printf '%b' "$zte_encoded"; printf '.') || zte_stream_fail DECODE
zte_body=${zte_body%.}
test "${#zte_body}" -eq @BYTES@ || zte_stream_fail BODY_SIZE
zte_hash=
if command -v sha256sum >/dev/null 2>&1; then
  zte_hash=$(printf '%s' "$zte_body" | sha256sum) || zte_stream_fail HASH_FAILED
elif command -v busybox >/dev/null 2>&1; then
  zte_hash=$(printf '%s' "$zte_body" | busybox sha256sum) || zte_stream_fail HASH_FAILED
else
  zte_stream_fail HASHER_UNAVAILABLE
fi
test "${zte_hash%% *}" = '@SHA256@' || zte_stream_fail BODY_HASH
printf '\n@BEGIN@\n'
(eval "$zte_body") </dev/null
zte_code=$?
printf '\n@RESULT@%s\n' "$zte_code"
exit 0
