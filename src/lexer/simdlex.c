#include <assert.h>
#include <stdio.h>
#include <emmintrin.h>
#include <iso646.h>
#include <stdint.h>
#include <stddef.h>

typedef __m128i IntVector128;

[[gnu::always_inline]]
static inline IntVector128 vector128_fill_8bit(char c)
{ return _mm_set1_epi8(c); }

[[gnu::always_inline]]
static inline IntVector128 load_16_unaligned_signed(const IntVector128 *vec)
{ return _mm_loadu_si128(vec); }

[[gnu::always_inline]]
static inline IntVector128 vector128_compare_equal_8bit(IntVector128 a, IntVector128 b)
{ return _mm_cmpeq_epi8(a, b); }

[[gnu::always_inline]]
static inline IntVector128 vector128_bor(IntVector128 a, IntVector128 b)
{ return _mm_or_si128(a, b); }

[[gnu::always_inline]]
static inline unsigned int vector128_get_movemask_8bit(IntVector128 a)
{ return (unsigned int)_mm_movemask_epi8(a); }

#define count_trailing_zeros(...) __builtin_ctz(__VA_ARGS__)

typedef struct {
    uint32_t advance;
    uint32_t newlines;
    uint32_t tail_col;
} simdlex_scan_result;

uint32_t skip_space(const uint8_t *start, size_t len)
{
    if (not start or len == 0) return 0;
    const char *src = (const char *)start, *end = (const char *)start + len;

    const IntVector128  space   = vector128_fill_8bit(' '),
                        tab     = vector128_fill_8bit('\t'),
                        ret     = vector128_fill_8bit('\r'),
                        newln   = vector128_fill_8bit('\n');

    // 16 bytes at a time
    while (src + 16 <= end) {
        const IntVector128 vec = load_16_unaligned_signed((const IntVector128 *)src);

        const IntVector128  has_space = vector128_compare_equal_8bit(vec, space),
                            has_tab   = vector128_compare_equal_8bit(vec, tab),
                            has_ret   = vector128_compare_equal_8bit(vec, ret),
                            has_newln = vector128_compare_equal_8bit(vec, newln);

        //every byte in the vector will either be `0xFF` for a match, and `0x00` for no match
        const IntVector128 has_any = vector128_bor(vector128_bor(has_space, has_tab), vector128_bor(has_ret, has_newln));

        // local i, mask = 0, 0
        // for byte in bytes(has_any) do
        //      mask = mask | (msb(byte) << i)
        //      i = i + 1
        // end
        // at bit[i] will be msb of byte[i] in has_any
        const unsigned int mask = vector128_get_movemask_8bit(has_any);

        //every byte is whitespace
        if (mask == 0xFFFF) {
            src += 16; //skip all
        } else {
            int i = 0;
            //find first non-ws 
            while (mask & (((unsigned int)1) << i++));
            src += i - 1; //only go that much
            return (uint32_t)(src - (const char *)start);
        }
    }

    while (src < end and (*src == ' ' or *src == '\t' or *src == '\r' or *src == '\n')) {
        src++;
    }

    return (uint32_t)(src - (const char *)start);
}

uint32_t read_until(const uint8_t *start, size_t len, char c)
{
    if (not start or len == 0) return 0;
    const char *src = (const char *)start, *end = (const char *)start + len;

    const IntVector128 delim = vector128_fill_8bit(c);
    
    while (src + 16 <= end) {
        const IntVector128 vec = load_16_unaligned_signed((const IntVector128 *)src);

        const IntVector128 has_delim = vector128_compare_equal_8bit(vec, delim);

        const unsigned int movemask = vector128_get_movemask_8bit(has_delim);

        if (movemask == 0) {
            src += 16;
            continue;
        } else {
            src += count_trailing_zeros(movemask) + 1;
            return (uint32_t)(src - (const char *)start);
        }
    }

    while (src < end and *src++ != c);
    return (uint32_t)(src - (const char *)start);
}

simdlex_scan_result skip_line_comment(const uint8_t *start, size_t len)
{
    simdlex_scan_result res = { 0, 0, 0 };
    const uint8_t *src = start;
    const uint8_t *end = start + len;
    const IntVector128 nl = vector128_fill_8bit('\n');

    while (src + 16 <= end) {
        const IntVector128 vec = load_16_unaligned_signed((const IntVector128 *)src);
        const unsigned int mask_nl = vector128_get_movemask_8bit(vector128_compare_equal_8bit(vec, nl));
        if (mask_nl == 0) {
            src += 16;
            continue;
        }
        src += count_trailing_zeros(mask_nl);
        break;
    }

    while (src < end && *src != '\n') {
        src++;
    }
    res.advance = (uint32_t)(src - start);
    res.tail_col = res.advance;
    return res;
}

simdlex_scan_result skip_block_comment(const uint8_t *start, size_t len)
{
    simdlex_scan_result res = { 0, 0, 0 };
    const uint8_t *src = start;
    const uint8_t *end = start + len;
    uint32_t tail = 0;
    const IntVector128 nl = vector128_fill_8bit('\n');
    const IntVector128 star = vector128_fill_8bit('*');

    while (src + 16 <= end) {
        const IntVector128 vec = load_16_unaligned_signed((const IntVector128 *)src);
        const unsigned int mask_nl = vector128_get_movemask_8bit(vector128_compare_equal_8bit(vec, nl));
        const unsigned int mask_star = vector128_get_movemask_8bit(vector128_compare_equal_8bit(vec, star));
        const unsigned int mask_any = mask_nl | mask_star;
        if (mask_any == 0) {
            src += 16;
            tail += 16;
            continue;
        }
        const unsigned int idx = count_trailing_zeros(mask_any);
        src += idx;
        tail += idx;
        break;
    }

    while (src < end) {
        uint8_t c = *src;
        if (c == '*' && (src + 1) < end && src[1] == '/') {
            src += 2;
            tail += 2;
            break;
        }
        if (c == '\n') {
            src++;
            res.newlines += 1;
            tail = 1;
            continue;
        }
        src++;
        tail += 1;
    }

    res.advance = (uint32_t)(src - start);
    res.tail_col = tail;
    return res;
}

simdlex_scan_result scan_string_literal(const uint8_t *start, size_t len, uint8_t quote)
{
    simdlex_scan_result res = { 0, 0, 0 };
    const uint8_t *src = start;
    const uint8_t *end = start + len;
    uint32_t tail = 0;

    const IntVector128 v_quote = vector128_fill_8bit((char)quote);
    const IntVector128 v_newline = vector128_fill_8bit('\n');
    const IntVector128 v_escape = vector128_fill_8bit('\\');

    while (src + 16 <= end) {
        const IntVector128 vec = load_16_unaligned_signed((const IntVector128 *)src);
        const unsigned int mask_quote = vector128_get_movemask_8bit(vector128_compare_equal_8bit(vec, v_quote));
        const unsigned int mask_nl = vector128_get_movemask_8bit(vector128_compare_equal_8bit(vec, v_newline));
        const unsigned int mask_escape = vector128_get_movemask_8bit(vector128_compare_equal_8bit(vec, v_escape));
        const unsigned int mask_any = mask_quote | mask_nl | mask_escape;
        if (mask_any == 0) {
            src += 16;
            tail += 16;
            continue;
        }
        const unsigned int idx = count_trailing_zeros(mask_any);
        src += idx;
        tail += idx;
        break;
    }

    while (src < end) {
        uint8_t c = *src;
        src++;
        tail += 1;
        if (c == quote) {
            break;
        }
        if (c == '\\') {
            if (src < end) {
                src++;
                tail += 1;
            }
            continue;
        }
        if (c == '\n') {
            res.newlines += 1;
            tail = 1;
        }
    }

    res.advance = (uint32_t)(src - start);
    res.tail_col = tail;
    return res;
}
