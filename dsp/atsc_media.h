// ATSC transport stream demultiplexer, PSIP parser and audio/video decoder (FFmpeg).
#ifndef ATSC_MEDIA_H
#define ATSC_MEDIA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct atsc_media atsc_media;

/// One virtual channel from the Terrestrial Virtual Channel Table (A/65).
typedef struct {
    int major, minor;            // e.g. 7.1
    char name[32];               // short name, UTF-8 (e.g. "KGO-HD")
    int program;                 // MPEG program_number carrying it
    int source_id;               // links guide events to the channel
    int service_type;            // 2 = digital TV, 3 = audio only, 4 = data
    int hidden;
} atsc_vchannel;

/// One guide event from an Event Information Table.
typedef struct {
    int source_id;
    int event_id;
    int64_t start_utc;           // Unix time, seconds
    int duration;                // seconds
    char title[256];             // UTF-8
} atsc_event;

typedef struct {
    void *ctx;
    /// Decoded, deinterlaced picture (YUV 4:2:0 planar). pts is in 90 kHz units.
    void (*video)(void *ctx, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                  int y_stride, int uv_stride, int width, int height,
                  int sar_num, int sar_den, int64_t pts);
    /// Decoded audio downmixed to interleaved float stereo at `rate` Hz.
    void (*audio)(void *ctx, const float *stereo, int frames, int rate, int64_t pts);
    /// The virtual channel list changed.
    void (*channels)(void *ctx, const atsc_vchannel *ch, int n);
    /// A guide event was received (may repeat; key is source_id + event_id).
    void (*event)(void *ctx, const atsc_event *ev);
    /// Broadcast clock from the System Time Table, Unix seconds.
    void (*time)(void *ctx, int64_t utc);
    /// Format of the selected program's streams.
    void (*format)(void *ctx, int width, int height, int interlaced, int audio_channels);
} atsc_media_cb;

atsc_media *atsc_media_create(const atsc_media_cb *cb);
void atsc_media_destroy(atsc_media *m);

/// Forget everything (new RF channel).
void atsc_media_reset(atsc_media *m);

/// Decode this MPEG program_number (0: the first one listed).
void atsc_media_select(atsc_media *m, int program);

/// What the demultiplexer and decoders have achieved for the selected program, for diagnostics.
typedef struct {
    int tables_seen;             // PAT received
    int program_listed;          // the selected program is in the PAT
    int program_mapped;          // its PMT has been received
    int video_type, audio_type;  // MPEG stream_type of the chosen streams (0 = none)
    int video_supported, audio_supported;
    uint64_t video_frames, audio_frames;   // decoded since the program was selected
    uint64_t dropped_packets;    // packets lost to uncorrectable errors
} atsc_media_status;

void atsc_media_get_status(atsc_media *m, atsc_media_status *out);

/// Human-readable codec name for an MPEG stream_type ("MPEG-2", "H.264", "AC-3", ...).
const char *atsc_stream_type_name(int stream_type);

/// PIDs needed to record the selected program (PAT, its PMT, video, audio, PSIP). Returns count.
int atsc_media_selected_pids(atsc_media *m, int *pids, int max);

/// The program number currently being decoded, or -1.
int atsc_media_current_program(atsc_media *m);

/// Feed one 188-byte transport packet. Packets with `ok` == 0 are counted and dropped.
void atsc_media_push(atsc_media *m, const uint8_t pkt[188], int ok);

#ifdef __cplusplus
}
#endif
#endif
