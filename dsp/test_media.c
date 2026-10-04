#include <string.h>
// Offline harness: decode a transport stream file; list channels and guide events, count
// frames and audio, and write one frame of the chosen program as a PPM.
//   test_media <file.ts> <program> <out.ppm>
#include "atsc_media.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int frames, want_frame = 40, wrote;
static long audio_frames;
static const char *outpath;
static int nevents, ndesc, nrated, ncc;
static void on_desc(void *c, int src, int ev, const char *t) {
    (void)c; if (ndesc++ < 2) printf("  description: source %d event %d: %.100s\n", src, ev, t);
}

static long pkt_now, first_frame_pkt = -1, switch_pkt = -1, switch_frame_pkt = -1;
static void on_video(void *c, const uint8_t *y, const uint8_t *u, const uint8_t *v, int ys, int uvs,
                     int w, int h, int sn, int sd, int64_t pts) {
    (void)c;
    if (first_frame_pkt < 0) first_frame_pkt = pkt_now;
    if (getenv("FRAMEDIFF")) {                  // motion between consecutive pictures (repeats show as ~0)
        static uint8_t *prev; static int pw, ph; static int k;
        if (prev && pw == w && ph == h && k < 120) {
            double d = 0; for (int r = 0; r < h; r += 2) for (int x = 0; x < w; x += 2) d += abs(y[r * ys + x] - prev[r * w + x]);
            printf("diff %.2f\n", d / ((h / 2) * (w / 2))); k++;
        }
        if (!prev || pw != w || ph != h) { free(prev); prev = malloc(w * h); pw = w; ph = h; }
        for (int r = 0; r < h; r++) memcpy(prev + r * w, y + r * ys, w);
    }
    if (switch_pkt >= 0 && switch_frame_pkt < 0) switch_frame_pkt = pkt_now;
    if (getenv("SHOWPTS") && switch_pkt >= 0) { static int k; if (k++ < 90) printf("emit pts %.3f at packet %ld\n", pts / 90000.0, pkt_now); }
    if (frames == 0) printf("first video frame %dx%d sar %d/%d pts %.3f s\n", w, h, sn, sd, pts / 90000.0);
    if (frames < 8) printf("  video pts %.4f\n", pts / 90000.0);
    if (++frames == want_frame && !wrote) {
        FILE *f = fopen(outpath, "wb");
        fprintf(f, "P6 %d %d 255\n", w, h);
        for (int r = 0; r < h; r++)
            for (int x = 0; x < w; x++) {
                float Y = y[r * ys + x] - 16, U = u[(r / 2) * uvs + x / 2] - 128, V = v[(r / 2) * uvs + x / 2] - 128;
                float R = 1.164f * Y + 1.793f * V, G = 1.164f * Y - 0.213f * U - 0.533f * V, B = 1.164f * Y + 2.112f * U;
                unsigned char px[3] = {(unsigned char)(R < 0 ? 0 : R > 255 ? 255 : R), (unsigned char)(G < 0 ? 0 : G > 255 ? 255 : G),
                                       (unsigned char)(B < 0 ? 0 : B > 255 ? 255 : B)};
                fwrite(px, 1, 3, f);
            }
        fclose(f); wrote = 1;
    }
}
static void on_audio(void *c, const float *s, int n, int rate, int64_t pts) {
    (void)c; (void)s; (void)rate; static int na; if (na++ < 8) printf("  audio pts %.4f (%d samples)\n", pts / 90000.0, n); audio_frames += n;
}
static void on_channels(void *c, const atsc_vchannel *ch, int n) {
    (void)c;
    printf("virtual channels (%d):\n", n);
    for (int i = 0; i < n; i++)
        printf("  %d.%d  %-8s program %d  source %d  type %d%s\n", ch[i].major, ch[i].minor, ch[i].name,
               ch[i].program, ch[i].source_id, ch[i].service_type, ch[i].hidden ? " (hidden)" : "");
}
static void on_event(void *c, const atsc_event *e) {
    (void)c;
    if (e->rating[0]) nrated++;
    if (e->captions) ncc++;
    if (nevents < 3) printf("  guide extras: rating '%s' captions %d (%s) audio '%s'\n", e->rating, e->captions, e->caption_langs, e->audio_langs);
    if (nevents++ < 12) {
        time_t t = e->start_utc; struct tm tm; localtime_r(&t, &tm);
        char buf[32]; strftime(buf, sizeof buf, "%a %H:%M", &tm);
        printf("  guide: source %d  %s  %3d min  %s\n", e->source_id, buf, e->duration / 60, e->title);
    }
}
static void on_time(void *c, int64_t utc) {
    (void)c; static int once;
    if (!once++) { time_t t = utc; printf("broadcast time: %s", ctime(&t)); }
}
static int ncaps; static char lastcap[4096];
static void on_caps(void *c, int64_t pts, const char *j) {
    (void)c; (void)pts;
    if (strstr(j, "\"t\"") && strlen(j) > strlen(lastcap) / 2) { snprintf(lastcap, sizeof lastcap, "%s", j); ncaps++; }
}
static void on_format(void *c, int w, int h, int il, int ach) {
    (void)c; printf("format: %dx%d %s, audio %d ch\n", w, h, il ? "interlaced" : "progressive", ach);
}

int main(int argc, char **argv) {
    outpath = argv[3];
    atsc_media_cb cb = {0}; cb.video = on_video; cb.audio = on_audio; cb.channels = on_channels; cb.event = on_event; cb.time = on_time; cb.format = on_format; cb.description = on_desc; cb.captions = on_caps;
    atsc_media *m = atsc_media_create(&cb);
    atsc_media_select(m, atoi(argv[2]));
    if (getenv("CAPTIONS")) atsc_media_select_captions(m, atoi(getenv("CAPTIONS")));
    FILE *f = fopen(argv[1], "rb");
    uint8_t pkt[188];
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    long n = 0;
    // DROP_EVERY=N DROP_LEN=K: lose K packets every N (a signal dropout), to exercise concealment
    long every = getenv("DROP_EVERY") ? atol(getenv("DROP_EVERY")) : 0, dlen = getenv("DROP_LEN") ? atol(getenv("DROP_LEN")) : 200;
    // SWITCH_AT=packet SWITCH_TO=program: change program mid-stream (a subchannel switch)
    long sw_at = getenv("SWITCH_AT") ? atol(getenv("SWITCH_AT")) : -1; int sw_to = getenv("SWITCH_TO") ? atoi(getenv("SWITCH_TO")) : 0;
    while (fread(pkt, 1, 188, f) == 188) {
        if (n == sw_at) { switch_pkt = n; pkt_now = n; atsc_media_select(m, sw_to); }
        pkt_now = n;
        atsc_media_push(m, pkt, !(every && n % every < dlen)); n++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("%ld packets, %d video frames, %.2f s of audio, %d guide events, %d descriptions, %d rated, %d captioned, decoded in %.2f s\n",
           n, frames, audio_frames / 48000.0, nevents, ndesc, nrated, ncc, el);
    if (ncaps) printf("captions: %d screens; last: %.600s\n", ncaps, lastcap);
    atsc_media_status ms; atsc_media_get_status(m, &ms);
    printf("dropouts: %llu stream gaps, %llu damaged frames held back\n", ms.stream_gaps, ms.held_frames);
    double pps = 19392658.0 / 188 / 8;                      // packets per second of a mux
    if (first_frame_pkt >= 0) printf("timing: first picture %.0f ms into the stream\n", first_frame_pkt / pps * 1000);
    if (switch_pkt >= 0) printf("timing: switch to program %d: picture after %.0f ms (%s)\n", sw_to,
        switch_frame_pkt >= 0 ? (switch_frame_pkt - switch_pkt) / pps * 1000 : -1.0, ms.instant_switches ? "from cache" : "waited for a keyframe");
    atsc_media_destroy(m);
    return 0;
}
