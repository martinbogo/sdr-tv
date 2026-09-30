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
static int nevents;

static void on_video(void *c, const uint8_t *y, const uint8_t *u, const uint8_t *v, int ys, int uvs,
                     int w, int h, int sn, int sd, int64_t pts) {
    (void)c;
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
static void on_format(void *c, int w, int h, int il, int ach) {
    (void)c; printf("format: %dx%d %s, audio %d ch\n", w, h, il ? "interlaced" : "progressive", ach);
}

int main(int argc, char **argv) {
    outpath = argv[3];
    atsc_media_cb cb = {NULL, on_video, on_audio, on_channels, on_event, on_time, on_format};
    atsc_media *m = atsc_media_create(&cb);
    atsc_media_select(m, atoi(argv[2]));
    FILE *f = fopen(argv[1], "rb");
    uint8_t pkt[188];
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    long n = 0;
    while (fread(pkt, 1, 188, f) == 188) { atsc_media_push(m, pkt, 1); n++; }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("%ld packets, %d video frames, %.2f s of audio, %d guide events, decoded in %.2f s\n",
           n, frames, audio_frames / 48000.0, nevents, el);
    atsc_media_destroy(m);
    return 0;
}
