#include "Bob.h"
#include <string.h>

// Plain C so it is compiled with optimizations (and auto-vectorized) even in debug builds.
void swiftcut_bob(const uint8_t *source, size_t sourceStride,
                 uint8_t *destination, size_t destinationStride,
                 size_t rowLength, size_t height, int keepOddRows) {
    for (size_t y = 0; y < height; y++) {
        uint8_t *out = destination + y * destinationStride;
        if ((int)(y & 1) == keepOddRows || height < 2) {
            memcpy(out, source + y * sourceStride, rowLength);
            continue;
        }
        size_t above = y > 0 ? y - 1 : y + 1;
        size_t below = y + 1 < height ? y + 1 : y - 1;
        const uint8_t *a = source + above * sourceStride;
        const uint8_t *b = source + below * sourceStride;
        for (size_t i = 0; i < rowLength; i++) {
            out[i] = (uint8_t)((a[i] + b[i] + 1) >> 1);
        }
    }
}
