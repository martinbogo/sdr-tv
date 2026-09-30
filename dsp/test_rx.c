// Offline harness: run a HackRF capture through atsc_rx as fast as possible.
//   test_rx <capture.iq> <pilot hint Hz> <out.ts>
#include "atsc_rx.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
extern int atsc_debug; extern double atsc_tsign, atsc_tgain, atsc_fgain, atsc_pkp, atsc_pki;

static FILE *out;
static void on_pkt(void *ctx, const uint8_t p[188], int ok) { (void)ctx; if (ok) fwrite(p, 1, 188, out); }

int main(int argc, char **argv) {
    if (getenv("TDEBUG")) atsc_debug = 1;
    if (getenv("TSIGN")) atsc_tsign = atof(getenv("TSIGN"));
    if (getenv("TGAIN")) atsc_tgain = atof(getenv("TGAIN"));
    if (getenv("FGAIN")) atsc_fgain = atof(getenv("FGAIN"));
    if (getenv("PKP")) atsc_pkp = atof(getenv("PKP"));
    if (getenv("PKI")) atsc_pki = atof(getenv("PKI"));
    FILE *f = fopen(argv[1], "rb");
    out = fopen(argv[3], "wb");
    atsc_rx *rx = atsc_rx_create(20e6, atof(argv[2]), on_pkt, NULL);
    const size_t chunk = 262144;
    int8_t *buf = malloc(2 * chunk);
    size_t total = 0, n;
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    double next_report = 0.25;
    while ((n = fread(buf, 2, chunk, f)) > 0) {
        atsc_rx_process(rx, buf, n);
        total += n;
        double sig_t = total / 20e6;
        if (sig_t >= next_report) {
            atsc_stats st; atsc_rx_get_stats(rx, &st);
            printf("t=%.2fs state=%d pilot=%.1f kHz clock=%+.2f ppm snr=%.1f dB fields=%llu RS good=%llu corr=%llu bad=%llu pkts=%llu\n",
                   sig_t, st.state, st.pilot_offset_hz / 1e3, st.clock_ppm, st.snr_db,
                   st.fields, st.rs_good, st.rs_corrected, st.rs_bad, st.packets);
            next_report += 0.25;
        }
    }
    atsc_rx_flush(rx);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    { atsc_stats st; atsc_rx_get_stats(rx, &st); printf("final: snr=%.1f dB fields=%llu RS good=%llu corr=%llu bad=%llu pkts=%llu\n", st.snr_db, st.fields, st.rs_good, st.rs_corrected, st.rs_bad, st.packets); }
    double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("processed %.2f s of signal in %.2f s: %.2fx real time\n", total / 20e6, el, total / 20e6 / el);
    atsc_rx_destroy(rx);
    fclose(out);
    return 0;
}
