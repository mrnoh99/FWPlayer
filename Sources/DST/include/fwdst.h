#ifndef FWDST_H
#define FWDST_H

#include <stddef.h>
#include <stdint.h>

/// Bytes per channel in one decoded SACD frame (588 samples x 64 / 8).
#define FWDST_FRAME_BYTES_PER_CHANNEL 4704

typedef struct fwdst fwdst_t;

/// Creates a DST decoder for `channels` (1...6) channels at DSD64. NULL on failure.
fwdst_t *fwdst_create(int channels);
void fwdst_destroy(fwdst_t *decoder);

/// Decodes one DST frame. `out` receives FWDST_FRAME_BYTES_PER_CHANNEL * channels bytes,
/// byte-interleaved by channel, MSB first. Returns 0 on success, otherwise a DST error code
/// (see fwdst_error_message).
int fwdst_decode(fwdst_t *decoder, const uint8_t *in, int in_length, int frame_number, uint8_t *out);

const char *fwdst_error_message(int error);

#endif
