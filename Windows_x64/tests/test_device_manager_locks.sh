#!/bin/sh
# Synthetic concurrency check: never executes a modem manager on this host.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
diagnostic=$root/Resources/DiagnosticTools/manager.sh
opkg=$root/Resources/ExperimentalOpkg/manager.sh
supervisor=$root/Resources/HostTools/zte-timeout
scratch=$(mktemp -d "${TMPDIR:-/tmp}/zte-manager-lock.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

sh -n "$diagnostic"
sh -n "$opkg"
awk '/^# ATOMIC_LOCK_BEGIN$/{copy=1;next} /^# ATOMIC_LOCK_END$/{exit} copy{print}' "$diagnostic" > "$scratch/diagnostic-lock.sh"
awk '/^# ATOMIC_LOCK_BEGIN$/{copy=1;next} /^# ATOMIC_LOCK_END$/{exit} copy{print}' "$opkg" > "$scratch/opkg-lock.sh"
test -s "$scratch/diagnostic-lock.sh"
cmp "$scratch/diagnostic-lock.sh" "$scratch/opkg-lock.sh"

# The bundled supervisor replaces the absent firmware timeout applet. Both
# managers must pin its exact bytes and never require native flock/timeout.
timeout_hash=$(shasum -a 256 "$supervisor" | awk '{print $1}')
grep -q "^TIMEOUT_SHA=$timeout_hash\$" "$diagnostic"
grep -q "^TIMEOUT_SHA=$timeout_hash\$" "$opkg"
grep -q "\"zte-timeout\": \"$timeout_hash\"" "$root/Resources/HostTools/SHA256.json"
od -An -tu1 -N6 "$supervisor" | awk '$1==127 && $2==69 && $3==76 && $4==70 && $5==2 && $6==1 {ok=1} END{exit !ok}'
od -An -tu1 -j18 -N2 "$supervisor" | awk '$1==183 && $2==0 {ok=1} END{exit !ok}'
! grep -Eq 'for (utility|c) in .*flock' "$diagnostic" "$opkg"
! grep -Eq 'command -v timeout|[^a-zA-Z0-9_-]timeout[[:space:]]+[0-9]' "$diagnostic" "$opkg"

for category in DiagnosticTools ExperimentalOpkg; do
    file=$root/Resources/$category/manager.sh
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    grep -q "\"manager.sh\": \"$actual\"" "$root/Resources/$category/SHA256.json"
    case "$category" in
        DiagnosticTools) grep -q "DiagnosticManagerHash = \"$actual\"" "$root/src/Features/DiagnosticToolsFeatures.cs" ;;
        ExperimentalOpkg) grep -q "OpkgManagerHash = \"$actual\"" "$root/src/Features/OpkgFeatures.cs" ;;
    esac
done

cat > "$scratch/worker.sh" <<'WORKER'
#!/bin/sh
set -eu
CID=0123456789abcdef0123456789abcdef
BOOT=01234567-89ab-cdef-0123-456789abcdef
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
verify_lock_dir() { test -d "$1" && test ! -L "$1"; }
verify_lock_file() { test -f "$1" && test ! -L "$1"; }
. "$1"
mode=$2
path=$3
cleanup() {
    code=$?; trap - EXIT HUP INT TERM
    release_atomic_lock || code=1
    exit "$code"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
acquire_atomic_lock "$path"
case "$mode" in
    hold) printf 'ready\n' > "$path.ready"; sleep 2 ;;
    tamper) printf 'changed-owner\n' > "$path/owner" ;;
    terminate) kill -TERM "$$" ;;
    once) : ;;
    *) exit 2 ;;
esac
WORKER

lock=$scratch/operation.lock.d
sh "$scratch/worker.sh" "$scratch/diagnostic-lock.sh" hold "$lock" &
holder=$!
ready=0
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if test -f "$lock.ready"; then ready=1; break; fi
    sleep 0.1
done
test "$ready" = 1
if sh "$scratch/worker.sh" "$scratch/opkg-lock.sh" once "$lock" > "$scratch/contender.out" 2>&1; then
    echo 'Concurrent operation unexpectedly acquired lock' >&2
    exit 1
fi
grep -q 'FAIL BUSY' "$scratch/contender.out"
wait "$holder"
test ! -e "$lock"
sh "$scratch/worker.sh" "$scratch/opkg-lock.sh" once "$lock"
test ! -e "$lock"

if sh "$scratch/worker.sh" "$scratch/opkg-lock.sh" terminate "$lock" > "$scratch/terminate.out" 2>&1; then
    echo 'Terminated operation unexpectedly returned success' >&2
    exit 1
fi
test ! -e "$lock"

if sh "$scratch/worker.sh" "$scratch/diagnostic-lock.sh" tamper "$lock" > "$scratch/tamper.out" 2>&1; then
    echo 'Changed owner marker was incorrectly released' >&2
    exit 1
fi
test -d "$lock"
if sh "$scratch/worker.sh" "$scratch/opkg-lock.sh" once "$lock" > "$scratch/stale.out" 2>&1; then
    echo 'Uncertain lock was incorrectly stolen' >&2
    exit 1
fi
grep -q 'FAIL BUSY' "$scratch/stale.out"
printf 'PASS: bundled ARM64 timeout and SHA pins; concurrent, signal, released and uncertain atomic lock states\n'
