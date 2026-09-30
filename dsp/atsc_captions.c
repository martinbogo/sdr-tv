// CEA-608 and CEA-708 closed caption decoders. See atsc_captions.h.
#include "atsc_captions.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ----------------------------------------------------------------------------- shared output

typedef struct { char *buf; int len, cap; } sbuf;

static void sb_put(sbuf *s, const char *t, int n) {
    if (s->len + n + 1 > s->cap) { s->cap = (s->len + n + 1) * 2; s->buf = realloc(s->buf, s->cap); }
    memcpy(s->buf + s->len, t, n); s->len += n; s->buf[s->len] = 0;
}
static void sb_str(sbuf *s, const char *t) { sb_put(s, t, (int)strlen(t)); }

static void sb_json_text(sbuf *s, const uint32_t *cps, int n) {
    sb_str(s, "\"");
    for (int i = 0; i < n; i++) {
        uint32_t c = cps[i];
        char b[8]; int k = 0;
        if (c == '"' || c == '\\') { b[k++] = '\\'; b[k++] = (char)c; }
        else if (c < 0x20) continue;
        else if (c < 0x80) b[k++] = (char)c;
        else if (c < 0x800) { b[k++] = (char)(0xC0 | (c >> 6)); b[k++] = (char)(0x80 | (c & 0x3F)); }
        else { b[k++] = (char)(0xE0 | (c >> 12)); b[k++] = (char)(0x80 | ((c >> 6) & 0x3F)); b[k++] = (char)(0x80 | (c & 0x3F)); }
        sb_put(s, b, k);
    }
    sb_str(s, "\"");
}

// ----------------------------------------------------------------------------- CEA-608

#define R608 15
#define C608 32

typedef struct {
    uint32_t ch[R608][C608];          // 0 = empty cell
    uint8_t italic[R608][C608];
} screen608;

typedef struct {
    screen608 disp, nondisp;
    int mode;                         // 0 pop-on, 1 roll-up, 2 paint-on
    int rollup_rows;
    int row, col;                     // cursor
    int italic;
    uint8_t last_b1, last_b2;         // for dropping repeated control codes
    int active;                       // this data channel is the selected one
    int cur_channel;                  // data channel of the last control code (1 or 2)
} dec608;

static const uint32_t basic_sub[128] = {
    [0x2A] = 0xE1, [0x5C] = 0xE9, [0x5E] = 0xED, [0x5F] = 0xF3, [0x60] = 0xFA,
    [0x7B] = 0xE7, [0x7C] = 0xF7, [0x7D] = 0xD1, [0x7E] = 0xF1, [0x7F] = 0x25A0,
};
static const uint32_t special608[16] = {
    0xAE, 0xB0, 0xBD, 0xBF, 0x2122, 0xA2, 0xA3, 0x266A, 0xE0, 0x20, 0xE8, 0xE2, 0xEA, 0xEE, 0xF4, 0xFB};
static const uint32_t ext608_12[32] = {  // Spanish, misc., French (b1 0x12)
    0xC1, 0xC9, 0xD3, 0xDA, 0xDC, 0xFC, 0x2018, 0xA1, '*', '\'', 0x2014, 0xA9, 0x2120, 0x2022, 0x201C, 0x201D,
    0xC0, 0xC2, 0xC7, 0xC8, 0xCA, 0xCB, 0xEB, 0xCE, 0xCF, 0xEF, 0xD4, 0xD9, 0xF9, 0xDB, 0xAB, 0xBB};
static const uint32_t ext608_13[32] = {  // Portuguese, German, Danish (b1 0x13)
    0xC3, 0xE3, 0xCD, 0xCC, 0xEC, 0xD2, 0xF2, 0xD5, 0xF5, '{', '}', '\\', '^', '_', '|', '~',
    0xC4, 0xE4, 0xD6, 0xF6, 0xDF, 0xA5, 0xA4, 0x2502, 0xC5, 0xE5, 0xD8, 0xF8, 0x250C, 0x2510, 0x2514, 0x2518};
// Preamble address code rows (0-based) by b1 (channel-1 form, low nibble): 0x10 row 11 only,
// 0x11 rows 1/2, 0x12 3/4, 0x13 12/13, 0x14 14/15, 0x15 5/6, 0x16 7/8, 0x17 9/10; b2 bit 0x20
// selects the second row of the pair.
static const int pac_row[8] = {10, 0, 2, 11, 13, 4, 6, 8};

static screen608 *target608(dec608 *d) { return d->mode == 0 ? &d->nondisp : &d->disp; }

static void put608(dec608 *d, uint32_t c) {
    if (d->col >= C608) d->col = C608 - 1;
    screen608 *s = target608(d);
    s->ch[d->row][d->col] = c;
    s->italic[d->row][d->col] = (uint8_t)d->italic;
    if (d->col < C608 - 1) d->col++;
}

static void rollup608(dec608 *d) {
    int base = d->row, top = base - d->rollup_rows + 1;
    if (top < 0) top = 0;
    for (int r = 0; r < R608; r++) {
        if (r < top || r > base) { memset(d->disp.ch[r], 0, sizeof d->disp.ch[r]); continue; }
    }
    for (int r = top; r < base; r++) {
        memcpy(d->disp.ch[r], d->disp.ch[r + 1], sizeof d->disp.ch[r]);
        memcpy(d->disp.italic[r], d->disp.italic[r + 1], sizeof d->disp.italic[r]);
    }
    memset(d->disp.ch[base], 0, sizeof d->disp.ch[base]);
    d->col = 0;
}

static void emit608(cc_decoder *cd);

// returns 1 if the displayed screen may have changed
static int cmd608(dec608 *d, int b1, int b2) {
    int f = b1 & 0x0F;                       // 0x14/0x15 (ch1) or after -8 for ch2 -> same
    if ((f == 0x04 || f == 0x05) && b2 >= 0x20 && b2 <= 0x2F) {
        switch (b2) {
        case 0x20: d->mode = 0; return 0;                                      // RCL
        case 0x21: if (d->col > 0) { d->col--; target608(d)->ch[d->row][d->col] = 0; } return d->mode != 0;  // BS
        case 0x24: for (int c = d->col; c < C608; c++) target608(d)->ch[d->row][c] = 0; return d->mode != 0; // DER
        case 0x25: case 0x26: case 0x27:                                       // RU2..RU4
            if (d->mode != 1) { memset(&d->disp, 0, sizeof d->disp); memset(&d->nondisp, 0, sizeof d->nondisp); }
            d->mode = 1; d->rollup_rows = b2 - 0x23; if (d->row < d->rollup_rows - 1) d->row = R608 - 1; d->col = 0;
            return 1;
        case 0x29: d->mode = 2; return 0;                                      // RDC
        case 0x2C: memset(&d->disp, 0, sizeof d->disp); return 1;              // EDM
        case 0x2D: if (d->mode == 1) { rollup608(d); return 1; } return 0;     // CR
        case 0x2E: memset(&d->nondisp, 0, sizeof d->nondisp); return 0;        // ENM
        case 0x2F: { screen608 t = d->disp; d->disp = d->nondisp; d->nondisp = t; d->mode = 0; return 1; } // EOC
        default: return 0;
        }
    }
    if (f == 0x07 && b2 >= 0x21 && b2 <= 0x23) { d->col += b2 - 0x20; if (d->col >= C608) d->col = C608 - 1; return 0; } // TO1..3
    return 0;
}

static int pair608(dec608 *d, int b1, int b2) {
    if (b1 >= 0x10 && b1 <= 0x1F) {
        int ch = b1 >= 0x18 ? 2 : 1;
        int n1 = b1 & ~0x08;                          // channel 1 form
        d->cur_channel = ch;
        if (!d->active) return 0;
        if (b1 == d->last_b1 && b2 == d->last_b2) { d->last_b1 = 0; return 0; }   // redundant repeat
        d->last_b1 = (uint8_t)b1; d->last_b2 = (uint8_t)b2;
        if (b2 >= 0x40) {                               // preamble address code
            int r = pac_row[n1 & 0x07];
            if ((n1 & 0x07) == 0 && (b2 & 0x20)) return 0;      // 0x10 has only one row
            r += (n1 & 0x07) && (b2 & 0x20) ? 1 : 0;
            if (d->mode == 1 && r != d->row) {          // roll-up base row moved: move the text with it
                int shift = r - d->row;
                screen608 t; memset(&t, 0, sizeof t);
                for (int rr = 0; rr < R608; rr++) {
                    int nr = rr + shift;
                    if (nr >= 0 && nr < R608) { memcpy(t.ch[nr], d->disp.ch[rr], sizeof t.ch[nr]); memcpy(t.italic[nr], d->disp.italic[rr], sizeof t.italic[nr]); }
                }
                d->disp = t;
            }
            d->row = r;
            int low = b2 & 0x1F;
            if (low >= 0x10) { d->col = ((low & 0x0E) >> 1) * 4; d->italic = 0; }
            else { d->col = 0; d->italic = (low & 0x0E) == 0x0E; }
            return 0;
        }
        if (n1 == 0x11 && b2 >= 0x20 && b2 <= 0x2F) {  // mid-row: attribute change, shown as a space
            d->italic = (b2 & 0x0E) == 0x0E; put608(d, ' ');
            return d->mode != 0;
        }
        if (n1 == 0x11 && b2 >= 0x30 && b2 <= 0x3F) { put608(d, special608[b2 - 0x30]); return d->mode != 0; }
        if ((n1 == 0x12 || n1 == 0x13) && b2 >= 0x20 && b2 <= 0x3F) {   // extended: replaces the previous char
            if (d->col > 0) d->col--;
            put608(d, n1 == 0x12 ? ext608_12[b2 - 0x20] : ext608_13[b2 - 0x20]);
            return d->mode != 0;
        }
        return cmd608(d, n1, b2);
    }
    if (b1 < 0x10) return 0;                            // XDS or padding
    if (!d->active) return 0;
    d->last_b1 = 0;
    int changed = 0;
    for (int k = 0; k < 2; k++) {
        int b = k ? b2 : b1;
        if (b < 0x20) continue;
        put608(d, basic_sub[b] ? basic_sub[b] : (uint32_t)b);
        changed = 1;
    }
    return changed && d->mode != 0;
}

// ----------------------------------------------------------------------------- CEA-708

#define MAXR708 15
#define MAXC708 42

typedef struct {
    int defined, visible, priority;
    int rel, av, ah, anchor, rows, cols;
    int prow, pcol;
    uint32_t text[MAXR708][MAXC708];
} win708;

typedef struct {
    win708 w[8];
    int cur;
    uint8_t pkt[130]; int pkt_len, pkt_need;
} dec708;

static void clear_win(win708 *w) { memset(w->text, 0, sizeof w->text); w->prow = w->pcol = 0; }

static void put708(win708 *w, uint32_t c) {
    if (!w->defined) return;
    if (w->pcol >= w->cols) {
        if (w->pcol >= MAXC708) return;
    }
    if (w->prow < MAXR708 && w->pcol < MAXC708) w->text[w->prow][w->pcol] = c;
    w->pcol++;
}

static void cr708(win708 *w) {
    w->pcol = 0;
    if (w->prow + 1 < w->rows) { w->prow++; return; }
    // last row: scroll the window up
    for (int r = 0; r + 1 < w->rows && r + 1 < MAXR708; r++) memcpy(w->text[r], w->text[r + 1], sizeof w->text[r]);
    if (w->rows - 1 < MAXR708) memset(w->text[w->rows - 1], 0, sizeof w->text[0]);
}

static uint32_t g2_char(int b) {
    switch (b) {
    case 0x20: case 0x21: return ' '; case 0x25: return 0x2026; case 0x2A: return 0x160; case 0x2C: return 0x152;
    case 0x30: return 0x2588; case 0x31: return 0x2018; case 0x32: return 0x2019; case 0x33: return 0x201C;
    case 0x34: return 0x201D; case 0x35: return 0x2022; case 0x39: return 0x2122; case 0x3A: return 0x161;
    case 0x3C: return 0x153; case 0x3D: return 0x2120; case 0x3F: return 0x178; case 0x76: return 0x215B;
    case 0x77: return 0x215C; case 0x78: return 0x215D; case 0x79: return 0x215E; case 0x7A: return 0x2502;
    case 0x7B: return 0x2510; case 0x7C: return 0x2514; case 0x7D: return 0x2500; case 0x7E: return 0x2518;
    case 0x7F: return 0x250C;
    default: return 0;
    }
}

// Decode one service block of the selected service; returns 1 if visible content may have changed.
static int service708(dec708 *d, const uint8_t *p, int n) {
    int changed = 0;
    int i = 0;
    while (i < n) {
        int c = p[i++];
        win708 *w = &d->w[d->cur];
        if (c == 0x10) {                                   // EXT1: extended code sets
            if (i >= n) break;
            int e = p[i++];
            if (e < 0x08) {}
            else if (e < 0x10) i += 1;
            else if (e < 0x18) i += 2;
            else if (e < 0x20) i += 3;
            else if (e < 0x80) { uint32_t ch = g2_char(e); if (ch) { put708(w, ch); changed |= w->visible; } }
            else if (e < 0x88) i += 4;
            else if (e < 0x90) i += 5;
            else if (e < 0xA0) { if (i < n) i += 1 + (p[i] & 0x1F); }
            else { if (e == 0xA0) { put708(w, 0x1F4AC); changed |= w->visible; } }   // [CC] icon (approximation)
            continue;
        }
        if (c < 0x20) {                                    // C0
            if (c == 0x08) { if (w->pcol > 0) { w->pcol--; if (w->prow < MAXR708) w->text[w->prow][w->pcol] = 0; changed |= w->visible; } }
            else if (c == 0x0C) { clear_win(w); changed |= w->visible; }
            else if (c == 0x0D) { cr708(w); changed |= w->visible; }
            else if (c == 0x0E) { w->pcol = 0; if (w->prow < MAXR708) memset(w->text[w->prow], 0, sizeof w->text[0]); changed |= w->visible; }
            else if (c >= 0x11 && c <= 0x17) i += 1;
            else if (c >= 0x18) i += 2;
            continue;
        }
        if (c < 0x80) { put708(w, c == 0x7F ? 0x266A : (uint32_t)c); changed |= w->visible; continue; }   // G0
        if (c >= 0xA0) { put708(w, (uint32_t)c); changed |= w->visible; continue; }                       // G1 (Latin-1)
        // C1 commands
        if (c <= 0x87) { d->cur = c - 0x80; continue; }                                                  // CWx
        if (c >= 0x88 && c <= 0x8C) {
            if (i >= n) break;
            int map = p[i++];
            for (int k = 0; k < 8; k++) {
                if (!(map & (1 << k))) continue;
                win708 *x = &d->w[k];
                if (c == 0x88) clear_win(x);
                else if (c == 0x89) x->visible = 1;
                else if (c == 0x8A) x->visible = 0;
                else if (c == 0x8B) x->visible = !x->visible;
                else if (c == 0x8C) { memset(x, 0, sizeof *x); }
            }
            changed = 1;
            continue;
        }
        if (c == 0x8D) { i += 1; continue; }                                     // DLY (not modelled)
        if (c == 0x8E) continue;                                                 // DLC
        if (c == 0x8F) { memset(d->w, 0, sizeof d->w); d->cur = 0; changed = 1; continue; }   // RST
        if (c == 0x90) { i += 2; continue; }                                     // SPA
        if (c == 0x91) { i += 3; continue; }                                     // SPC
        if (c == 0x92) {                                                         // SPL
            if (i + 2 > n) break;
            w->prow = p[i] & 0x0F; w->pcol = p[i + 1] & 0x3F;
            if (w->prow >= MAXR708) w->prow = MAXR708 - 1;
            i += 2; continue;
        }
        if (c == 0x97) { i += 4; continue; }                                     // SWA
        if (c >= 0x98) {                                                         // DFx define window
            if (i + 6 > n) break;
            win708 *x = &d->w[c - 0x98];
            int was = x->defined;
            x->defined = 1;
            x->visible = (p[i] >> 5) & 1;
            x->priority = p[i] & 0x07;
            x->rel = (p[i + 1] >> 7) & 1;
            x->av = p[i + 1] & 0x7F;
            x->ah = p[i + 2];
            x->anchor = (p[i + 3] >> 4) & 0x0F;
            x->rows = (p[i + 3] & 0x0F) + 1;
            x->cols = (p[i + 4] & 0x3F) + 1;
            if (x->rows > MAXR708) x->rows = MAXR708;
            if (!was) clear_win(x);
            d->cur = c - 0x98;
            i += 6;
            changed = 1;
            continue;
        }
    }
    return changed;
}

// ----------------------------------------------------------------------------- decoder

struct cc_decoder {
    int service;
    cc_screen_cb cb; void *ctx;
    dec608 d608;
    dec708 d708;
    char *last;
};

static void emit_json(cc_decoder *cd, sbuf *s) {
    if (cd->last && !strcmp(cd->last, s->buf)) { free(s->buf); return; }
    free(cd->last); cd->last = s->buf;
    if (cd->cb) cd->cb(cd->ctx, s->buf);
}

static void emit608(cc_decoder *cd) {
    sbuf s = {0};
    sb_str(&s, "{\"regions\":[");
    int first = 1;
    for (int r = 0; r < R608; r++) {
        int c0 = -1, c1 = -1;
        for (int c = 0; c < C608; c++) if (cd->d608.disp.ch[r][c] && cd->d608.disp.ch[r][c] != ' ') { if (c0 < 0) c0 = c; c1 = c; }
        if (c0 < 0) continue;
        uint32_t line[C608]; int n = 0;
        for (int c = c0; c <= c1; c++) line[n++] = cd->d608.disp.ch[r][c] ? cd->d608.disp.ch[r][c] : ' ';
        char head[96];
        snprintf(head, sizeof head, "%s{\"x\":%.4f,\"y\":%.4f,\"anchor\":0,\"grid\":1,\"lines\":[", first ? "" : ",",
                 c0 / (double)C608, r / (double)R608);
        sb_str(&s, head);
        sb_json_text(&s, line, n);
        sb_str(&s, "]}");
        first = 0;
    }
    sb_str(&s, "]}");
    emit_json(cd, &s);
}

static void emit708(cc_decoder *cd) {
    sbuf s = {0};
    sb_str(&s, "{\"regions\":[");
    int first = 1;
    for (int pr = 7; pr >= 0; pr--) {                   // low priority first; the app draws in order
        for (int k = 0; k < 8; k++) {
            win708 *w = &cd->d708.w[k];
            if (!w->defined || !w->visible || w->priority != pr) continue;
            int any = 0;
            for (int r = 0; r < w->rows && !any; r++) for (int c = 0; c < MAXC708; c++) if (w->text[r][c] && w->text[r][c] != ' ') { any = 1; break; }
            if (!any) continue;
            double x = w->rel ? w->ah / 99.0 : w->ah / 209.0;
            double y = w->rel ? w->av / 99.0 : w->av / 74.0;
            if (x > 1) x = 1; if (y > 1) y = 1;
            char head[128];
            snprintf(head, sizeof head, "%s{\"x\":%.4f,\"y\":%.4f,\"anchor\":%d,\"lines\":[", first ? "" : ",", x, y, w->anchor > 8 ? 0 : w->anchor);
            sb_str(&s, head);
            int fl = 1;
            for (int r = 0; r < w->rows; r++) {
                int c1 = -1;
                for (int c = 0; c < MAXC708; c++) if (w->text[r][c] && w->text[r][c] != ' ') c1 = c;
                uint32_t line[MAXC708]; int n = 0;
                for (int c = 0; c <= c1; c++) line[n++] = w->text[r][c] ? w->text[r][c] : ' ';
                if (!fl) sb_str(&s, ",");
                sb_json_text(&s, line, n);
                fl = 0;
            }
            sb_str(&s, "]}");
            first = 0;
        }
    }
    sb_str(&s, "]}");
    emit_json(cd, &s);
}

cc_decoder *cc_create(int service, cc_screen_cb cb, void *ctx) {
    cc_decoder *d = calloc(1, sizeof *d);
    d->service = service; d->cb = cb; d->ctx = ctx;
    cc_reset(d);
    return d;
}

void cc_destroy(cc_decoder *d) { if (d) { free(d->last); free(d); } }

void cc_reset(cc_decoder *d) {
    memset(&d->d608, 0, sizeof d->d608);
    d->d608.row = R608 - 1; d->d608.rollup_rows = 3;
    memset(&d->d708, 0, sizeof d->d708);
    free(d->last); d->last = NULL;
    if (d->cb) d->cb(d->ctx, "{\"regions\":[]}");
}

static int parity_ok(int b) { b ^= b >> 4; b ^= b >> 2; b ^= b >> 1; return b & 1; }

static void dtvcc_packet(cc_decoder *cd) {
    dec708 *d = &cd->d708;
    int want = cd->service - 100;
    int i = 1, changed = 0;
    while (i < d->pkt_len) {
        int svc = d->pkt[i] >> 5, size = d->pkt[i] & 0x1F;
        i++;
        if (svc == 0 && size == 0) break;                 // null block ends the packet
        if (svc == 7) { if (i >= d->pkt_len) break; svc = d->pkt[i++] & 0x3F; }
        if (i + size > d->pkt_len) break;
        if (svc == want) changed |= service708(d, d->pkt + i, size);
        i += size;
    }
    if (changed) emit708(cd);
}

void cc_feed(cc_decoder *cd, const uint8_t *t, int n) {
    if (!cd || cd->service == 0) return;
    for (int k = 0; k < n; k++) {
        int flags = t[3 * k], b1 = t[3 * k + 1], b2 = t[3 * k + 2];
        int valid = (flags >> 2) & 1, type = flags & 3;
        if (cd->service <= 4) {
            // 608: type 0 = field 1 (CC1, CC2), type 1 = field 2 (CC3, CC4)
            if (!valid || type > 1) continue;
            int field = type + 1, want_field = cd->service <= 2 ? 1 : 2, want_ch = (cd->service - 1) % 2 + 1;
            if (field != want_field) continue;
            if (!parity_ok(b1) || !parity_ok(b2)) continue;
            b1 &= 0x7F; b2 &= 0x7F;
            if (b1 == 0 && b2 == 0) continue;
            dec608 *d = &cd->d608;
            if (b1 >= 0x10 && b1 <= 0x1F) d->active = ((b1 >= 0x18) ? 2 : 1) == want_ch;
            if (pair608(d, b1, b2)) emit608(cd);
        } else {
            // 708: type 3 starts a DTVCC packet, type 2 continues it
            dec708 *d = &cd->d708;
            if (type == 3) {
                if (d->pkt_len > 0 && d->pkt_len >= d->pkt_need) dtvcc_packet(cd);
                if (!valid) { d->pkt_len = 0; continue; }
                int code = b1 & 0x3F;
                d->pkt_need = code == 0 ? 128 : code * 2;
                d->pkt[0] = (uint8_t)b1; d->pkt[1] = (uint8_t)b2; d->pkt_len = 2;
            } else if (type == 2 && valid && d->pkt_len > 0 && d->pkt_len + 2 <= (int)sizeof d->pkt) {
                d->pkt[d->pkt_len++] = (uint8_t)b1; d->pkt[d->pkt_len++] = (uint8_t)b2;
            }
            if (d->pkt_len > 0 && d->pkt_len >= d->pkt_need) { dtvcc_packet(cd); d->pkt_len = 0; }
        }
    }
}
