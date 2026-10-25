#ifndef FUNSIZE_BOB_H
#define FUNSIZE_BOB_H

#include <stddef.h>
#include <stdint.h>

/// Builds a full frame from one field of an interlaced 4-byte-per-pixel image.
/// Rows of the kept field are copied; each other row is the average of the rows above and below.
/// keepOddRows: 0 keeps the top field (rows 0, 2, 4...), 1 keeps the bottom field.
void swiftcut_bob(const uint8_t *source, size_t sourceStride,
                 uint8_t *destination, size_t destinationStride,
                 size_t rowLength, size_t height, int keepOddRows);

#endif
