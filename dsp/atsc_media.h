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
    char rating[32];             // content advisory text, e.g. "TV-PG-L" ("" if not given)
    int captions;                // 1 if a caption service is announced for the program
    char caption_langs[16];      // ISO 639-2 codes, comma-separated ("eng,spa")
    char audio_langs[24];        // languages of the program's audio, comma-separated
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
    /// Extended text (the program description) for a guide event, from an Extended Text Table.
    void (*description)(void *ctx, int source_id, int event_id, const char *text);
    /// Broadcast clock from the System Time Table, Unix seconds.
    void (*time)(void *ctx, int64_t utc);
    /// Caption screen changed (JSON, see atsc_captions.h), to be shown at video time `pts`.
    void (*captions)(void *ctx, int64_t pts, const char *json);
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
    uint64_t held_frames;        // damaged video frames not shown (the last good picture stays up)
    uint64_t stream_gaps;        // gaps found in the video/audio streams (continuity counter)
    uint64_t instant_switches;   // program switches that started from the cached GOP
} atsc_media_status;

void atsc_media_get_status(atsc_media *m, atsc_media_status *out);

/// Human-readable codec name for an MPEG stream_type ("MPEG-2", "H.264", "AC-3", ...).
const char *atsc_stream_type_name(int stream_type);

/// One audio stream of the selected program.
typedef struct {
    int pid, stream_type;
    char lang[4];                // ISO 639-2 code, "" if not signalled
    int role;                    // 0 main, 1 music/effects, 2 visually impaired (description),
                                 // 3 hearing impaired, 4 dialogue, 5 commentary, 6 emergency
    int channels;                // from the AC-3 descriptor, 0 if unknown
} atsc_audio_track;

/// One caption service announced by the broadcaster (caption_service_descriptor).
typedef struct {
    char lang[4];
    int digital;                 // 1: CEA-708 service `number`; 0: CEA-608 on field `number` (1 or 2)
    int number;
    int easy_reader, wide;
} atsc_caption_service;

int atsc_media_audio_tracks(atsc_media *m, atsc_audio_track *out, int max);
/// Choose the audio stream by index in the list above.
void atsc_media_select_audio(atsc_media *m, int index);
int atsc_media_caption_services(atsc_media *m, atsc_caption_service *out, int max);
/// 0 off, 1..4 CC1..CC4 (608), 101..163 708 service 1..63.
void atsc_media_select_captions(atsc_media *m, int service);

/// PIDs needed to record the selected program (PAT, its PMT, video, audio, PSIP). Returns count.
int atsc_media_selected_pids(atsc_media *m, int *pids, int max);

/// Guide collection on this RF channel: distinct EIT sections received since the last reset, and
/// transport packets since a new one last arrived. A mux repeats its whole guide every ~10-20 s,
/// so once nothing new has come for a few seconds the guide it carries is complete.
void atsc_media_guide_progress(atsc_media *m, int *sections, uint64_t *packets_since_new);

/// PIDs to record any program of this RF channel (PAT, its PMT, PSIP, video and every audio track),
/// whether or not it is the one being decoded. Returns 0 until its PMT has been received.
int atsc_media_program_pids(atsc_media *m, int program, int *pids, int max);

/// The program number currently being decoded, or -1.
int atsc_media_current_program(atsc_media *m);

/// Feed one 188-byte transport packet. Packets with `ok` == 0 are counted and dropped.
void atsc_media_push(atsc_media *m, const uint8_t pkt[188], int ok);

#ifdef __cplusplus
}
#endif
#endif
