#ifndef ESIM_PROCESS_H
#define ESIM_PROCESS_H
struct esim_process_result { int read_errno,write_errno,wait_errno,exit_status,status_valid,protocol_error; };
/* Run one stdin request followed by EOF. Lines are NUL-terminated without LF.
 * Callback rejection still drains the child. Success requires exact broker
 * exit proof and status0, even if another SIGCHLD handler reaped the broker.
 * No signal is sent to the agent; this call waits for its natural cleanup. */
int esim_process_run(char *const argv[],const char *input,int (*line)(const char *,void *),void *context,struct esim_process_result *result);
#endif
