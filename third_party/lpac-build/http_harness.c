/* Exercise the actual built HTTP stdio driver. This never uses a network API. */
#include <driver/http/stdio.h>
#include <euicc/interface.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    struct euicc_http_interface iface = {0};
    const char *headers[] = {"Content-Type: application/json", "X-Test: fixture", NULL};
    const uint8_t tx[] = "{}";
    uint8_t *rx = NULL;
    uint32_t code = 0, length = 0;
    if (driver_http_stdio.init(&iface)) return 10;
    int result = iface.transmit(NULL, "https://example.invalid/fixture", &code,
                               &rx, &length, tx, 2, headers);
    int pass = result == 0 && code == 200 && length == 2 && rx && !memcmp(rx, "{}", 2);
    free(rx);
    return pass ? 0 : 11;
}
