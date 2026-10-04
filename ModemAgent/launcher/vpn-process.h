#ifndef ZTE_VPN_PROCESS_H
#define ZTE_VPN_PROCESS_H
#include <stddef.h>
#define VPN_PROCESS_OUTPUT_LIMIT (256U * 1024U)
#define VPN_PROCESS_INPUT_LIMIT (64U * 1024U)
#define VPN_PROCESS_CLEANUP_MS 1000U

struct vpn_process_result {
 char *output; size_t output_length;
 int read_errno, write_errno, wait_errno, broker_errno;
 int exit_status, status_valid, proof_valid;
 int timed_out, output_limit, cleanup_complete;
};
/* Exactly one request followed by EOF. Return 1 means a complete transport and
 * normal child exit with independently verified status, INCLUDING nonzero exit.
 * The caller must separately validate JSON and its success/error schema.
 * Output is bounded bytes plus a convenience NUL; never log it unfiltered.
 * No process-wide signal disposition is changed in the caller.
 * On Linux the broker is a subreaper and abort cleanup covers owned descendants,
 * including children that create their own process groups. Kernels without
 * task/children use bounded raw procfs PPid discovery, always followed by
 * waitid ownership verification before signalling. On other platforms
 * abort cleanup is conservatively unconfirmed. Normal completion does not stop
 * legitimate detached services. Timeout never authorizes mutation retry.
 * A timeout has at most CLEANUP_MS + 250ms of additional collection time;
 * kernel stalls/power loss are outside the cleanup guarantee. */
int vpn_process_run(char *const argv[], const char *input, size_t input_length,
                    unsigned timeout_ms, struct vpn_process_result *result);
void vpn_process_free(struct vpn_process_result *result);
#endif
