// Streaming ATSC 1.0 (8VSB) receiver: HackRF 8-bit IQ in, MPEG transport packets out.
// Port of prototype/*.py; see those files for the derivations.
#ifndef ATSC_RX_H
#define ATSC_RX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct atsc_rx atsc_rx;

/// Called for every transport packet. `ok` is 0 when Reed-Solomon could not correct it
/// (the packet is still delivered, with transport_error_indicator set).
typedef void (*atsc_ts_cb)(void *ctx, const uint8_t pkt[188], int ok);

typedef enum {
    ATSC_ACQ_PILOT = 0,     // searching for the pilot
    ATSC_ACQ_SEGMENT,       // pilot locked, searching for segment sync
    ATSC_ACQ_FIELD,         // segment sync locked, waiting for a field sync
    ATSC_LOCKED             // equalizer running, decoding
} atsc_state;

typedef struct {
    atsc_state state;
    double pilot_offset_hz;     // pilot frequency relative to the tuned centre
    double clock_ppm;           // symbol clock vs nominal
    double snr_db;              // equalizer SNR on the last field sync (training)
    double dbfs;                // input level
    uint64_t fields;            // field syncs seen since lock
    uint64_t rs_good, rs_corrected, rs_bad;   // Reed-Solomon codewords since reset
    uint64_t packets;
} atsc_stats;

/// fs: input sample rate (20e6). pilot_hint_hz: expected pilot offset from the tuned centre.
atsc_rx *atsc_rx_create(double fs, double pilot_hint_hz, atsc_ts_cb cb, void *ctx);
void atsc_rx_destroy(atsc_rx *rx);

/// Restart acquisition, e.g. after retuning.
void atsc_rx_reset(atsc_rx *rx, double pilot_hint_hz);

/// Feed interleaved int8 I/Q; `n` is the number of complex samples.
void atsc_rx_process(atsc_rx *rx, const int8_t *iq, size_t n);

void atsc_rx_get_stats(atsc_rx *rx, atsc_stats *out);

/// Wait until all queued work has been processed (for offline use).
void atsc_rx_flush(atsc_rx *rx);

#ifdef __cplusplus
}
#endif
#endif
