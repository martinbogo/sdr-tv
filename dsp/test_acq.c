// Acquisition benchmark: start the receiver at many points in an I/Q recording (20 Msps int8, tuned
// as the app tunes) and report how quickly it locks and whether the lock is good.
//   test_acq file.iq [trials] [seconds]
// Last line: RESULT good=G trials=N meanlock=S minsnr=D
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "atsc_rx.h"

static void on_pkt(void *c, const uint8_t *p, int ok) { (void)c; (void)p; (void)ok; }

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: test_acq file.iq [trials] [seconds]\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long bytes = ftell(f); fseek(f, 0, SEEK_SET);
    int8_t *iq = malloc(bytes);
    if (fread(iq, 1, bytes, f) != (size_t)bytes) { fprintf(stderr, "short read\n"); return 2; }
    fclose(f);
    size_t ns = bytes / 2;
    int trials = argc > 2 ? atoi(argv[2]) : 8;
    double dur = argc > 3 ? atof(argv[3]) : 1.5;
    double hint = -6690559.441;               // where the app's tuning puts the pilot
    atsc_rx *rx = atsc_rx_create(20e6, hint, on_pkt, NULL);
    size_t span = (size_t)(dur * 20e6), step = 20000;
    if (span > ns) span = ns;
    int good = 0; double tl_sum = 0, min_snr = 1e9;
    for (int t = 0; t < trials; t++) {
        size_t start = (size_t)((double)(ns - span) * t / trials) & ~1ul;
        atsc_rx_reset(rx, hint);
        double tlock = -1; atsc_stats st, mid = {0};
        for (size_t k = 0; k + step <= span; k += step) {
            atsc_rx_process(rx, iq + 2 * (start + k), step);
            if (k % 200000 == 0) {
                atsc_rx_flush(rx); atsc_rx_get_stats(rx, &st);
                if (tlock < 0 && st.state == ATSC_LOCKED) tlock = k / 20e6;
                if (k == span / 2 / 200000 * 200000) mid = st;
            }
        }
        atsc_rx_flush(rx); atsc_rx_get_stats(rx, &st);
        uint64_t g = st.rs_good + st.rs_corrected - (mid.rs_good + mid.rs_corrected), b = st.rs_bad - mid.rs_bad;
        double loss = g + b ? (double)b / (g + b) : 1;
        int ok = st.state == ATSC_LOCKED && loss < 0.05;
        good += ok; tl_sum += tlock >= 0 ? tlock : dur;
        if (st.snr_db < min_snr) min_snr = st.snr_db;
        printf("start %5.2fs  lock at %6.3fs  snr %5.1f dB  loss %5.1f%%  %s\n",
               start / 20e6, tlock, st.snr_db, 100 * loss, ok ? "good" : "BAD");
    }
    printf("RESULT good=%d trials=%d meanlock=%.3f minsnr=%.1f\n", good, trials, tl_sum / trials, min_snr);
    return 0;
}
