// ATSC transport stream demultiplexer, PSIP parser (A/65) and decoder (FFmpeg: MPEG-2, AC-3).
#include "atsc_media.h"
#include "atsc_captions.h"

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_PIDS 8192
#define MAX_CH 64
#define GPS_EPOCH_UNIX 315964800LL       // 1980-01-06 00:00:00 UTC

typedef struct {
    uint8_t buf[4096 + 188];
    int len, need;                        // bytes collected, total section length (0 = unknown)
    int active;
} section_buf;

typedef struct {
    uint8_t *buf; int len, cap;
    int64_t pts;
    int started;
} pes_buf;

struct atsc_media {
    atsc_media_cb cb;

    // PSI / PSIP
    section_buf *sec[MAX_PIDS];           // allocated on demand for table PIDs
    uint8_t is_table[MAX_PIDS];           // 1 PAT, 2 PMT, 3 PSIP base, 4 EIT, 5 ETT
    int pmt_pid_of_program[65536 / 8];    // small map: program -> pmt pid (index by program & mask)
    int prog_list[MAX_CH], prog_pmt[MAX_CH], nprog;
    int pat_version, tvct_version;
    atsc_vchannel ch[MAX_CH]; int nch;
    int gps_utc_offset; int have_offset;
    // guide completeness: distinct EIT sections seen (pid, source, section, version)
    uint64_t eit_seen[4096]; int eit_count;
    uint64_t pkts, eit_new_at;            // packet counter, and its value when the last new section came

    // selected program
    int want_program, cur_program;
    int video_pid, audio_pid, video_type, audio_type;
    int want_audio, cur_pmt;
    cc_decoder *cc; int cc_service; int64_t cc_pts;
    uint64_t v_frames, a_frames;
    pes_buf vpes, apes;

    // FFmpeg
    AVCodecParserContext *vparser, *aparser;
    AVCodecContext *vdec, *adec;
    AVFrame *frame, *filt;
    AVPacket *pkt;
    AVFilterGraph *graph; AVFilterContext *src, *sink;
    int g_w, g_h, g_fmt, g_sn, g_sd;
    SwrContext *swr; int swr_in_ch, swr_rate, swr_fmt;
    float *abuf; int abuf_cap;
    int fmt_w, fmt_h, fmt_i, fmt_ach;
    int64_t a_next_pts, v_next_pts, v_frame_dur;

    uint64_t dropped;
    // dropouts: continuity counters of the decoded streams, and what a gap does to the output
    int v_cc, a_cc;                       // last continuity counter seen (-1: none yet)
    int v_wait_key;                       // a gap hit the video: hold the picture until a clean keyframe
    int64_t v_wait_from;                  // pts of the first frame held back
    int a_skip;                           // audio frames still to drop after a gap
    uint64_t v_held, gaps;                // frames held back, gaps seen (diagnostics)
};

// ----------------------------------------------------------------------------- utilities

static uint32_t crc32_mpeg(const uint8_t *d, int n) {
    uint32_t c = 0xFFFFFFFF;
    for (int i = 0; i < n; i++) {
        c ^= (uint32_t)d[i] << 24;
        for (int b = 0; b < 8; b++) c = (c & 0x80000000) ? (c << 1) ^ 0x04C11DB7 : c << 1;
    }
    return c;
}

static void utf8_put(char **o, char *end, uint32_t cp) {
    if (cp < 0x80) { if (*o < end) *(*o)++ = (char)cp; }
    else if (cp < 0x800) { if (*o + 1 < end) { *(*o)++ = (char)(0xC0 | (cp >> 6)); *(*o)++ = (char)(0x80 | (cp & 0x3F)); } }
    else { if (*o + 2 < end) { *(*o)++ = (char)(0xE0 | (cp >> 12)); *(*o)++ = (char)(0x80 | ((cp >> 6) & 0x3F)); *(*o)++ = (char)(0x80 | (cp & 0x3F)); } }
}

// A/65 multiple_string_structure -> first string, UTF-8. Uncompressed segments only
// (compression type 0); Huffman-coded segments are skipped.
static void mss_to_utf8(const uint8_t *p, int len, char *out, int cap) {
    char *o = out, *end = out + cap - 1;
    if (len < 1) { *o = 0; return; }
    int nstr = p[0]; int i = 1;
    for (int s = 0; s < nstr && s < 1; s++) {
        if (i + 4 > len) break;
        int nseg = p[i + 3]; i += 4;
        for (int g = 0; g < nseg; g++) {
            if (i + 3 > len) break;
            int comp = p[i], mode = p[i + 1], nb = p[i + 2]; i += 3;
            if (i + nb > len) break;
            if (comp == 0) {
                if (mode == 0x3F) {                         // UTF-16
                    for (int k = 0; k + 1 < nb; k += 2) utf8_put(&o, end, (uint32_t)p[i + k] << 8 | p[i + k + 1]);
                } else if (mode <= 0x06 || (mode >= 0x09 && mode <= 0x10) || (mode >= 0x20 && mode <= 0x27) || (mode >= 0x30 && mode <= 0x33)) {
                    for (int k = 0; k < nb; k++) utf8_put(&o, end, ((uint32_t)mode << 8) | p[i + k]);
                }
            }
            i += nb;
        }
    }
    *o = 0;
}

// ----------------------------------------------------------------------------- tables

static void set_table_pid(atsc_media *m, int pid, int kind) {
    if (pid < 0 || pid >= MAX_PIDS) return;
    if (!m->sec[pid]) m->sec[pid] = calloc(1, sizeof(section_buf));
    m->is_table[pid] = (uint8_t)kind;
}

static void select_streams(atsc_media *m);

static void parse_pat(atsc_media *m, const uint8_t *s, int len) {
    int ver = (s[5] >> 1) & 0x1F;
    if (ver == m->pat_version) return;
    m->pat_version = ver;
    m->nprog = 0;
    for (int i = 8; i + 4 <= len - 4; i += 4) {
        int prog = s[i] << 8 | s[i + 1];
        int pid = (s[i + 2] & 0x1F) << 8 | s[i + 3];
        if (prog == 0) continue;               // network PID
        if (m->nprog < MAX_CH) { m->prog_list[m->nprog] = prog; m->prog_pmt[m->nprog] = pid; m->nprog++; }
        set_table_pid(m, pid, 2);
    }
    select_streams(m);
}

#define MAX_AUD 8
#define MAX_CCS 16
typedef struct {
    int prog, video, audio, vtype, atype;
    atsc_audio_track aud[MAX_AUD]; int naud;
    atsc_caption_service ccs[MAX_CCS]; int nccs;
} pmt_info;
static pmt_info pmts[MAX_CH]; static int npmt;       // per-media would be cleaner; one instance in practice

static void parse_pmt(atsc_media *m, const uint8_t *s, int len) {
    int prog = s[3] << 8 | s[4];
    int pinfo = (s[10] & 0x0F) << 8 | s[11];
    int i = 12 + pinfo;
    pmt_info pi; memset(&pi, 0, sizeof pi); pi.prog = prog;
    while (i + 5 <= len - 4) {
        int type = s[i], pid = (s[i + 1] & 0x1F) << 8 | s[i + 2];
        int eslen = (s[i + 3] & 0x0F) << 8 | s[i + 4];
        const uint8_t *d = s + i + 5, *dend = s + i + 5 + eslen;
        if (dend > s + len - 4) dend = s + len - 4;
        int is_video = type == 0x01 || type == 0x02 || type == 0x1B || type == 0x24;
        int is_audio = type == 0x81 || type == 0x87 || type == 0x0F || type == 0x11 || type == 0x03 || type == 0x04;
        if (is_video && !pi.video) { pi.video = pid; pi.vtype = type; }
        atsc_audio_track at; memset(&at, 0, sizeof at); at.pid = pid; at.stream_type = type;
        for (const uint8_t *q = d; q + 2 <= dend && q + 2 + q[1] <= dend; q += 2 + q[1]) {
            int tag = q[0], dl = q[1]; const uint8_t *v = q + 2;
            if (tag == 0x0A && dl >= 4 && is_audio) {             // ISO 639 language
                memcpy(at.lang, v, 3); at.lang[3] = 0;
                if (v[3] == 3) at.role = 3; else if (v[3] == 2 && !at.role) at.role = 2;
            } else if (tag == 0x81 && dl >= 3 && is_audio) {      // ATSC AC-3 audio descriptor
                int bsmod = v[2] >> 5, nch = (v[2] >> 1) & 0x0F;
                if (bsmod) at.role = bsmod;
                static const int chmap[8] = {2, 1, 2, 3, 3, 4, 4, 5};
                at.channels = nch < 8 ? chmap[nch] : (nch == 8 ? 1 : nch == 9 ? 2 : nch == 10 ? 6 : 0);
            } else if (tag == 0x86 && dl >= 1) {                  // caption service descriptor
                int ns = v[0] & 0x1F; const uint8_t *e = v + 1;
                for (int k = 0; k < ns && e + 6 <= v + dl && pi.nccs < MAX_CCS; k++, e += 6) {
                    atsc_caption_service *c = &pi.ccs[pi.nccs++];
                    memcpy(c->lang, e, 3); c->lang[3] = 0;
                    c->digital = (e[3] >> 7) & 1;
                    c->number = c->digital ? (e[3] & 0x3F) : (e[3] & 1) + 1;
                    c->easy_reader = (e[4] >> 7) & 1; c->wide = (e[4] >> 6) & 1;
                }
            }
        }
        if (is_audio && pi.naud < MAX_AUD) pi.aud[pi.naud++] = at;
        i += 5 + eslen;
    }
    if (pi.naud) { pi.audio = pi.aud[0].pid; pi.atype = pi.aud[0].stream_type; }
    int k = 0;
    for (; k < npmt; k++) if (pmts[k].prog == prog) break;
    if (k == npmt && npmt < MAX_CH) npmt++;
    if (k < MAX_CH) pmts[k] = pi;
    select_streams(m);
}

static void parse_mgt(atsc_media *m, const uint8_t *s, int len) {
    int n = s[9] << 8 | s[10];
    int i = 11;
    for (int t = 0; t < n && i + 11 <= len - 4; t++) {
        int type = s[i] << 8 | s[i + 1];
        int pid = (s[i + 2] & 0x1F) << 8 | s[i + 3];
        int dlen = (s[i + 9] & 0x0F) << 8 | s[i + 10];
        if (type >= 0x0100 && type <= 0x017F) set_table_pid(m, pid, 4);   // EIT-0 .. EIT-127
        if (type >= 0x0200 && type <= 0x027F) set_table_pid(m, pid, 5);   // event ETT-0 .. ETT-127
        i += 11 + dlen;
    }
}

static void parse_vct(atsc_media *m, const uint8_t *s, int len) {
    int ver = (s[5] >> 1) & 0x1F;
    int sec = s[6];
    if (sec == 0 && ver == m->tvct_version) return;
    if (sec == 0) { m->tvct_version = ver; m->nch = 0; }
    int n = s[9];
    int i = 10;
    for (int c = 0; c < n && i + 32 <= len - 4; c++) {
        atsc_vchannel v = {0};
        char *o = v.name, *end = v.name + sizeof v.name - 1;
        for (int k = 0; k < 7; k++) {
            uint32_t cp = (uint32_t)s[i + 2 * k] << 8 | s[i + 2 * k + 1];
            if (cp) utf8_put(&o, end, cp);
        }
        *o = 0;
        v.major = ((s[i + 14] & 0x0F) << 6) | (s[i + 15] >> 2);
        v.minor = ((s[i + 15] & 0x03) << 8) | s[i + 16];
        v.program = s[i + 24] << 8 | s[i + 25];
        v.hidden = (s[i + 26] >> 4) & 1;
        v.service_type = s[i + 27] & 0x3F;
        v.source_id = s[i + 28] << 8 | s[i + 29];
        int dlen = (s[i + 30] & 0x03) << 8 | s[i + 31];
        if (m->nch < MAX_CH) m->ch[m->nch++] = v;
        i += 32 + dlen;
    }
    if (s[6] == s[7] && m->cb.channels) m->cb.channels(m->cb.ctx, m->ch, m->nch);   // last section
}

/// Remember a guide section (EIT: pid, source, section, version; ETT: pid, ETM id, version);
/// returns 1 if it had not been seen before.
static int eit_note(atsc_media *m, int pid, const uint8_t *s) {
    uint64_t key = s[0] == 0xCC
        ? ((uint64_t)1 << 63 | (uint64_t)pid << 40 | (uint64_t)((uint32_t)s[9] << 24 | s[10] << 16 | s[11] << 8 | s[12]) << 5 | ((s[5] >> 1) & 0x1F))
        : ((uint64_t)pid << 40 | (uint64_t)(s[3] << 8 | s[4]) << 24 | (uint64_t)s[6] << 8 | ((s[5] >> 1) & 0x1F));
    key += 1;                                   // 0 marks an empty slot
    uint32_t h = (uint32_t)((key * 0x9E3779B97F4A7C15ull) >> 52);
    for (int probe = 0; probe < 4096; probe++, h = (h + 1) & 4095) {
        if (m->eit_seen[h] == key) return 0;
        if (!m->eit_seen[h]) {
            if (m->eit_count > 3500) return 0;  // full: stop counting, never block
            m->eit_seen[h] = key; m->eit_count++; m->eit_new_at = m->pkts;
            return 1;
        }
    }
    return 0;
}

/// Append a 3-letter language code to a comma-separated list if it is not there yet.
static void add_lang(char *list, int cap, const uint8_t *code) {
    char c[4] = {0};
    for (int k = 0; k < 3; k++) c[k] = (code[k] >= 'a' && code[k] <= 'z') || (code[k] >= 'A' && code[k] <= 'Z') ? (char)(code[k] | 0x20) : 0;
    if (!c[0] || !c[1] || !c[2] || strstr(list, c)) return;
    if (strlen(list) + 4 + (list[0] != 0) >= (size_t)cap) return;
    if (list[0]) strcat(list, ",");
    strcat(list, c);
}

/// Ratings, captions and audio languages announced for one event.
static void event_descriptors(atsc_event *ev, const uint8_t *d, const uint8_t *dend) {
    for (const uint8_t *q = d; q + 2 <= dend && q + 2 + q[1] <= dend; q += 2 + q[1]) {
        int tag = q[0], dl = q[1]; const uint8_t *v = q + 2, *vend = v + dl;
        if (tag == 0x87 && dl >= 1 && !ev->rating[0]) {            // content advisory (A/65 6.9.9)
            int regions = v[0] & 0x3F; const uint8_t *r = v + 1;
            for (int k = 0; k < regions && r + 2 <= vend; k++) {
                int dims = r[1]; r += 2 + 2 * dims;
                if (r + 1 > vend) break;
                int tl = r[0];
                if (r + 1 + tl > vend) break;
                if (tl && !ev->rating[0]) mss_to_utf8(r + 1, tl, ev->rating, sizeof ev->rating);
                r += 1 + tl;
            }
        } else if (tag == 0x86 && dl >= 1) {                         // caption service
            int ns = v[0] & 0x1F; const uint8_t *e = v + 1;
            for (int k = 0; k < ns && e + 6 <= vend; k++, e += 6) {
                ev->captions = 1;
                add_lang(ev->caption_langs, sizeof ev->caption_langs, e);
            }
        } else if (tag == 0x81 && dl >= 5) {                         // AC-3 audio (A/52 Annex A)
            int nch = (v[2] >> 1) & 0x0F, bsmod = v[2] >> 5;
            const uint8_t *p = v + 4;                                // past langcod
            if (nch == 0) p++;                                       // langcod2 (1+1 mode)
            p++;                                                     // mainid/priority or asvcflags
            (void)bsmod;
            if (p >= vend) continue;
            int textlen = p[0] >> 1; p += 1 + textlen;
            if (p >= vend) continue;
            int lf = p[0] >> 7, lf2 = (p[0] >> 6) & 1; p++;
            if (lf && p + 3 <= vend) { add_lang(ev->audio_langs, sizeof ev->audio_langs, p); p += 3; }
            if (lf2 && p + 3 <= vend) add_lang(ev->audio_langs, sizeof ev->audio_langs, p);
        } else if (tag == 0x0A && dl >= 4) {                         // ISO 639 language (other audio codecs)
            add_lang(ev->audio_langs, sizeof ev->audio_langs, v);
        }
    }
}

static void parse_ett(atsc_media *m, int pid, const uint8_t *s, int len) {
    eit_note(m, pid, s);
    if (len < 13 + 4 || !m->cb.description) return;
    uint32_t etm = (uint32_t)s[9] << 24 | s[10] << 16 | s[11] << 8 | s[12];
    if ((etm & 3) != 2) return;                  // event ETMs only (channel ETMs end in 00)
    char text[2048];
    mss_to_utf8(s + 13, len - 13 - 4, text, sizeof text);
    if (text[0]) m->cb.description(m->cb.ctx, (int)(etm >> 16), (int)((etm >> 2) & 0x3FFF), text);
}

static void parse_eit(atsc_media *m, int pid, const uint8_t *s, int len) {
    eit_note(m, pid, s);
    int source = s[3] << 8 | s[4];
    int n = s[9];
    int i = 10;
    for (int e = 0; e < n && i + 10 <= len - 4; e++) {
        atsc_event ev = {0};
        ev.source_id = source;
        ev.event_id = ((s[i] & 0x3F) << 8) | s[i + 1];
        uint32_t start = (uint32_t)s[i + 2] << 24 | s[i + 3] << 16 | s[i + 4] << 8 | s[i + 5];
        ev.duration = ((s[i + 6] & 0x0F) << 16) | s[i + 7] << 8 | s[i + 8];
        int tlen = s[i + 9];
        if (i + 10 + tlen + 2 > len - 4) break;
        mss_to_utf8(s + i + 10, tlen, ev.title, sizeof ev.title);
        ev.start_utc = GPS_EPOCH_UNIX + start - (m->have_offset ? m->gps_utc_offset : 18);
        int dlen = (s[i + 10 + tlen] & 0x0F) << 8 | s[i + 11 + tlen];
        const uint8_t *d = s + i + 12 + tlen, *dend = d + dlen;
        if (dend > s + len - 4) dend = s + len - 4;
        event_descriptors(&ev, d, dend);
        if (m->cb.event) m->cb.event(m->cb.ctx, &ev);
        i += 12 + tlen + dlen;
    }
}

static void parse_stt(atsc_media *m, const uint8_t *s, int len) {
    if (len < 17) return;
    uint32_t gps = (uint32_t)s[9] << 24 | s[10] << 16 | s[11] << 8 | s[12];
    m->gps_utc_offset = s[13]; m->have_offset = 1;
    if (m->cb.time) m->cb.time(m->cb.ctx, GPS_EPOCH_UNIX + gps - m->gps_utc_offset);
}

static void handle_section(atsc_media *m, int pid, const uint8_t *s, int len) {
    int syntax = s[1] & 0x80;
    if (syntax && crc32_mpeg(s, len) != 0) return;     // corrupted
    int tid = s[0];
    int kind = m->is_table[pid];
    if (kind == 1 && tid == 0x00) parse_pat(m, s, len);
    else if (kind == 2 && tid == 0x02) parse_pmt(m, s, len);
    else if (kind == 3 && tid == 0xC7) parse_mgt(m, s, len);
    else if (kind == 3 && (tid == 0xC8 || tid == 0xC9)) parse_vct(m, s, len);
    else if (kind == 3 && tid == 0xCD) parse_stt(m, s, len);
    else if (kind == 4 && tid == 0xCB) parse_eit(m, pid, s, len);
    else if (kind == 5 && tid == 0xCC) parse_ett(m, pid, s, len);
}

static void section_packet(atsc_media *m, int pid, const uint8_t *p, int n, int pusi) {
    section_buf *sb = m->sec[pid];
    if (!sb) return;
    int i = 0;
    if (pusi) {
        int ptr = p[0]; i = 1;
        if (sb->active && ptr > 0 && i + ptr <= n) {   // tail of the previous section
            memcpy(sb->buf + sb->len, p + i, ptr); sb->len += ptr;
            if (sb->need && sb->len >= sb->need) handle_section(m, pid, sb->buf, sb->need);
        }
        i += ptr; sb->active = 1; sb->len = 0; sb->need = 0;
    } else if (!sb->active) return;
    while (i < n) {
        if (sb->len == 0 && p[i] == 0xFF) { sb->active = 0; return; }     // stuffing
        int take = n - i;
        if (sb->len + take > (int)sizeof sb->buf) { sb->active = 0; return; }
        memcpy(sb->buf + sb->len, p + i, take); sb->len += take; i += take;
        while (1) {
            if (!sb->need && sb->len >= 3) sb->need = 3 + (((sb->buf[1] & 0x0F) << 8) | sb->buf[2]);
            if (!sb->need || sb->len < sb->need) break;
            handle_section(m, pid, sb->buf, sb->need);
            int rest = sb->len - sb->need;
            memmove(sb->buf, sb->buf + sb->need, rest);
            sb->len = rest; sb->need = 0;
            if (rest == 0 || sb->buf[0] == 0xFF) { sb->len = 0; break; }
        }
    }
}

// ----------------------------------------------------------------------------- decoding

static void close_decoders(atsc_media *m) {
    if (m->vparser) av_parser_close(m->vparser);
    if (m->aparser) av_parser_close(m->aparser);
    avcodec_free_context(&m->vdec); avcodec_free_context(&m->adec);
    avfilter_graph_free(&m->graph); m->src = m->sink = NULL; m->g_w = 0;
    swr_free(&m->swr); m->swr_in_ch = 0;
    m->vparser = m->aparser = NULL;
    m->vpes.started = m->apes.started = 0; m->vpes.len = m->apes.len = 0;
    m->fmt_w = m->fmt_h = m->fmt_ach = -1;
    m->a_next_pts = m->v_next_pts = AV_NOPTS_VALUE; m->v_frame_dur = 0;
    m->v_cc = m->a_cc = -1; m->v_wait_key = 1; m->v_wait_from = AV_NOPTS_VALUE; m->a_skip = 0;
}

static enum AVCodecID video_codec(int t) {
    switch (t) { case 0x01: case 0x02: return AV_CODEC_ID_MPEG2VIDEO; case 0x1B: return AV_CODEC_ID_H264; case 0x24: return AV_CODEC_ID_HEVC; default: return AV_CODEC_ID_NONE; }
}
static enum AVCodecID audio_codec(int t) {
    switch (t) {
    case 0x81: return AV_CODEC_ID_AC3; case 0x87: return AV_CODEC_ID_EAC3;
    case 0x0F: return AV_CODEC_ID_AAC; case 0x11: return AV_CODEC_ID_AAC_LATM;
    case 0x03: case 0x04: return AV_CODEC_ID_MP2;
    default: return AV_CODEC_ID_NONE;
    }
}

const char *atsc_stream_type_name(int t) {
    switch (t) {
    case 0x01: return "MPEG-1"; case 0x02: return "MPEG-2"; case 0x1B: return "H.264"; case 0x24: return "H.265";
    case 0x81: return "AC-3"; case 0x87: return "E-AC-3"; case 0x0F: return "AAC"; case 0x11: return "AAC (LATM)";
    case 0x03: case 0x04: return "MPEG audio";
    default: return "unknown";
    }
}

static AVCodecContext *open_one(enum AVCodecID id, AVCodecParserContext **parser, int threads) {
    const AVCodec *c = id == AV_CODEC_ID_NONE ? NULL : avcodec_find_decoder(id);
    if (!c) { *parser = NULL; return NULL; }
    AVCodecContext *ctx = avcodec_alloc_context3(c);
    ctx->thread_count = threads;
    ctx->pkt_timebase = (AVRational){1, 90000};
    if (avcodec_open2(ctx, c, NULL) < 0) { avcodec_free_context(&ctx); *parser = NULL; return NULL; }
    *parser = av_parser_init(id == AV_CODEC_ID_MP2 ? AV_CODEC_ID_MP2 : id);
    return ctx;
}

static void open_decoders(atsc_media *m) {
    close_decoders(m);
    m->vdec = open_one(video_codec(m->video_type), &m->vparser, 4);
    m->adec = open_one(audio_codec(m->audio_type), &m->aparser, 1);
    m->v_frames = m->a_frames = 0;
}

static void select_streams(atsc_media *m) {
    int prog = m->want_program;
    if (!prog && m->nprog) prog = m->prog_list[0];
    for (int k = 0; k < npmt; k++) {
        if (pmts[k].prog != prog) continue;
        pmt_info *pi = &pmts[k];
        int ai = m->want_audio >= 0 && m->want_audio < pi->naud ? m->want_audio : 0;
        int apid = pi->naud ? pi->aud[ai].pid : 0, atype = pi->naud ? pi->aud[ai].stream_type : 0;
        if (prog == m->cur_program && pi->video == m->video_pid && apid == m->audio_pid) { m->cur_pmt = k; return; }
        int video_same = prog == m->cur_program && pi->video == m->video_pid;
        m->cur_program = prog; m->cur_pmt = k;
        m->video_pid = pi->video; m->video_type = pi->vtype;
        m->audio_pid = apid; m->audio_type = atype;
        if (video_same) {                          // audio track change only: keep the picture going
            if (m->aparser) av_parser_close(m->aparser);
            avcodec_free_context(&m->adec);
            m->adec = open_one(audio_codec(atype), &m->aparser, 1);
            swr_free(&m->swr); m->swr_in_ch = 0; m->apes.started = 0; m->a_next_pts = AV_NOPTS_VALUE;
        } else {
            open_decoders(m);
            if (m->cc) cc_reset(m->cc);
        }
        return;
    }
}

int atsc_media_audio_tracks(atsc_media *m, atsc_audio_track *out, int max) {
    if (m->cur_pmt < 0 || m->cur_pmt >= npmt) return 0;
    pmt_info *pi = &pmts[m->cur_pmt];
    int n = pi->naud < max ? pi->naud : max;
    memcpy(out, pi->aud, sizeof(atsc_audio_track) * n);
    return n;
}

void atsc_media_select_audio(atsc_media *m, int index) { m->want_audio = index; select_streams(m); }

int atsc_media_caption_services(atsc_media *m, atsc_caption_service *out, int max) {
    if (m->cur_pmt < 0 || m->cur_pmt >= npmt) return 0;
    pmt_info *pi = &pmts[m->cur_pmt];
    int n = pi->nccs < max ? pi->nccs : max;
    memcpy(out, pi->ccs, sizeof(atsc_caption_service) * n);
    return n;
}

static void on_cc_screen(void *ctx, const char *json) {
    atsc_media *m = ctx;
    if (m->cb.captions) m->cb.captions(m->cb.ctx, m->cc_pts, json);
}

void atsc_media_select_captions(atsc_media *m, int service) {
    if (service == m->cc_service) return;
    m->cc_service = service;
    cc_destroy(m->cc); m->cc = NULL;
    if (service) m->cc = cc_create(service, on_cc_screen, m);
    else if (m->cb.captions) m->cb.captions(m->cb.ctx, m->cc_pts, "{\"regions\":[]}");
}

static int build_graph(atsc_media *m, AVFrame *f) {
    avfilter_graph_free(&m->graph);
    m->graph = avfilter_graph_alloc();
    char args[256];
    AVRational sar = f->sample_aspect_ratio.num ? f->sample_aspect_ratio : (AVRational){1, 1};
    snprintf(args, sizeof args, "video_size=%dx%d:pix_fmt=%d:time_base=1/90000:pixel_aspect=%d/%d:colorspace=%d:range=%d",
             f->width, f->height, f->format, sar.num, sar.den, f->colorspace, f->color_range);
    if (avfilter_graph_create_filter(&m->src, avfilter_get_by_name("buffer"), "in", args, NULL, m->graph) < 0) return -1;
    if (avfilter_graph_create_filter(&m->sink, avfilter_get_by_name("buffersink"), "out", NULL, NULL, m->graph) < 0) return -1;
    AVFilterInOut *outs = avfilter_inout_alloc(), *ins = avfilter_inout_alloc();
    outs->name = av_strdup("in"); outs->filter_ctx = m->src; outs->pad_idx = 0; outs->next = NULL;
    ins->name = av_strdup("out"); ins->filter_ctx = m->sink; ins->pad_idx = 0; ins->next = NULL;
    // bwdif: motion-adaptive deinterlacing, one output frame per input frame; progressive frames pass through
    int r = avfilter_graph_parse_ptr(m->graph, "bwdif=mode=send_frame:parity=auto:deint=interlaced,format=yuv420p", &ins, &outs, NULL);
    avfilter_inout_free(&ins); avfilter_inout_free(&outs);
    if (r < 0 || avfilter_graph_config(m->graph, NULL) < 0) return -1;
    m->g_w = f->width; m->g_h = f->height; m->g_fmt = f->format; m->g_sn = sar.num; m->g_sd = sar.den;
    return 0;
}

static void emit_video(atsc_media *m, AVFrame *f) {
    m->v_frames++;
    if (m->cb.video)
        m->cb.video(m->cb.ctx, f->data[0], f->data[1], f->data[2], f->linesize[0], f->linesize[1],
                    f->width, f->height, f->sample_aspect_ratio.num ? f->sample_aspect_ratio.num : 1,
                    f->sample_aspect_ratio.den ? f->sample_aspect_ratio.den : 1, f->pts);
}

static void decode_video(atsc_media *m, AVPacket *pk) {
    if (avcodec_send_packet(m->vdec, pk) < 0) return;
    while (avcodec_receive_frame(m->vdec, m->frame) == 0) {
        AVFrame *f = m->frame;
        if (f->pts == AV_NOPTS_VALUE) f->pts = f->best_effort_timestamp;
        if (m->vdec->framerate.num > 0)
            m->v_frame_dur = (int64_t)90000 * m->vdec->framerate.den / m->vdec->framerate.num;
        if (f->pts == AV_NOPTS_VALUE && m->v_next_pts != AV_NOPTS_VALUE) f->pts = m->v_next_pts;
        if (f->pts != AV_NOPTS_VALUE) m->v_next_pts = f->pts + (m->v_frame_dur ? m->v_frame_dur : 3003);
        int interlaced = (f->flags & AV_FRAME_FLAG_INTERLACED) != 0;
        if (m->fmt_w != f->width || m->fmt_h != f->height || m->fmt_i != interlaced) {
            m->fmt_w = f->width; m->fmt_h = f->height; m->fmt_i = interlaced;
            if (m->cb.format) m->cb.format(m->cb.ctx, f->width, f->height, interlaced, m->fmt_ach);
        }
        if (m->cc) {
            AVFrameSideData *sd = av_frame_get_side_data(f, AV_FRAME_DATA_A53_CC);
            if (sd && sd->size >= 3) { m->cc_pts = f->pts; cc_feed(m->cc, sd->data, (int)(sd->size / 3)); }
        }
        // After a gap in the stream, frames decoded from incomplete data are smeared with blocks
        // until the next keyframe. Hold the last good picture instead: show nothing until a clean
        // keyframe arrives (or 3 s pass, for streams with very long keyframe intervals). Frames the
        // decoder itself flags as damaged are never shown.
        int damaged = (f->flags & AV_FRAME_FLAG_CORRUPT) || f->decode_error_flags;
        if (m->v_wait_key) {
            int key = (f->flags & AV_FRAME_FLAG_KEY) || f->pict_type == AV_PICTURE_TYPE_I;
            if (m->v_wait_from == AV_NOPTS_VALUE) m->v_wait_from = f->pts;
            int waited_long = f->pts != AV_NOPTS_VALUE && m->v_wait_from != AV_NOPTS_VALUE && f->pts - m->v_wait_from > 3 * 90000;
            if ((key && !damaged) || (waited_long && !damaged)) { m->v_wait_key = 0; m->v_wait_from = AV_NOPTS_VALUE; }
            else { m->v_held++; av_frame_unref(f); continue; }
        } else if (damaged) { m->v_held++; av_frame_unref(f); continue; }
        AVRational sar = f->sample_aspect_ratio.num ? f->sample_aspect_ratio : (AVRational){1, 1};
        if (!m->graph || f->width != m->g_w || f->height != m->g_h || f->format != m->g_fmt ||
            sar.num != m->g_sn || sar.den != m->g_sd) {
            if (build_graph(m, f) < 0) { emit_video(m, f); av_frame_unref(f); continue; }
        }
        if (av_buffersrc_add_frame_flags(m->src, f, AV_BUFFERSRC_FLAG_KEEP_REF) >= 0) {
            AVRational tb = av_buffersink_get_time_base(m->sink);   // bwdif doubles the time base
            while (av_buffersink_get_frame(m->sink, m->filt) >= 0) {
                if (m->filt->pts != AV_NOPTS_VALUE) m->filt->pts = av_rescale_q(m->filt->pts, tb, (AVRational){1, 90000});
                emit_video(m, m->filt);
                av_frame_unref(m->filt);
            }
        }
        av_frame_unref(f);
    }
}

static void decode_audio(atsc_media *m, AVPacket *pk) {
    if (avcodec_send_packet(m->adec, pk) < 0) return;
    while (avcodec_receive_frame(m->adec, m->frame) == 0) {
        AVFrame *f = m->frame;
        int ch = f->ch_layout.nb_channels;
        if (ch != m->fmt_ach) {
            m->fmt_ach = ch;
            if (m->cb.format && m->fmt_w > 0) m->cb.format(m->cb.ctx, m->fmt_w, m->fmt_h, m->fmt_i, ch);
        }
        if (!m->swr || ch != m->swr_in_ch || f->sample_rate != m->swr_rate || f->format != m->swr_fmt) {
            swr_free(&m->swr);
            AVChannelLayout out = AV_CHANNEL_LAYOUT_STEREO;
            swr_alloc_set_opts2(&m->swr, &out, AV_SAMPLE_FMT_FLT, f->sample_rate,
                                &f->ch_layout, f->format, f->sample_rate, 0, NULL);
            if (!m->swr || swr_init(m->swr) < 0) { swr_free(&m->swr); av_frame_unref(f); continue; }
            m->swr_in_ch = ch; m->swr_rate = f->sample_rate; m->swr_fmt = f->format;
        }
        int outn = swr_get_out_samples(m->swr, f->nb_samples);
        if (outn * 2 > m->abuf_cap) { m->abuf_cap = outn * 2; m->abuf = realloc(m->abuf, sizeof(float) * m->abuf_cap); }
        uint8_t *outp[1] = {(uint8_t *)m->abuf};
        int got = swr_convert(m->swr, outp, outn, (const uint8_t **)f->extended_data, f->nb_samples);
        // Several AC-3 frames share one PES timestamp; the ones after the first carry none.
        // Continue the timeline from the previous frame instead of dropping them.
        int64_t pts = f->pts;
        if (pts == AV_NOPTS_VALUE || (m->a_next_pts != AV_NOPTS_VALUE && llabs(pts - m->a_next_pts) < 900))
            pts = m->a_next_pts;                       // also smooths sub-10 ms timestamp jitter
        if (pts != AV_NOPTS_VALUE) m->a_next_pts = pts + (int64_t)got * 90000 / f->sample_rate;
        if (got > 0) m->a_frames++;
        if (m->a_skip > 0) { m->a_skip--; av_frame_unref(f); continue; }   // around a gap: brief silence, not a glitch
        if (got > 0 && pts != AV_NOPTS_VALUE && m->cb.audio) m->cb.audio(m->cb.ctx, m->abuf, got, f->sample_rate, pts);
        av_frame_unref(f);
    }
}

static void parse_es(atsc_media *m, int video, const uint8_t *d, int n, int64_t pts, int64_t dts) {
    AVCodecParserContext *p = video ? m->vparser : m->aparser;
    AVCodecContext *c = video ? m->vdec : m->adec;
    if (!p || !c) return;
    while (n > 0) {
        uint8_t *out; int outn;
        int used = av_parser_parse2(p, c, &out, &outn, d, n, pts, dts, 0);
        pts = dts = AV_NOPTS_VALUE;
        d += used; n -= used;
        if (outn) {
            m->pkt->data = out; m->pkt->size = outn;
            m->pkt->pts = p->pts; m->pkt->dts = p->dts;
            if (video) decode_video(m, m->pkt); else decode_audio(m, m->pkt);
        }
        if (used == 0 && outn == 0) break;
    }
}

static void pes_packet(atsc_media *m, int video, const uint8_t *p, int n, int pusi) {
    pes_buf *pb = video ? &m->vpes : &m->apes;
    int64_t pts = AV_NOPTS_VALUE, dts = AV_NOPTS_VALUE;
    if (pusi) {
        if (n < 9 || p[0] != 0 || p[1] != 0 || p[2] != 1) { pb->started = 0; return; }
        int hlen = p[8];
        if ((p[7] & 0x80) && n >= 14) {
            pts = ((int64_t)(p[9] & 0x0E) << 29) | ((int64_t)p[10] << 22) | ((int64_t)(p[11] & 0xFE) << 14) |
                  ((int64_t)p[12] << 7) | (p[13] >> 1);
            dts = pts;                                  // equal unless a DTS is also present
        }
        if ((p[7] & 0xC0) == 0xC0 && n >= 19) {     // PTS and DTS both present (reordered video)
            dts = ((int64_t)(p[14] & 0x0E) << 29) | ((int64_t)p[15] << 22) | ((int64_t)(p[16] & 0xFE) << 14) |
                  ((int64_t)p[17] << 7) | (p[18] >> 1);
        }
        if (9 + hlen > n) { pb->started = 0; return; }
        p += 9 + hlen; n -= 9 + hlen;
        pb->started = 1;
    } else if (!pb->started) return;
    parse_es(m, video, p, n, pts, dts);
}

// ----------------------------------------------------------------------------- public

atsc_media *atsc_media_create(const atsc_media_cb *cb) {
    av_log_set_level(AV_LOG_FATAL);           // missing-reference noise before the first I-frame is normal
    atsc_media *m = calloc(1, sizeof *m);
    m->cb = *cb;
    m->frame = av_frame_alloc(); m->filt = av_frame_alloc(); m->pkt = av_packet_alloc();
    atsc_media_reset(m);
    return m;
}

void atsc_media_destroy(atsc_media *m) {
    if (!m) return;
    cc_destroy(m->cc);
    close_decoders(m);
    for (int i = 0; i < MAX_PIDS; i++) free(m->sec[i]);
    av_frame_free(&m->frame); av_frame_free(&m->filt); av_packet_free(&m->pkt);
    free(m->abuf);
    free(m);
}

void atsc_media_reset(atsc_media *m) {
    close_decoders(m);
    for (int i = 0; i < MAX_PIDS; i++) { free(m->sec[i]); m->sec[i] = NULL; m->is_table[i] = 0; }
    set_table_pid(m, 0x0000, 1);
    set_table_pid(m, 0x1FFB, 3);
    m->pat_version = m->tvct_version = -1;
    m->nprog = 0; m->nch = 0; npmt = 0;
    m->cur_program = -1; m->video_pid = m->audio_pid = -1;
    m->video_type = m->audio_type = 0; m->v_frames = m->a_frames = 0;
    m->cur_pmt = -1; m->want_audio = 0;
    if (m->cc) cc_reset(m->cc);
    memset(m->eit_seen, 0, sizeof m->eit_seen); m->eit_count = 0; m->pkts = m->eit_new_at = 0;
}

void atsc_media_guide_progress(atsc_media *m, int *sections, uint64_t *packets_since_new) {
    *sections = m->eit_count;
    *packets_since_new = m->pkts - m->eit_new_at;
}

void atsc_media_get_status(atsc_media *m, atsc_media_status *o) {
    memset(o, 0, sizeof *o);
    o->tables_seen = m->pat_version >= 0;
    int want = m->want_program;
    for (int k = 0; k < m->nprog; k++) if (m->prog_list[k] == want || (!want && k == 0)) o->program_listed = 1;
    o->program_mapped = m->cur_program > 0 && (!want || m->cur_program == want);
    o->video_type = o->program_mapped ? m->video_type : 0;
    o->audio_type = o->program_mapped ? m->audio_type : 0;
    o->video_supported = m->vdec != NULL;
    o->audio_supported = m->adec != NULL;
    o->video_frames = m->v_frames; o->audio_frames = m->a_frames;
    o->dropped_packets = m->dropped;
    o->held_frames = m->v_held; o->stream_gaps = m->gaps;
}

int atsc_media_selected_pids(atsc_media *m, int *pids, int max) {
    int n = 0, pmt = -1;
    for (int k = 0; k < m->nprog; k++) if (m->prog_list[k] == m->cur_program) pmt = m->prog_pmt[k];
    int cand[5] = {0x0000, pmt, m->video_pid, m->audio_pid, 0x1FFB};
    for (int i = 0; i < 5 && n < max; i++) if (cand[i] >= 0) pids[n++] = cand[i];
    return n;
}

int atsc_media_current_program(atsc_media *m) { return m->cur_program; }

void atsc_media_select(atsc_media *m, int program) {
    if (program != m->want_program) m->want_audio = 0;
    m->want_program = program;
    select_streams(m);
}

void atsc_media_push(atsc_media *m, const uint8_t *pk, int ok) {
    m->pkts++;
    if (!ok || pk[0] != 0x47 || (pk[1] & 0x80)) { m->dropped++; return; }
    int pid = (pk[1] & 0x1F) << 8 | pk[2];
    int pusi = pk[1] & 0x40;
    int afc = (pk[3] >> 4) & 3;
    int i = 4;
    if (afc == 2 || afc == 0) return;               // no payload
    if (afc == 3) { i += 1 + pk[4]; if (i >= 188) return; }
    const uint8_t *p = pk + i; int n = 188 - i;
    if (pid == m->video_pid || pid == m->audio_pid) {
        // continuity counter: +1 per packet with payload; a repeat is a permitted duplicate
        int cc = pk[3] & 0x0F, *last = pid == m->video_pid ? &m->v_cc : &m->a_cc;
        if (*last >= 0 && cc == *last) return;                        // duplicate packet
        if (*last >= 0 && cc != ((*last + 1) & 0x0F)) {               // packets went missing
            m->gaps++;
            if (pid == m->video_pid) m->v_wait_key = 1; else m->a_skip = 2;
        }
        *last = cc;
    }
    if (m->sec[pid]) section_packet(m, pid, p, n, pusi);
    else if (pid == m->video_pid) pes_packet(m, 1, p, n, pusi);
    else if (pid == m->audio_pid) pes_packet(m, 0, p, n, pusi);
}
