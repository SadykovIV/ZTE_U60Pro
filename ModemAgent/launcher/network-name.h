#ifndef ZTE_NETWORK_NAME_H
#define ZTE_NETWORK_NAME_H
#include <stddef.h>
#include <stdint.h>

typedef int (*network_name_getter)(char *target, int capacity);
/* Display only: SDK cached registered-network names, never SIM Operator/Operator2.
 * The OEM caller appends RAT and converts to a 256-byte UTF-8 scratch buffer. */
#define NETWORK_NAME_UTF8_LIMIT 96
#define NETWORK_NAME_SCALAR_LIMIT 60
#define NETWORK_NAME_WIDE_CAPACITY 128
void network_name_read(uint32_t *target, size_t capacity,
                       network_name_getter full, network_name_getter short_name);
#endif
