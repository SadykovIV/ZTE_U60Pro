#ifndef ZTE_LAUNCHER_INFO_LAYOUT_H
#define ZTE_LAUNCHER_INFO_LAYOUT_H
#include <stddef.h>
#define INFO_MAX_SELECTED 12
#define INFO_DEFAULT_SELECTED 6
#define INFO_VIEWPORT_Y 76
#define INFO_VIEWPORT_HEIGHT 346
#define INFO_LAYOUT_MAX_BYTES 512
enum info_row { INFO_CPU, INFO_SIGNAL, INFO_NETWORK, INFO_CARRIERS, INFO_CPU_TEMP, INFO_MODEM_TEMP, INFO_MEMORY, INFO_STORAGE, INFO_UPTIME, INFO_BATTERY, INFO_RSRQ, INFO_SINR, INFO_ROWS };
enum info_style { INFO_STYLE_LIST, INFO_STYLE_TILES };
struct info_layout { unsigned char order[INFO_ROWS],enabled[INFO_ROWS],style; };
struct info_slot { unsigned metric; int x,y,width,height; };
void info_layout_default(struct info_layout *out);
int info_layout_valid(const struct info_layout *layout);
/* Parse the complete, length-bounded ASCII format. Failure always gives defaults. */
int info_layout_parse(const char *bytes,size_t length,struct info_layout *out);
/* Root-owned directory chain and a private regular file only. No writes. */
int info_layout_read(struct info_layout *out);
unsigned info_layout_selected(const struct info_layout *layout);
unsigned info_layout_slots(const struct info_layout *layout,struct info_slot out[INFO_MAX_SELECTED]);
#endif
