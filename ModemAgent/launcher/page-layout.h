#ifndef ZTE_LAUNCHER_PAGE_LAYOUT_H
#define ZTE_LAUNCHER_PAGE_LAYOUT_H
#include <stddef.h>
#define PAGE_LAYOUT_MAX_BYTES 128
#define PAGE_LAYOUT_MAX_PAGES 3
enum page_id { PAGE_INFO=0, PAGE_VPN=1, PAGE_ESIM=2 };
enum page_layout_result { PAGE_LAYOUT_INVALID=0, PAGE_LAYOUT_CONFIG=1, PAGE_LAYOUT_DEFAULT=2 };
struct page_layout { unsigned char count, ids[PAGE_LAYOUT_MAX_PAGES]; };
void page_layout_default(struct page_layout *out);
int page_layout_valid(const struct page_layout *layout);
/* Exact complete ASCII document. Invalid input yields count0 (stock pages only). */
int page_layout_parse(const char *bytes,size_t length,struct page_layout *out);
/* No writes. Missing file in a trusted directory gives all3 defaults/result2;
 * malformed/unsafe file or unsafe directory gives count0/result0. */
int page_layout_read(struct page_layout *out);
#ifdef PAGE_LAYOUT_TEST
/* Test seam: production fixed root path/UID cannot be changed by environment. */
int page_layout_read_test(const char *parent,const char *directory,unsigned owner,struct page_layout *out);
#endif
#endif
