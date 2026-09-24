// B31 temporary font hook. No calls, allocation, I/O or persistent state.
// x0 = font manager, w1 = requested size, w2 = font ID.
// Only x16/x17 (AAPCS64 scratch) and w1 may change before the original prologue.
.extern LANGUAGE_ENUM
.extern FONT_RESUME
.section .text
.balign 4
.global screen_ru_font_scale
.type screen_ru_font_scale, %function
screen_ru_font_scale:
    cbz w2, check_language
    cmp w2, #2
    b.eq check_language
    cmp w2, #10
    b.ne original_prologue
check_language:
    adrp x16, LANGUAGE_ENUM
    ldr w16, [x16, #:lo12:LANGUAGE_ENUM]
    cmp w16, #2
    b.ne original_prologue
    // Keep tiny sizes and invalid/out-of-range requests on the stock path.
    cmp w1, #12
    b.lt original_prologue
    cmp w1, #64
    b.gt original_prologue
    mov w16, #17
    mul w16, w1, w16
    add w16, w16, #10
    mov w17, #20
    udiv w1, w16, w17
original_prologue:
    stp x29, x30, [sp, #-64]!
    b FONT_RESUME
.size screen_ru_font_scale, . - screen_ru_font_scale
