/*
 * Thin single-threaded wrapper around the DST decoder in this directory, which
 * is taken from SACD Ripper (https://github.com/sacd-ripper/sacd-ripper,
 * libs/libdstdec, GPL v2, derived from the ISO/IEC 14496-3 reference decoder).
 * See NOTICE.txt.
 */
#include "fwdst.h"

#include <stdlib.h>
#include <string.h>

#include "types.h"
#include "dst_init.h"
#include "dst_fram.h"

#define FWDST_MAX_INPUT (1024 * 64)

struct fwdst
{
    ebunch   d;
    int      channels;
    uint8_t *scratch;
};

fwdst_t *fwdst_create(int channels)
{
    fwdst_t *decoder;

    if (channels < 1 || channels > MAX_CHANNELS)
        return NULL;

    decoder = (fwdst_t *) calloc(1, sizeof(fwdst_t));
    if (!decoder)
        return NULL;

    decoder->scratch = (uint8_t *) malloc(FWDST_MAX_INPUT);
    if (!decoder->scratch || DST_InitDecoder(&decoder->d, channels, 64) != 0)
    {
        free(decoder->scratch);
        free(decoder);
        return NULL;
    }
    decoder->channels = channels;
    return decoder;
}

void fwdst_destroy(fwdst_t *decoder)
{
    if (!decoder)
        return;
    DST_CloseDecoder(&decoder->d);
    free(decoder->scratch);
    free(decoder);
}

int fwdst_decode(fwdst_t *decoder, const uint8_t *in, int in_length, int frame_number, uint8_t *out)
{
    if (!decoder || !in || !out || in_length <= 0 || in_length > FWDST_MAX_INPUT)
        return -1;

    /* The decoder reads (and may touch) its input in place: give it a copy. */
    memcpy(decoder->scratch, in, (size_t) in_length);
    return DST_FramDSTDecode(decoder->scratch, out, in_length, frame_number, &decoder->d);
}

const char *fwdst_error_message(int error)
{
    return DST_GetErrorMessage(error);
}
