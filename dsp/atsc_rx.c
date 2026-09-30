// Streaming ATSC 1.0 (8VSB) receiver. See atsc_rx.h and prototype/*.py.
#include "atsc_rx.h"
#include <stdio.h>
int atsc_debug = 0; double atsc_tsign = 1, atsc_tgain = 0.2, atsc_fgain = 0.01, atsc_pkp = 0.005, atsc_pki = 5e-8;

#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// ----------------------------------------------------------------------------- constants

#define RS_SYM (4.5e6 / 286.0 * 684.0)      // 10.762237762 Msymbols/s
#define ROLLOFF 0.1152
#define SEG 832                              // symbols per segment
#define HSEG (2 * SEG)                       // half-symbols per segment
#define FIELD_SEGS 313
#define DATA_SEGS 312
#define SEGDATA 828
#define NCODERS 12
#define BYTES_FIELD (DATA_SEGS * 207)        // 64584
#define ENC_SYMS (DATA_SEGS * SEGDATA / NCODERS)   // 21528 symbols per encoder per field
#define ENC_BYTES (BYTES_FIELD / NCODERS)    // 5382

#define MF_HALF 60                           // matched filter: 2*MF_HALF+1 taps at 20 Msps
#define MF_LEN (2 * MF_HALF + 1)
#define FFT_LOG2 13
#define FFT_N (1 << FFT_LOG2)
#define FFT_STEP (FFT_N - MF_LEN + 1)

#define INTERP_TAPS 16
#define INTERP_PHASES 256

#define FF_M 32                              // DFE feed-forward taps: -M..M at half-symbol spacing
#define FF_L (2 * FF_M + 1)
#define FB_L 64                              // DFE feedback taps
#define WCAP 4096                            // DFE input window ring (power of two)
#define TRAIN_LEN 728                        // sync + PN511 + 3 x PN63 + VSB mode

#define VIT_DEPTH 48
#define VIT_BLOCK 16
#define VIT_LEN (VIT_DEPTH + VIT_BLOCK)

typedef struct { float r, i; } cf;

static const float SYNC4[4] = {5, -5, -5, 5};

static const char *PN511 =
    "0000000101111111110010101010111001100110100010001001111000011101"
    "0111110100110101001110110011101001000101100011110010000101000111"
    "1100111101010001010011000011000100000100001111110000010101000000"
    "1100111111101110101010010110011000110111011110110100101001001110"
    "0111000101110100001101001111101100010101101111001101101011101101"
    "1001011011011100100100101110001110010111101000110101100001001101"
    "1111000100101011110001100101000010001100000111101111110101101010"
    "110010011001000111011100001011010000011011000000100100000001110";
static const char *PN63 = "111001001011011101100110101011111100000100001100010100111101000";
static const char *VSB_MODE = "000010100101111101011010";

// ----------------------------------------------------------------------------- pipeline queues
// Thread 1 (the caller of atsc_rx_process): front end, symbol timing, field-sync detection.
// Thread 2: adaptive equalizer. Thread 3: Viterbi, deinterleaver, Reed-Solomon, packets.
// Single-producer/single-consumer rings; dispatch semaphores count items and free slots and
// provide the memory ordering. `gen` changes on reset so stale work is dropped downstream.

typedef struct { int64_t s0; int is_field; uint32_t gen; } seg_desc;
#define Q1_CAP 2048                          // segments (u ring must hold more than this)
typedef struct { int s; int reset; uint32_t gen; float soft[828]; } soft_blk;
#define Q2_CAP 512

// ----------------------------------------------------------------------------- state

struct atsc_rx {
    // threads and queues
    pthread_t th2, th3;
    _Atomic int quit;
    _Atomic uint32_t gen; uint32_t gen2, gen3;
    _Atomic int reset_req; double reset_hint;
    seg_desc q1[Q1_CAP]; int64_t q1_head, q1_tail;
    dispatch_semaphore_t q1_items, q1_space;
    soft_blk *q2; int64_t q2_head, q2_tail;
    dispatch_semaphore_t q2_items, q2_space;
    _Atomic int64_t q1_pending, q2_pending;

    double fs;
    atsc_ts_cb cb;
    void *ctx;
    _Atomic int state;
    double pilot_hint;

    // stats
    double dbfs, snr_db, pilot_snr;
    uint64_t fields, rs_good, rs_corr, rs_bad, packets;

    // pilot acquisition buffer
    cf *acq; size_t acq_n, acq_cap;

    // NCO / pilot tracking
    double nco_ph, nco_f;                     // radians, radians/sample
    double pil_r, pil_i;                      // lowpassed pilot phasor
    int pil_cnt; double pil_acc_r, pil_acc_i;
    double pil_err_acc; long pil_err_n;
    int timing_lost, segs_since_field;
    uint64_t resyncs;
    uint64_t dfe_resets;

    // matched filter (overlap-save)
    vDSP_DFT_Setup dft_f, dft_i;
    float *H_r, *H_i;                         // filter spectrum
    float *ob_r, *ob_i;                       // overlap-save input block
    int ob_fill;
    float *t1r, *t1i, *t2r, *t2i;

    // matched-filter output history for the interpolator (complex, 20 Msps)
    cf *z; size_t z_n, z_cap;                 // z[0] is sample index z_base
    double z_base;

    // interpolator
    float itab[INTERP_PHASES + 1][INTERP_TAPS];
    double tau;                               // next output position, in z sample index units
    double step;                              // input samples per half-symbol

    // half-symbol stream u (normalized), kept in a ring with absolute index
    cf *u; size_t u_cap; int64_t u_count;     // u_count = total produced
    double u_pow;                             // running power for normalization

    // segment timing
    int64_t seg_next;                         // absolute u index where the next segment sync starts
    int seg_win; cf seg_acc[5];               // coherent sync correlation accumulator (offsets -2..2)
    cf *fold; int fold_segs; int64_t fold_start;

    // field tracking
    float pn511[511], pn63[63], vsbmode[24];
    double pn_avg; int pn_n;
    int seg_in_field;                         // 0 = field sync segment, 1..312 data
    int field_parity;                         // PN63 middle inversion of the current field
    int64_t field_seg_start;                  // u index of the current field sync segment

    // DFE (single precision, mirrored buffers)
    float wf_r[FF_L], wf_i[FF_L], bf[FB_L], cf_;
    float hbuf[2 * FB_L]; int hpos;
    float xw_r[2 * WCAP], xw_i[2 * WCAP]; int64_t rot_upto;
    float pc, ps; int pnorm;
    int dfe_ready;
    double train_err; int train_n;

    // Viterbi (per encoder)
    struct vit {
        float pm[4];
        uint8_t prev[VIT_LEN][4];
        uint8_t bit[VIT_LEN][4];
        uint8_t z2[VIT_LEN][4];
        int t, head;                           // symbols in the circular window, oldest slot
        uint64_t in_count, out_count;          // symbols in / decisions out
        uint8_t last_z2;
        uint8_t pair_acc; int pair_n;          // accumulating a byte
    } vit[NCODERS];
    int enc_of_pos[3][SEGDATA];              // encoder of data symbol j in segment s%3

    // byte reassembly: field byte k for (encoder e, byte index m in field)
    int32_t (*bytepos)[ENC_BYTES];
    uint8_t *fbuf[3]; int fcount[3];          // field byte buffers (ring of 3) and bytes filled
    int64_t field_emit;                       // next field index to hand to the deinterleaver

    // deinterleaver + RS + derandomizer
    uint8_t *X; int64_t X_count; size_t X_cap; // interleaved byte stream (ring)
    int64_t m_next;                           // next deinterleaved byte index
    uint8_t cw[207]; int cw_n; int64_t pkt_index;
    uint8_t prbs[DATA_SEGS * 187];
};

static void frontend_reset(atsc_rx *rx, double pilot_hint_hz);
static void backend_reset(atsc_rx *rx);
static void *thread2(void *arg);
static void *thread3(void *arg);

// ----------------------------------------------------------------------------- helpers

static double sincd(double x) { return fabs(x) < 1e-12 ? 1.0 : sin(M_PI * x) / (M_PI * x); }

static double rrc(double t, double beta) {
    if (fabs(t) < 1e-9) return 1 - beta + 4 * beta / M_PI;
    if (fabs(fabs(t) - 1 / (4 * beta)) < 1e-9)
        return beta / sqrt(2) * ((1 + 2 / M_PI) * sin(M_PI / (4 * beta)) + (1 - 2 / M_PI) * cos(M_PI / (4 * beta)));
    return (sin(M_PI * t * (1 - beta)) + 4 * beta * t * cos(M_PI * t * (1 + beta))) /
           (M_PI * t * (1 - (4 * beta * t) * (4 * beta * t)));
}

static double bessel_i0(double x) {
    double s = 1, t = 1;
    for (int k = 1; k < 30; k++) { t *= (x / (2 * k)) * (x / (2 * k)); s += t; }
    return s;
}

static void pn_levels(const char *bits, float *out, int n) {
    for (int i = 0; i < n; i++) out[i] = bits[i] == '1' ? 5.0f : -5.0f;
}

// ----------------------------------------------------------------------------- Reed-Solomon

static uint8_t gexp[512], glog[256];
static uint8_t gmul_root[20][256];          // x * alpha^j, for syndrome evaluation

static void gf_init(void) {
    int x = 1;
    for (int i = 0; i < 255; i++) {
        gexp[i] = (uint8_t)x; glog[x] = (uint8_t)i;
        x <<= 1; if (x & 0x100) x ^= 0x11D;
    }
    for (int i = 255; i < 512; i++) gexp[i] = gexp[i - 255];
    for (int j = 0; j < 20; j++)
        for (int v = 0; v < 256; v++) gmul_root[j][v] = v ? gexp[glog[v] + j] : 0;
}
static inline uint8_t gmul(uint8_t a, uint8_t b) { return (a && b) ? gexp[glog[a] + glog[b]] : 0; }
static inline uint8_t ginv(uint8_t a) { return gexp[255 - glog[a]]; }
static inline uint8_t gpow(int e) { e %= 255; if (e < 0) e += 255; return gexp[e]; }

static void rs_syndromes(const uint8_t *cw, uint8_t S[20]) {
    for (int j = 0; j < 20; j++) {
        const uint8_t *mj = gmul_root[j];
        uint8_t s = 0;
        for (int i = 0; i < 207; i++) s = mj[s] ^ cw[i];
        S[j] = s;
    }
}

// Returns corrected byte count, or -1 if uncorrectable.
static int rs_decode(uint8_t *cw) {
    uint8_t S[20]; rs_syndromes(cw, S);
    int any = 0; for (int j = 0; j < 20; j++) any |= S[j];
    if (!any) return 0;
    uint8_t C[21] = {1}, B[21] = {1}, T[21];
    int L = 0, m = 1; uint8_t bb = 1;
    for (int n = 0; n < 20; n++) {
        uint8_t d = S[n];
        for (int i = 1; i <= L; i++) d ^= gmul(C[i], S[n - i]);
        if (!d) { m++; continue; }
        uint8_t coef = gmul(d, ginv(bb));
        if (2 * L <= n) {
            memcpy(T, C, sizeof C);
            for (int i = m; i < 21; i++) C[i] ^= gmul(coef, B[i - m]);
            L = n + 1 - L; memcpy(B, T, sizeof B); bb = d; m = 1;
        } else {
            for (int i = m; i < 21; i++) C[i] ^= gmul(coef, B[i - m]);
            m++;
        }
    }
    if (L > 10) return -1;
    int locs[10], nl = 0;
    for (int p = 0; p < 207; p++) {
        int deg = 206 - p;
        uint8_t v = 0;
        for (int i = 0; i <= L; i++) if (C[i]) v ^= gmul(C[i], gpow(-deg * i));
        if (!v) { if (nl >= L) return -1; locs[nl++] = p; }
    }
    if (nl != L) return -1;
    uint8_t Om[20];
    for (int i = 0; i < 20; i++) {
        uint8_t v = 0;
        for (int j = 0; j <= i && j <= L; j++) v ^= gmul(C[j], S[i - j]);
        Om[i] = v;
    }
    for (int q = 0; q < nl; q++) {
        int deg = 206 - locs[q];
        uint8_t num = 0, den = 0;
        for (int i = 0; i < 20; i++) if (Om[i]) num ^= gmul(Om[i], gpow(-deg * i));
        for (int i = 1; i <= L; i += 2) if (C[i]) den ^= gmul(C[i], gpow(-deg * (i - 1)));
        if (!den) return -1;
        cw[locs[q]] ^= gmul(gmul(gpow(deg), num), ginv(den));
    }
    rs_syndromes(cw, S);
    for (int j = 0; j < 20; j++) if (S[j]) return -1;
    return nl;
}

// ----------------------------------------------------------------------------- randomizer

static void prbs_init(uint8_t *out, int n) {
    int st[17] = {0};
    const int preload[] = {15, 14, 13, 12, 8, 7};
    for (int k = 0; k < 6; k++) st[preload[k] + 1] = 1;
    const int outs[8] = {1, 3, 4, 7, 11, 12, 13, 14};
    for (int i = 0; i < n; i++) {
        int v = 0;
        for (int b = 0; b < 8; b++) v |= st[outs[b]] << b;
        out[i] = (uint8_t)v;
        int fb = st[16];
        for (int k = 16; k > 1; k--) {
            int tap = (k - 1 == 1 || k - 1 == 3 || k - 1 == 6 || k - 1 == 7 || k - 1 == 11 || k - 1 == 12 || k - 1 == 13);
            st[k] = st[k - 1] ^ (tap ? fb : 0);
        }
        st[1] = fb;
    }
}

// ----------------------------------------------------------------------------- setup

static void mf_init(atsc_rx *rx) {
    double sps2 = rx->fs / (RS_SYM / 2);     // samples per 2T
    float *hr = calloc(FFT_N, sizeof(float)), *hi = calloc(FFT_N, sizeof(float));
    double norm = 0;
    for (int n = 0; n < MF_LEN; n++) {
        double t = (n - MF_HALF) / sps2;
        double v = rrc(t, ROLLOFF);
        double ph = 2 * M_PI * (RS_SYM / 4) * (n - MF_HALF) / rx->fs;
        hr[n] = (float)(v * cos(ph)); hi[n] = (float)(v * sin(ph));
        norm += v * v;
    }
    for (int n = 0; n < MF_LEN; n++) { hr[n] /= (float)sqrt(norm); hi[n] /= (float)sqrt(norm); }
    rx->dft_f = vDSP_DFT_zop_CreateSetup(NULL, FFT_N, vDSP_DFT_FORWARD);
    rx->dft_i = vDSP_DFT_zop_CreateSetup(rx->dft_f, FFT_N, vDSP_DFT_INVERSE);
    rx->H_r = malloc(FFT_N * sizeof(float)); rx->H_i = malloc(FFT_N * sizeof(float));
    vDSP_DFT_Execute(rx->dft_f, hr, hi, rx->H_r, rx->H_i);
    float s = 1.0f / FFT_N;
    vDSP_vsmul(rx->H_r, 1, &s, rx->H_r, 1, FFT_N);
    vDSP_vsmul(rx->H_i, 1, &s, rx->H_i, 1, FFT_N);
    free(hr); free(hi);
    rx->ob_r = calloc(FFT_N, sizeof(float)); rx->ob_i = calloc(FFT_N, sizeof(float));
    rx->t1r = malloc(FFT_N * sizeof(float)); rx->t1i = malloc(FFT_N * sizeof(float));
    rx->t2r = malloc(FFT_N * sizeof(float)); rx->t2i = malloc(FFT_N * sizeof(float));
    rx->ob_fill = MF_LEN - 1;                 // leading zeros = filter history
}

static void interp_init(atsc_rx *rx) {
    for (int p = 0; p <= INTERP_PHASES; p++) {
        double frac = (double)p / INTERP_PHASES, sum = 0;
        for (int k = 0; k < INTERP_TAPS; k++) {
            double d = (k - (INTERP_TAPS / 2 - 1)) - frac;   // taps at -7..8 relative to floor
            double win = bessel_i0(6.0 * sqrt(fmax(0, 1 - (d / (INTERP_TAPS / 2.0)) * (d / (INTERP_TAPS / 2.0))))) / bessel_i0(6.0);
            rx->itab[p][k] = (float)(sincd(d) * win);
            sum += rx->itab[p][k];
        }
        for (int k = 0; k < INTERP_TAPS; k++) rx->itab[p][k] /= (float)sum;
    }
}

static void byte_map_init(atsc_rx *rx) {
    // Field byte k -> encoder (k + 4r) mod 12, r = segment boundaries passed before its 12-byte row
    // was latched (48 output symbols per row). See prototype/fec.py byte_map().
    rx->bytepos = malloc(sizeof(int32_t[ENC_BYTES]) * NCODERS);
    int count[NCODERS] = {0};
    for (int k = 0; k < BYTES_FIELD; k++) {
        int row = k / 12, r = (48 * row) / SEGDATA;
        int e = (k + 4 * r) % NCODERS;
        rx->bytepos[e][count[e]++] = k;
    }
    for (int s = 0; s < 3; s++)
        for (int j = 0; j < SEGDATA; j++) rx->enc_of_pos[s][j] = (j + 4 * s) % NCODERS;
}

atsc_rx *atsc_rx_create(double fs, double pilot_hint_hz, atsc_ts_cb cb, void *ctx) {
    static int gf_done = 0;
    if (!gf_done) { gf_init(); gf_done = 1; }
    atsc_rx *rx = calloc(1, sizeof(atsc_rx));
    rx->fs = fs; rx->cb = cb; rx->ctx = ctx;
    mf_init(rx);
    interp_init(rx);
    byte_map_init(rx);
    pn_levels(PN511, rx->pn511, 511);
    pn_levels(PN63, rx->pn63, 63);
    pn_levels(VSB_MODE, rx->vsbmode, 24);
    prbs_init(rx->prbs, DATA_SEGS * 187);
    rx->acq_cap = 1 << 20; rx->acq = malloc(rx->acq_cap * sizeof(cf));
    rx->z_cap = 1 << 16; rx->z = malloc(rx->z_cap * sizeof(cf));
    rx->u_cap = 1 << 22; rx->u = malloc(rx->u_cap * sizeof(cf));
    rx->fold = malloc(HSEG * sizeof(cf));
    for (int i = 0; i < 3; i++) rx->fbuf[i] = malloc(BYTES_FIELD);
    rx->X_cap = 4 * BYTES_FIELD; rx->X = malloc(rx->X_cap);
    rx->q2 = malloc(sizeof(soft_blk) * Q2_CAP);
    rx->q1_items = dispatch_semaphore_create(0); rx->q1_space = dispatch_semaphore_create(Q1_CAP);
    rx->q2_items = dispatch_semaphore_create(0); rx->q2_space = dispatch_semaphore_create(Q2_CAP);
    frontend_reset(rx, pilot_hint_hz);
    rx->gen2 = rx->gen3 = (uint32_t)-1;
    backend_reset(rx);
    pthread_create(&rx->th2, NULL, thread2, rx);
    pthread_create(&rx->th3, NULL, thread3, rx);
    return rx;
}

void atsc_rx_destroy(atsc_rx *rx) {
    if (!rx) return;
    atomic_store(&rx->quit, 1);
    dispatch_semaphore_signal(rx->q1_items); dispatch_semaphore_signal(rx->q2_items);
    pthread_join(rx->th2, NULL); pthread_join(rx->th3, NULL);
    free(rx->q2);
    vDSP_DFT_DestroySetup(rx->dft_f); vDSP_DFT_DestroySetup(rx->dft_i);
    free(rx->H_r); free(rx->H_i); free(rx->ob_r); free(rx->ob_i);
    free(rx->t1r); free(rx->t1i); free(rx->t2r); free(rx->t2i);
    free(rx->acq); free(rx->z); free(rx->u); free(rx->fold); free(rx->bytepos);
    for (int i = 0; i < 3; i++) free(rx->fbuf[i]);
    free(rx->X);
    free(rx);
}

static void vit_reset(atsc_rx *rx) {
    for (int e = 0; e < NCODERS; e++) {
        struct vit *v = &rx->vit[e];
        memset(v, 0, sizeof *v);
        v->pm[1] = v->pm[2] = v->pm[3] = 1e9f;
    }
}

void atsc_rx_reset(atsc_rx *rx, double pilot_hint_hz) {
    // applied by the processing thread at the start of the next atsc_rx_process call
    rx->reset_hint = pilot_hint_hz;
    atomic_store(&rx->reset_req, 1);
}

void atsc_rx_flush(atsc_rx *rx) {
    while (atomic_load(&rx->q1_pending) > 0 || atomic_load(&rx->q2_pending) > 0) usleep(1000);
}

static void frontend_reset(atsc_rx *rx, double pilot_hint_hz) {
    atomic_fetch_add(&rx->gen, 1);
    rx->state = ATSC_ACQ_PILOT;
    rx->pilot_hint = pilot_hint_hz;
    rx->pilot_snr = 0;
    rx->acq_n = 0;
    rx->nco_ph = 0; rx->nco_f = 0;
    rx->pil_r = 0; rx->pil_i = 0; rx->pil_cnt = 0; rx->pil_acc_r = rx->pil_acc_i = 0;
    memset(rx->ob_r, 0, FFT_N * sizeof(float)); memset(rx->ob_i, 0, FFT_N * sizeof(float));
    rx->ob_fill = MF_LEN - 1;
    rx->z_n = 0; rx->z_base = 0;
    rx->tau = INTERP_TAPS;                    // leave room for interpolator history
    rx->step = rx->fs / (2 * RS_SYM);
    rx->u_count = 0; rx->u_pow = 0;
    rx->fold_segs = 0; rx->fold_start = -1;
    rx->seg_win = 0; memset(rx->seg_acc, 0, sizeof rx->seg_acc);
    rx->pn_avg = 0; rx->pn_n = 0;
    rx->seg_next = 0;
    rx->timing_lost = 0; rx->segs_since_field = 0;
}

void atsc_rx_get_stats(atsc_rx *rx, atsc_stats *o) {
    o->state = rx->state;
    o->pilot_offset_hz = -rx->nco_f * rx->fs / (2 * M_PI);
    o->clock_ppm = (rx->step / (rx->fs / (2 * RS_SYM)) - 1) * 1e6;
    o->snr_db = rx->snr_db;
    o->dbfs = rx->dbfs;
    o->pilot_snr_db = rx->pilot_snr;
    o->fields = rx->fields;
    o->rs_good = rx->rs_good; o->rs_corrected = rx->rs_corr; o->rs_bad = rx->rs_bad;
    o->packets = rx->packets;
}

// ----------------------------------------------------------------------------- back end

static void emit_packet(atsc_rx *rx, uint8_t *cw, int ok) {
    uint8_t pkt[188];
    pkt[0] = 0x47;
    const uint8_t *pr = rx->prbs + (rx->pkt_index % DATA_SEGS) * 187;
    for (int i = 0; i < 187; i++) pkt[1 + i] = cw[i] ^ pr[i];
    if (!ok) pkt[1] |= 0x80;                  // transport_error_indicator
    rx->pkt_index++;
    rx->packets++;
    if (rx->cb) rx->cb(rx->ctx, pkt, ok);
}

// Interleaved field bytes -> deinterleave (B=52, M=4) -> RS -> derandomize -> TS.
static void push_field_bytes(atsc_rx *rx, const uint8_t *fb) {
    for (int k = 0; k < BYTES_FIELD; k++) rx->X[(rx->X_count + k) % rx->X_cap] = fb[k];
    rx->X_count += BYTES_FIELD;
    while (1) {
        int64_t m = rx->m_next;
        int64_t src = m + 208 * (m % 52);
        if (src >= rx->X_count) break;
        rx->cw[rx->cw_n++] = rx->X[src % rx->X_cap];
        rx->m_next++;
        if (rx->cw_n == 207) {
            int r = rs_decode(rx->cw);
            if (r == 0) rx->rs_good++; else if (r > 0) rx->rs_corr++; else rx->rs_bad++;
            emit_packet(rx, rx->cw, r >= 0);
            rx->cw_n = 0;
        }
    }
}

// Store one decoded byte of encoder e; hand complete fields on in order.
static void vit_byte(atsc_rx *rx, int e, uint64_t byte_no, uint8_t val) {
    uint64_t field = byte_no / ENC_BYTES;
    int m = (int)(byte_no % ENC_BYTES);
    int slot = (int)(field % 3);
    rx->fbuf[slot][rx->bytepos[e][m]] = val;
    rx->fcount[slot]++;
    while (rx->fcount[rx->field_emit % 3] == BYTES_FIELD) {
        int s = (int)(rx->field_emit % 3);
        push_field_bytes(rx, rx->fbuf[s]);
        rx->fcount[s] = 0;
        rx->field_emit++;
    }
}

static void vit_output(atsc_rx *rx, int e, int x1, int z2) {
    struct vit *v = &rx->vit[e];
    int x2 = z2 ^ v->last_z2;                  // undo the differential precoder
    v->last_z2 = (uint8_t)z2;
    v->pair_acc = (uint8_t)((v->pair_acc << 2) | (x2 << 1) | x1);
    if (++v->pair_n == 4) {
        vit_byte(rx, e, v->out_count / 4, v->pair_acc);
        v->pair_n = 0; v->pair_acc = 0;
    }
    v->out_count++;
}

static void vit_traceback(atsc_rx *rx, int e, int nout) {
    // trace back from the best state through the whole window; emit the oldest nout decisions
    struct vit *v = &rx->vit[e];
    int s = 0; float best = v->pm[0];
    for (int k = 1; k < 4; k++) if (v->pm[k] < best) { best = v->pm[k]; s = k; }
    uint8_t xs[VIT_LEN], zs[VIT_LEN];
    for (int n = v->t - 1; n >= 0; n--) {
        int slot = (v->head + n) % VIT_LEN;
        xs[n] = v->bit[slot][s]; zs[n] = v->z2[slot][s];
        s = v->prev[slot][s];
    }
    for (int n = 0; n < nout; n++) vit_output(rx, e, xs[n], zs[n]);
    v->head = (v->head + nout) % VIT_LEN;
    v->t -= nout;
}

static void vit_symbol(atsc_rx *rx, int e, float r) {
    struct vit *v = &rx->vit[e];
    // best parallel-branch metric for each (Z1, Z0): levels 2*(4 Z2 + 2 Z1 + Z0) - 7
    float bm[4]; uint8_t bz[4];
    for (int q = 0; q < 4; q++) {
        float l0 = 2.0f * q - 7.0f, d0 = (r - l0) * (r - l0), d1 = (r - l0 - 8.0f) * (r - l0 - 8.0f);
        if (d0 <= d1) { bm[q] = d0; bz[q] = 0; } else { bm[q] = d1; bz[q] = 1; }
    }
    int slot = (v->head + v->t) % VIT_LEN;
    float nw[4] = {1e30f, 1e30f, 1e30f, 1e30f};
    for (int s = 0; s < 4; s++) {
        int a = s >> 1, b = s & 1;
        for (int x1 = 0; x1 < 2; x1++) {
            int ns = (b << 1) | (a ^ x1), q = 2 * x1 + b;
            float m = v->pm[s] + bm[q];
            if (m < nw[ns]) { nw[ns] = m; v->prev[slot][ns] = (uint8_t)s; v->bit[slot][ns] = (uint8_t)x1; v->z2[slot][ns] = bz[q]; }
        }
    }
    float mn = fminf(fminf(nw[0], nw[1]), fminf(nw[2], nw[3]));
    for (int s = 0; s < 4; s++) v->pm[s] = nw[s] - mn;
    v->t++;
    v->in_count++;
    if (v->t == VIT_LEN) vit_traceback(rx, e, VIT_BLOCK);
}

// ----------------------------------------------------------------------------- DFE

static inline float slice8(float y) {
    float k = floorf((y + 8.0f) * 0.5f);
    if (k < 0) k = 0; if (k > 7) k = 7;
    return -7.0f + 2.0f * k;
}

static inline cf u_at(atsc_rx *rx, int64_t k) { return rx->u[k & (rx->u_cap - 1)]; }

// Equalize one symbol centred at u index k. When `has_known`, `known` is the training value.
// Input samples are derotated by the carrier phase once, as they enter the tap window, into a
// mirrored buffer so the window is always contiguous; the decision history is mirrored likewise.
static float dfe_symbol(atsc_rx *rx, int64_t k, int has_known, float known) {
    if (rx->rot_upto < k - FF_M || rx->rot_upto > k + FF_M + 1) rx->rot_upto = k - FF_M;
    while (rx->rot_upto <= k + FF_M) {
        cf x = u_at(rx, rx->rot_upto);
        int pos = (int)(rx->rot_upto & (WCAP - 1));
        float rr = x.r * rx->pc - x.i * rx->ps, ri = x.r * rx->ps + x.i * rx->pc;
        rx->xw_r[pos] = rr; rx->xw_r[pos + WCAP] = rr;
        rx->xw_i[pos] = ri; rx->xw_i[pos + WCAP] = ri;
        rx->rot_upto++;
    }
    const float *xr = rx->xw_r + ((k - FF_M) & (WCAP - 1));
    const float *xi = rx->xw_i + ((k - FF_M) & (WCAP - 1));
    float *wr = rx->wf_r, *wi = rx->wf_i;
    float acc_r = 0, acc_i = 0;
    for (int i = 0; i < FF_L; i++) {
        acc_r += wr[i] * xr[i] - wi[i] * xi[i];
        acc_i += wr[i] * xi[i] + wi[i] * xr[i];
    }
    const float *h = rx->hbuf + rx->hpos;               // h[0] = most recent decision
    float fb = 0;
    for (int j = 0; j < FB_L; j++) fb += rx->bf[j] * h[j];
    float y = acc_r + rx->cf_ - fb;
    float d = has_known ? known : slice8(y);
    float e = d - y;
    const float mu_w = 3e-4f, mu_b = 3e-5f, mu_c = 1e-5f, mu_th = 1e-4f;
    float ew = mu_w * e, eb = mu_b * e;
    for (int i = 0; i < FF_L; i++) { wr[i] += ew * xr[i]; wi[i] -= ew * xi[i]; }
    for (int j = 0; j < FB_L; j++) rx->bf[j] -= eb * h[j];
    rx->cf_ += mu_c * e;
    // carrier phase: theta += dtheta; phasor p = e^{-j theta} rotated incrementally
    float dth = mu_th * e * acc_i;
    float pc = rx->pc + rx->ps * dth, ps = rx->ps - rx->pc * dth;
    if (++rx->pnorm == 1024) { float m = 1.0f / sqrtf(pc * pc + ps * ps); pc *= m; ps *= m; rx->pnorm = 0; }
    rx->pc = pc; rx->ps = ps;
    // push decision: history is stored backwards in a mirrored buffer
    rx->hpos = (rx->hpos + FB_L - 1) % FB_L;
    rx->hbuf[rx->hpos] = d; rx->hbuf[rx->hpos + FB_L] = d;
    if (has_known) { rx->train_err += e * e; rx->train_n++; }
    return y;
}

// Least-squares FSE initialisation from one field sync segment (both PN63 polarities tried).
static int solve(double *A, double *bvec, int n) {        // Gaussian elimination, in place
    for (int c = 0; c < n; c++) {
        int p = c; double mx = fabs(A[c * n + c]);
        for (int r = c + 1; r < n; r++) if (fabs(A[r * n + c]) > mx) { mx = fabs(A[r * n + c]); p = r; }
        if (mx < 1e-12) return -1;
        if (p != c) {
            for (int k = 0; k < n; k++) { double t = A[c * n + k]; A[c * n + k] = A[p * n + k]; A[p * n + k] = t; }
            double t = bvec[c]; bvec[c] = bvec[p]; bvec[p] = t;
        }
        for (int r = c + 1; r < n; r++) {
            double f = A[r * n + c] / A[c * n + c];
            if (f == 0) continue;
            for (int k = c; k < n; k++) A[r * n + k] -= f * A[c * n + k];
            bvec[r] -= f * bvec[c];
        }
    }
    for (int c = n - 1; c >= 0; c--) {
        double s = bvec[c];
        for (int k = c + 1; k < n; k++) s -= A[c * n + k] * bvec[k];
        bvec[c] = s / A[c * n + c];
    }
    return 0;
}

static void training_seq(atsc_rx *rx, int inverted, float *t) {
    memcpy(t, SYNC4, 4 * sizeof(float));
    memcpy(t + 4, rx->pn511, 511 * sizeof(float));
    for (int r = 0; r < 3; r++)
        for (int i = 0; i < 63; i++) t[515 + 63 * r + i] = (r == 1 && inverted) ? -rx->pn63[i] : rx->pn63[i];
    memcpy(t + 704, rx->vsbmode, 24 * sizeof(float));
}

static void dfe_init_ls(atsc_rx *rx, int64_t seg0) {
    const int P = 2 * FF_L + 1;
    double *A = malloc(sizeof(double) * P * P), *bv = malloc(sizeof(double) * P);
    double best_err = 1e30; int best_inv = 0;
    double best_w[2 * FF_L + 1];
    float t[TRAIN_LEN];
    for (int inv = 0; inv < 2; inv++) {
        training_seq(rx, inv, t);
        memset(A, 0, sizeof(double) * P * P); memset(bv, 0, sizeof(double) * P);
        double row[2 * FF_L + 1];
        for (int n = 0; n < TRAIN_LEN; n++) {
            for (int i = 0; i < FF_L; i++) {
                cf x = u_at(rx, seg0 + 2 * n - FF_M + i);
                row[i] = x.r; row[FF_L + i] = x.i;
            }
            row[2 * FF_L] = 1;
            for (int a = 0; a < P; a++) {
                bv[a] += row[a] * t[n];
                for (int c = 0; c < P; c++) A[a * P + c] += row[a] * row[c];
            }
        }
        double tr = 0; for (int a = 0; a < P; a++) tr += A[a * P + a];
        for (int a = 0; a < P; a++) A[a * P + a] += 1e-3 * tr / P;
        double w[2 * FF_L + 1]; memcpy(w, bv, sizeof w);
        double *Ac = malloc(sizeof(double) * P * P); memcpy(Ac, A, sizeof(double) * P * P);
        if (solve(Ac, w, P) == 0) {
            double err = 0;
            for (int n = 0; n < TRAIN_LEN; n++) {
                double y = w[2 * FF_L];
                for (int i = 0; i < FF_L; i++) {
                    cf x = u_at(rx, seg0 + 2 * n - FF_M + i);
                    y += w[i] * x.r + w[FF_L + i] * x.i;
                }
                err += (y - t[n]) * (y - t[n]);
            }
            if (err < best_err) { best_err = err; best_inv = inv; memcpy(best_w, w, sizeof w); }
        }
        free(Ac);
    }
    for (int i = 0; i < FF_L; i++) { rx->wf_r[i] = (float)best_w[i]; rx->wf_i[i] = (float)-best_w[FF_L + i]; }
    rx->cf_ = (float)best_w[2 * FF_L];
    memset(rx->bf, 0, sizeof rx->bf); memset(rx->hbuf, 0, sizeof rx->hbuf); rx->hpos = 0;
    rx->pc = 1; rx->ps = 0; rx->pnorm = 0; rx->rot_upto = INT64_MIN / 2;
    rx->field_parity = best_inv;
    rx->dfe_ready = 1;
    free(A); free(bv);
}

static void backend_reset(atsc_rx *rx) {
    vit_reset(rx);
    for (int i = 0; i < 3; i++) rx->fcount[i] = 0;
    rx->field_emit = 0;
    rx->X_count = 0; rx->m_next = 0; rx->cw_n = 0; rx->pkt_index = 0;
}

// ----------------------------------------------------------------------------- segment processing

// Called when the whole segment starting at u index s0 (plus equalizer look-ahead) is available.
static int seg_frontend(atsc_rx *rx, int64_t s0) {
    // 1. timing: coherent segment-sync correlation at offsets -2..2 around s0
    for (int j = -2; j <= 2; j++) {
        double r = 0, i = 0;
        for (int m = 0; m < 4; m++) { cf x = u_at(rx, s0 + j + 2 * m); r += x.r * SYNC4[m]; i += x.i * SYNC4[m]; }
        rx->seg_acc[j + 2].r += (float)r; rx->seg_acc[j + 2].i += (float)i;
    }
    if (++rx->seg_win == 24) {
        // The phase of the sync correlation at the nominal position rises monotonically with timing
        // offset (about pi/4 per half-symbol; measured, see prototype notes), so it is an
        // unambiguous timing error detector within +-4 half-symbols. Positive phase = grid late.
        double phi = atan2(rx->seg_acc[2].i, rx->seg_acc[2].r);
        double err = atsc_tsign * phi / (M_PI / 4);       // half-symbols
        // one disturbed measurement (a gain step, an impulse) must not throw the loop: the clock
        // moves only ~0.1 half-symbols per update, so cap each correction
        if (err > 1) err = 1; else if (err < -1) err = -1;
        if (atsc_debug) {
            fprintf(stderr, "timing err %+.3f pilot phase rms %.1f deg\n", err,
                    sqrt(rx->pil_err_acc / fmax(rx->pil_err_n, 1)) * 180 / M_PI);
            rx->pil_err_acc = 0; rx->pil_err_n = 0;
        }
        rx->tau -= atsc_tgain * err * rx->step;               // phase correction
        rx->step *= 1 - atsc_fgain * err / (24.0 * HSEG);     // frequency correction
        // A real clock is within a few ppm. If the loop has run away (e.g. after a front-end
        // transient disturbed the phase it measures), reacquire from scratch: ~0.1 s.
        double nominal = rx->fs / (2 * RS_SYM);
        double ppm = (rx->step / nominal - 1) * 1e6;
        if (fabs(ppm) > 20) rx->timing_lost = 1;
        rx->seg_win = 0; memset(rx->seg_acc, 0, sizeof rx->seg_acc);
    }

    // 2. field sync detection: PN511 correlation at this segment
    double pr = 0, pi = 0;
    for (int n = 0; n < 511; n++) { cf x = u_at(rx, s0 + 8 + 2 * n); pr += x.r * rx->pn511[n]; pi += x.i * rx->pn511[n]; }
    double pm = sqrt(pr * pr + pi * pi);
    int is_field = rx->pn_n > 20 && pm > 6 * rx->pn_avg;
    if (!is_field) { rx->pn_avg = rx->pn_n ? 0.98 * rx->pn_avg + 0.02 * pm : pm; rx->pn_n++; }

    if (rx->state == ATSC_ACQ_SEGMENT && rx->pn_n > 64) rx->state = ATSC_ACQ_FIELD;
    // Loss of sync: a gap in the sample stream (e.g. the tuner pausing USB while its gain changes)
    // shifts the whole symbol grid. If no field sync is actually seen for three fields, start over.
    if (is_field) rx->segs_since_field = 0;
    else if (++rx->segs_since_field > 3 * FIELD_SEGS + 8 && rx->state >= ATSC_ACQ_FIELD) {
        rx->timing_lost = 1; rx->resyncs++;
    }
    return is_field;
}


// Thread 2: equalize one segment described by `d`.
static void seg_dfe(atsc_rx *rx, const seg_desc *d) {
    int64_t s0 = d->s0; int is_field = d->is_field;
    if (!rx->dfe_ready) {
        if (!is_field) return;
        dfe_init_ls(rx, s0);
        rx->state = ATSC_LOCKED;
        rx->seg_in_field = 0;
        rx->field_parity ^= 1;          // toggled back below when this field is processed
    }
    if (is_field && rx->seg_in_field != 0) {
        // field sync where none was expected: realign the byte-level back end to this field
        soft_blk *blk = &rx->q2[rx->q2_head % Q2_CAP];
        dispatch_semaphore_wait(rx->q2_space, DISPATCH_TIME_FOREVER);
        blk = &rx->q2[rx->q2_head % Q2_CAP];
        blk->reset = 1; blk->gen = d->gen; blk->s = -1;
        rx->q2_head++; atomic_fetch_add(&rx->q2_pending, 1);
        dispatch_semaphore_signal(rx->q2_items);
    }
    if (rx->seg_in_field == 0 || is_field) {
        // (a missing field sync at the expected position is tolerated: brief fades happen)
        rx->seg_in_field = 0;
        rx->field_parity ^= 1;
        rx->fields++;
        float t[TRAIN_LEN];
        training_seq(rx, rx->field_parity, t);
        rx->train_err = 0; rx->train_n = 0;
        for (int n = 0; n < SEG; n++) dfe_symbol(rx, s0 + 2 * n, n < TRAIN_LEN, n < TRAIN_LEN ? t[n] : 0);
        if (rx->train_n) rx->snr_db = 10 * log10(21.0 / fmax(rx->train_err / rx->train_n, 1e-9));
        // A decision-feedback equalizer that has been knocked off (a gain step, an impulse) can
        // lock onto wrong decisions and never recover. If it measures badly on the known training
        // sequence, solve it again from scratch on this field's training data.
        if (rx->snr_db < 12) { dfe_init_ls(rx, s0); rx->dfe_resets++; }
        rx->seg_in_field = 1;
        return;
    }
    int s = rx->seg_in_field - 1;                // 0..311
    for (int n = 0; n < 4; n++) dfe_symbol(rx, s0 + 2 * n, 1, SYNC4[n]);
    dispatch_semaphore_wait(rx->q2_space, DISPATCH_TIME_FOREVER);
    soft_blk *blk = &rx->q2[rx->q2_head % Q2_CAP];
    for (int j = 0; j < SEGDATA; j++) blk->soft[j] = dfe_symbol(rx, s0 + 2 * (4 + j), 0, 0);
    blk->s = s; blk->reset = 0; blk->gen = d->gen;
    rx->q2_head++; atomic_fetch_add(&rx->q2_pending, 1);
    dispatch_semaphore_signal(rx->q2_items);
    if (++rx->seg_in_field == FIELD_SEGS) rx->seg_in_field = 0;
}

static void *thread2(void *arg) {
    atsc_rx *rx = arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   // keep it on performance cores
    while (1) {
        dispatch_semaphore_wait(rx->q1_items, DISPATCH_TIME_FOREVER);
        if (atomic_load(&rx->quit)) break;
        seg_desc d = rx->q1[rx->q1_tail % Q1_CAP];
        rx->q1_tail++;
        if (d.gen != rx->gen2) {                 // new acquisition: forget equalizer state
            rx->gen2 = d.gen; rx->dfe_ready = 0; rx->seg_in_field = 0; rx->fields = 0; rx->snr_db = 0;
        }
        seg_dfe(rx, &d);
        dispatch_semaphore_signal(rx->q1_space);
        atomic_fetch_sub(&rx->q1_pending, 1);
    }
    return NULL;
}

static void *thread3(void *arg) {
    atsc_rx *rx = arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    while (1) {
        dispatch_semaphore_wait(rx->q2_items, DISPATCH_TIME_FOREVER);
        if (atomic_load(&rx->quit)) break;
        soft_blk *blk = &rx->q2[rx->q2_tail % Q2_CAP];
        if (blk->gen != rx->gen3) { rx->gen3 = blk->gen; backend_reset(rx); rx->rs_good = rx->rs_corr = rx->rs_bad = rx->packets = 0; }
        if (blk->reset) backend_reset(rx);
        else {
            const int *enc = rx->enc_of_pos[blk->s % 3];
            for (int j = 0; j < SEGDATA; j++) vit_symbol(rx, enc[j], blk->soft[j]);
        }
        rx->q2_tail++;
        dispatch_semaphore_signal(rx->q2_space);
        atomic_fetch_sub(&rx->q2_pending, 1);
    }
    return NULL;
}

// ----------------------------------------------------------------------------- u stream

static void push_u(atsc_rx *rx, cf v) {
    double p = v.r * v.r + v.i * v.i;
    // level normalisation: ~0.25 ms time constant, fast enough to absorb a tuner gain step before
    // the equalizer's decisions go wrong, slow enough to be steady on 8VSB's constant power
    rx->u_pow = rx->u_count < 1000 ? (rx->u_pow * rx->u_count + p) / (rx->u_count + 1) : 0.9998 * rx->u_pow + 0.0002 * p;
    float g = (float)(1.0 / sqrt(fmax(rx->u_pow, 1e-12)));
    v.r *= g; v.i *= g;
    rx->u[rx->u_count & (rx->u_cap - 1)] = v;
    rx->u_count++;

    if (rx->state == ATSC_ACQ_SEGMENT && rx->fold_start < 0 && rx->u_count > 20000) {
        rx->fold_start = rx->u_count; memset(rx->fold, 0, HSEG * sizeof(cf)); rx->fold_segs = 0;
    }
    if (rx->state == ATSC_ACQ_SEGMENT && rx->fold_start >= 0 && !rx->seg_next) {
        // coarse segment search: fold the coherent sync correlation over 96 segments
        int64_t k = rx->u_count - 8;          // correlation for a sync starting at k needs u[k..k+6]
        if (k >= rx->fold_start) {
            int p = (int)((k - rx->fold_start) % HSEG);
            double r = 0, i = 0;
            for (int m = 0; m < 4; m++) { cf x = u_at(rx, k + 2 * m); r += x.r * SYNC4[m]; i += x.i * SYNC4[m]; }
            rx->fold[p].r += (float)r; rx->fold[p].i += (float)i;
            if (p == HSEG - 1 && ++rx->fold_segs == 96) {
                int best = 0; float bm = -1;
                for (int q = 0; q < HSEG; q++) {
                    float mg = rx->fold[q].r * rx->fold[q].r + rx->fold[q].i * rx->fold[q].i;
                    if (mg > bm) { bm = mg; best = q; }
                }
                int64_t first = rx->fold_start + best;
                while (first < rx->u_count) first += HSEG;
                rx->seg_next = first;
            }
        }
    }
    // process segments once the segment plus DFE look-ahead is in the ring
    while (rx->seg_next && rx->u_count >= rx->seg_next + HSEG + FF_M + 16) {
        int is_field = seg_frontend(rx, rx->seg_next);
        if (rx->state >= ATSC_ACQ_FIELD) {
            dispatch_semaphore_wait(rx->q1_space, DISPATCH_TIME_FOREVER);
            rx->q1[rx->q1_head % Q1_CAP] = (seg_desc){rx->seg_next, is_field, atomic_load(&rx->gen)};
            rx->q1_head++; atomic_fetch_add(&rx->q1_pending, 1);
            dispatch_semaphore_signal(rx->q1_items);
        }
        rx->seg_next += HSEG;
    }
}

// ----------------------------------------------------------------------------- front end

static void interp_run(atsc_rx *rx) {
    // produce u samples while the interpolator window fits in z
    while (1) {
        double pos = rx->tau - rx->z_base;
        int64_t i0 = (int64_t)floor(pos);
        if (i0 + INTERP_TAPS / 2 + 1 >= (int64_t)rx->z_n) break;
        if (i0 - (INTERP_TAPS / 2 - 1) < 0) { rx->tau = rx->z_base + INTERP_TAPS; continue; }
        double frac = pos - i0;
        int ph = (int)(frac * INTERP_PHASES + 0.5);
        const float *tab = rx->itab[ph];
        float r = 0, i = 0;
        const cf *zp = rx->z + i0 - (INTERP_TAPS / 2 - 1);
        for (int k = 0; k < INTERP_TAPS; k++) { r += zp[k].r * tab[k]; i += zp[k].i * tab[k]; }
        push_u(rx, (cf){r, i});
        rx->tau += rx->step;
    }
    // drop consumed z samples, keeping the interpolator history
    int64_t keep_from = (int64_t)floor(rx->tau - rx->z_base) - INTERP_TAPS;
    if (keep_from > 0 && keep_from < (int64_t)rx->z_n) {
        memmove(rx->z, rx->z + keep_from, (rx->z_n - keep_from) * sizeof(cf));
        rx->z_n -= keep_from; rx->z_base += keep_from;
    }
}

static void mf_block(atsc_rx *rx) {
    // overlap-save: ob holds MF_LEN-1 history + FFT_STEP new samples
    vDSP_DFT_Execute(rx->dft_f, rx->ob_r, rx->ob_i, rx->t1r, rx->t1i);
    DSPSplitComplex X = {rx->t1r, rx->t1i}, H = {rx->H_r, rx->H_i}, Y = {rx->t2r, rx->t2i};
    vDSP_zvmul(&X, 1, &H, 1, &Y, 1, FFT_N, 1);
    vDSP_DFT_Execute(rx->dft_i, rx->t2r, rx->t2i, rx->t1r, rx->t1i);
    if (rx->z_n + FFT_STEP > rx->z_cap) {
        rx->z_cap = (rx->z_n + FFT_STEP) * 2; rx->z = realloc(rx->z, rx->z_cap * sizeof(cf));
    }
    for (int k = 0; k < FFT_STEP; k++) {
        rx->z[rx->z_n + k].r = rx->t1r[MF_LEN - 1 + k];
        rx->z[rx->z_n + k].i = rx->t1i[MF_LEN - 1 + k];
    }
    rx->z_n += FFT_STEP;
    memmove(rx->ob_r, rx->ob_r + FFT_STEP, (MF_LEN - 1) * sizeof(float));
    memmove(rx->ob_i, rx->ob_i + FFT_STEP, (MF_LEN - 1) * sizeof(float));
    rx->ob_fill = MF_LEN - 1;
    interp_run(rx);
}

static void acquire_pilot(atsc_rx *rx) {
    // long FFT of the buffered samples; strongest line within 150 kHz of the hint
    int log2n = 20; size_t n = (size_t)1 << log2n;
    FFTSetup setup = vDSP_create_fftsetup(log2n, kFFTRadix2);
    float *re = malloc(n * sizeof(float)), *im = malloc(n * sizeof(float));
    for (size_t k = 0; k < n; k++) {
        float w = 0.5f - 0.5f * cosf(2 * (float)M_PI * k / n);
        re[k] = rx->acq[k].r * w; im[k] = rx->acq[k].i * w;
    }
    DSPSplitComplex sc = {re, im};
    vDSP_fft_zip(setup, &sc, 1, log2n, FFT_FORWARD);
    double binhz = rx->fs / n;
    int lo = (int)floor((rx->pilot_hint - 150e3) / binhz), hi = (int)ceil((rx->pilot_hint + 150e3) / binhz);
    int best = lo; double bm = -1;
    for (int b = lo; b <= hi; b++) {
        size_t idx = (size_t)((b % (int)n + (int)n) % (int)n);
        double m = re[idx] * re[idx] + im[idx] * im[idx];
        if (m > bm) { bm = m; best = b; }
    }
    double mag[3];
    for (int d = -1; d <= 1; d++) {
        size_t idx = (size_t)(((best + d) % (int)n + (int)n) % (int)n);
        mag[d + 1] = log(re[idx] * re[idx] + im[idx] * im[idx] + 1e-20);
    }
    double off = 0.5 * (mag[0] - mag[2]) / (mag[0] - 2 * mag[1] + mag[2]);
    // how far the pilot stands out: peak over the median bin in the search window
    {
        int nb = hi - lo + 1;
        float *tmp = malloc(sizeof(float) * nb);
        for (int b = lo; b <= hi; b++) {
            size_t idx = (size_t)((b % (int)n + (int)n) % (int)n);
            tmp[b - lo] = re[idx] * re[idx] + im[idx] * im[idx];
        }
        vDSP_vsort(tmp, nb, 1);
        rx->pilot_snr = 10 * log10(bm / fmax(tmp[nb / 2], 1e-20));
        free(tmp);
    }
    double f = (best + off) * binhz;
    rx->nco_f = -2 * M_PI * f / rx->fs;       // NCO rotates by -f
    rx->nco_ph = 0;
    vDSP_destroy_fftsetup(setup);
    free(re); free(im);
    rx->state = ATSC_ACQ_SEGMENT;
    rx->seg_next = 0;
}

void atsc_rx_process(atsc_rx *rx, const int8_t *iq, size_t n) {
    if (atomic_exchange(&rx->reset_req, 0)) frontend_reset(rx, rx->reset_hint);
    if (rx->timing_lost) {
        // keep the known pilot frequency as the hint so reacquisition is quick
        double hint = rx->state >= ATSC_ACQ_SEGMENT ? -rx->nco_f * rx->fs / (2 * M_PI) : rx->pilot_hint;
        frontend_reset(rx, hint);
    }
    // input level
    double pw = 0;
    for (size_t k = 0; k < 2 * n; k++) pw += (double)iq[k] * iq[k];
    if (n) rx->dbfs = 10 * log10(fmax(pw / n, 1e-9)) - 20 * log10(128);

    size_t k = 0;
    if (rx->state == ATSC_ACQ_PILOT) {
        for (; k < n && rx->acq_n < rx->acq_cap; k++, rx->acq_n++) {
            rx->acq[rx->acq_n].r = iq[2 * k]; rx->acq[rx->acq_n].i = iq[2 * k + 1];
        }
        if (rx->acq_n < rx->acq_cap) return;
        acquire_pilot(rx);
    }
    // NCO mix (pilot -> DC) with slow phase tracking, then matched filter
    double ph = rx->nco_ph, df = rx->nco_f;
    double cr = cos(ph), ci = sin(ph), dr = cos(df), di = sin(df);
    for (; k < n; k++) {
        float xr = iq[2 * k], xi = iq[2 * k + 1];
        float yr = (float)(xr * cr - xi * ci), yi = (float)(xr * ci + xi * cr);
        double t = cr * dr - ci * di; ci = cr * di + ci * dr; cr = t;
        // pilot tracking: average over 200 samples, lowpass, nudge phase and frequency
        rx->pil_acc_r += yr; rx->pil_acc_i += yi;
        if (++rx->pil_cnt == 200) {
            // second-order pilot PLL, ~50 Hz bandwidth, updated every 200 samples (100 kHz).
            // The 200-sample mean is the pilot plus leaked data; a light IIR smooths the latter.
            rx->pil_r = 0.7 * rx->pil_r + 0.3 * rx->pil_acc_r;
            rx->pil_i = 0.7 * rx->pil_i + 0.3 * rx->pil_acc_i;
            rx->pil_acc_r = rx->pil_acc_i = 0; rx->pil_cnt = 0;
            double err = atan2(rx->pil_i, rx->pil_r);
            rx->pil_err_acc += err * err; rx->pil_err_n++;
            double rot = -atsc_pkp * err;
            double nr = cos(rot), ni = sin(rot);
            double t2 = cr * nr - ci * ni; ci = cr * ni + ci * nr; cr = t2;
            df -= atsc_pki * err;
            dr = cos(df); di = sin(df);
            double mag = sqrt(cr * cr + ci * ci); cr /= mag; ci /= mag;
        }
        rx->ob_r[rx->ob_fill] = yr; rx->ob_i[rx->ob_fill] = yi;
        if (++rx->ob_fill == FFT_N) mf_block(rx);
    }
    rx->nco_ph = atan2(ci, cr); rx->nco_f = df;
}
