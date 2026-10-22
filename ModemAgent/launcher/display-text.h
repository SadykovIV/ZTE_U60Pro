#ifndef ZTE_LAUNCHER_DISPLAY_TEXT_H
#define ZTE_LAUNCHER_DISPLAY_TEXT_H
#include <stddef.h>

/* Display-only fallback for the stock font. Never use the result as a profile
 * identifier or save it over the original name. The output is NUL-terminated
 * when capacity > 0, valid UTF-8, and ends in ... if it did not fit.
 * Country flags become [DE], common pictographs become short ASCII labels,
 * other emoji (including a complete ZWJ sequence) become one [*]. Newlines are
 * retained for existing multi-line captions; format/bidi controls are removed.
 * This is deliberately not a general Unicode shaping or emoji font engine. */
void display_text_name(const char *source, char *target, size_t capacity);
#endif
