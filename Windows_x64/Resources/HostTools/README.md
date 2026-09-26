# Private modem process supervisor

`zte-timeout` is built from `Native/zte_timeout.c` with the local musl-cross compiler using `python3 tools/build_host_tools.py`. It is a static AArch64 Linux executable: no interpreter or shared libraries are required. `SHA256.json` and `PROVENANCE.json` describe the exact bundled binary. Static runtime notices are included in `LICENSES.txt`.

Usage: `zte-timeout SECONDS PROGRAM [ARGS...]`, with an integer deadline from 1 to 86400 seconds. `--version` prints the helper version. The program and arguments are passed directly to `execvp`; the helper never constructs or parses a shell command.

Exit status:

| Status | Meaning |
| --- | --- |
| Program exit status | Command finished before the deadline |
| 124 | Monotonic deadline reached |
| 125 | Invalid invocation or supervisor/kernel error |
| 126 | Executable found but could not be executed |
| 127 | Executable not found |
| 128 + signal | Command was killed by a signal, or the supervisor received HUP/INT/TERM before timeout |

The command runs in a separate process group. At the deadline, the supervisor sends TERM, then KILL after 250 milliseconds. HUP/INT/TERM are forwarded to the command group and use the same bounded escalation. Remaining descendants in that group are also stopped when the command exits normally. Linux subreaper mode collects orphaned descendants, and parent-death notification starts cleanup if the invoking process disappears. A child parent-death signal additionally stops the immediate command if its supervisor is killed.

The helper does not grant privileges, change the working directory, reset the environment, or isolate files/network. Callers must validate the binary and arguments and provide their own isolation. Processes that deliberately create another session/process group, an uncatchable SIGKILL of the supervisor, and kernel tasks stuck in uninterruptible sleep cannot be guaranteed to receive full descendant cleanup. A kernel cleanup failure is reported as 125 after the bounded wait.
