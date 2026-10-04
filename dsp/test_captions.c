// Caption decoder checks: synthetic CEA-708 and CEA-608 data in, styled JSON out.
//   test_captions   (exit status 0 when all pass)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "atsc_captions.h"

static char last[8192];
static void on_screen(void *c, const char *json) { (void)c; snprintf(last, sizeof last, "%s", json); }
static int failures;
static void check(int ok, const char *what) { printf("  %s  %s\n", ok ? "ok   " : "FAIL ", what); if (!ok) failures++; }

/// One DTVCC packet carrying one service-1 block, as cc_data triplets (type 3 start, type 2 rest).
static void feed708(cc_decoder *d, const unsigned char *block, int n) {
    unsigned char pkt[128]; int len = 0;
    int size = n + 1;                                   // service header + block
    int total = 1 + size; if (total & 1) total++;       // packets are whole byte pairs
    pkt[len++] = (unsigned char)(total / 2);            // sequence 0, size code
    pkt[len++] = (unsigned char)(1 << 5 | n);           // service 1, block size
    memcpy(pkt + len, block, n); len += n;
    while (len < total) pkt[len++] = 0;
    unsigned char t[3 * 64]; int k = 0;
    for (int i = 0; i < len; i += 2) { t[3 * k] = (unsigned char)(0xF8 | (i ? 6 : 7)); t[3 * k + 1] = pkt[i]; t[3 * k + 2] = pkt[i + 1]; k++; }
    cc_feed(d, t, k);
    unsigned char end[3] = {0xFF, 0, 0};                // next packet start flushes this one
    cc_feed(d, end, 1);
}

static int parity(int b) { int p = b ^ (b >> 4); p ^= p >> 2; p ^= p >> 1; return (p & 1) ? b : (b | 0x80); }
static void feed608(cc_decoder *d, int b1, int b2) {
    unsigned char t[3] = {0xFC, (unsigned char)parity(b1), (unsigned char)parity(b2)};
    cc_feed(d, t, 1);
}

int main(void) {
    printf("CEA-708\n");
    cc_decoder *d = cc_create(101, on_screen, NULL);
    const unsigned char block[] = {
        0x98, 0x20, 0x4A, 0x40, 0x61, 0x1F, 0x09,       // DF0: visible, anchor bottom-centre, 2 rows, 32 cols, styles 1/1
        0x97, 0x0C, 0x00, 0x02, 0x00,                   // SWA: green fill, solid; centred
        0x91, 0x30, 0x00, 0x00,                         // SPC: red text, black background
        0x90, 0x01, 0x80,                               // SPA: standard size, italic
        'H', 'I',
    };
    feed708(d, block, sizeof block);
    check(strstr(last, "\"t\":\"HI\"") != NULL, "text decoded");
    check(strstr(last, "\"fg\":\"#FF0000\"") != NULL, "pen colour: red text");
    check(strstr(last, "\"i\":1") != NULL, "pen attribute: italic");
    check(strstr(last, "\"fill\":\"#00FF00\"") != NULL && strstr(last, "\"justify\":2") != NULL, "window fill and centring");
    cc_destroy(d);

    printf("CEA-608\n");
    d = cc_create(1, on_screen, NULL);
    feed608(d, 0x14, 0x20);                             // RCL: pop-on
    feed608(d, 0x14, 0x4B);                             // PAC row 15, yellow, underlined
    feed608(d, 'O', 'K');
    feed608(d, 0x14, 0x2F);                             // EOC: show
    check(strstr(last, "\"t\":\"OK\"") != NULL, "text decoded");
    check(strstr(last, "\"fg\":\"#FFFF00\"") != NULL && strstr(last, "\"u\":1") != NULL, "preamble: yellow, underlined");
    cc_destroy(d);

    printf(failures ? "captions: %d failed\n" : "captions: all passed\n", failures);
    return failures != 0;
}
