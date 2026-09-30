// Closed caption decoders: CEA-608 (line 21 captions, CC1-CC4) and CEA-708 (DTV captions,
// services 1-63), fed with the cc_data triplets carried in ATSC video (A/53 "GA94" user data).
#ifndef ATSC_CAPTIONS_H
#define ATSC_CAPTIONS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cc_decoder cc_decoder;

/// Receives the full caption screen whenever it changes, as JSON:
///   {"regions":[{"x":0.1,"y":0.8,"anchor":6,"lines":["HELLO","WORLD"]}, ...]}
/// x/y are 0..1 within the caption safe area; anchor 0..8 is which point of the region sits at
/// x/y (0 top-left, 1 top-centre, 2 top-right, 3..5 middle, 6..8 bottom). An empty region list
/// clears the screen.
typedef void (*cc_screen_cb)(void *ctx, const char *json);

/// service: 1..4 = CC1..CC4 (608); 101..163 = 708 service 1..63; 0 = off.
cc_decoder *cc_create(int service, cc_screen_cb cb, void *ctx);
void cc_destroy(cc_decoder *d);
void cc_reset(cc_decoder *d);

/// Feed the cc_data of one video frame (in display order): n triplets of
/// [marker|cc_valid|cc_type, byte1, byte2].
void cc_feed(cc_decoder *d, const uint8_t *triplets, int n);

#ifdef __cplusplus
}
#endif
#endif
