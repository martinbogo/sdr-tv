"""8VSB error-correction back end (ATSC A/53 Part 2 section 5.2), in reverse:
trellis decoding of the 12 interleaved encoders, byte reassembly, convolutional byte
deinterleaving, Reed-Solomon (207,187) decoding and derandomizing into MPEG transport packets.
"""
import numpy as np
from numba import njit

SEG_DATA = 828           # data symbols per segment
SEGS = 312               # data segments per field
BYTES_FIELD = SEGS * 207
NCODERS = 12

# --------------------------------------------------------------------------- trellis


@njit(cache=True)
def viterbi(r):
    """Decode one trellis encoder's soft symbol stream.

    Encoder (Figure 5.6): Z1 = X1; Z0 = b; next a = b, next b = a ^ X1 (state = 2a + b).
    Z2 is uncoded (the differential precoder output), so each branch keeps the better of the two
    parallel levels. Level = 2 * (4 Z2 + 2 Z1 + Z0) - 7. Returns X1 and Z2 per symbol.
    """
    n = len(r)
    INF = 1e30
    pm = np.array([0.0, INF, INF, INF])       # encoder starts in state 0
    prev = np.empty((n, 4), np.int8)
    bit = np.empty((n, 4), np.int8)
    z2c = np.empty((n, 4), np.int8)
    for t in range(n):
        new = np.array([INF, INF, INF, INF])
        for s in range(4):
            if pm[s] >= INF:
                continue
            a = s >> 1; b = s & 1
            for x1 in range(2):
                ns = (b << 1) | (a ^ x1)
                base = 2 * x1 + b                   # 2 Z1 + Z0
                l0 = 2.0 * base - 7.0               # Z2 = 0
                l1 = 2.0 * (4 + base) - 7.0         # Z2 = 1
                d0 = (r[t] - l0) ** 2; d1 = (r[t] - l1) ** 2
                if d0 <= d1:
                    m = pm[s] + d0; z = 0
                else:
                    m = pm[s] + d1; z = 1
                if m < new[ns]:
                    new[ns] = m; prev[t, ns] = s; bit[t, ns] = x1; z2c[t, ns] = z
        mn = new.min()
        for s in range(4):
            pm[s] = new[s] - mn
    x1 = np.empty(n, np.int8); z2 = np.empty(n, np.int8)
    s = int(np.argmin(pm))
    for t in range(n - 1, -1, -1):
        x1[t] = bit[t, s]; z2[t] = z2c[t, s]
        s = prev[t, s]
    return x1, z2


def encoder_positions():
    """For each encoder, the (segment, data-symbol) positions it occupies within a field, in order."""
    s = np.repeat(np.arange(SEGS), SEG_DATA)
    j = np.tile(np.arange(SEG_DATA), SEGS)
    enc = (j + 4 * (s % 3)) % NCODERS
    flat = s * SEG_DATA + j
    return [flat[enc == e] for e in range(NCODERS)]


def byte_map():
    """Field byte k -> (encoder, index of that byte within the encoder's stream).

    Bytes are latched to the encoders in rows of 12. A row latched after the r-th data segment
    boundary (in output symbol time, 48 symbols per row) is rotated by 4r encoders, which
    reproduces Table 5.2 of A/53 Part 2.
    """
    k = np.arange(BYTES_FIELD)
    row = k // 12
    r = (48 * row) // SEG_DATA
    enc = (k + 4 * r) % NCODERS
    idx = np.zeros(BYTES_FIELD, np.int64)
    count = np.zeros(NCODERS, np.int64)
    for i in range(BYTES_FIELD):
        idx[i] = count[enc[i]]; count[enc[i]] += 1
    assert (count == BYTES_FIELD // NCODERS).all()
    return enc, idx


def trellis_decode(fields_soft):
    """fields_soft: (nfields, 312*828) soft data symbols. Returns (nfields, 64584) bytes in
    transmission (interleaved) order."""
    nf = len(fields_soft)
    pos = encoder_positions()
    enc, idx = byte_map()
    out = np.zeros((nf, BYTES_FIELD), np.uint8)
    per = BYTES_FIELD // NCODERS
    for e in range(NCODERS):
        stream = np.concatenate([f[pos[e]] for f in fields_soft])
        x1, z2 = viterbi(stream.astype(np.float64))
        x2 = z2 ^ np.concatenate([[0], z2[:-1]])          # undo the differential precoder
        # 4 symbols per byte, bit pairs (X2, X1) = (7,6), (5,4), (3,2), (1,0)
        pairs = (x2.astype(np.uint8) << 1) | x1.astype(np.uint8)
        b = (pairs[0::4] << 6) | (pairs[1::4] << 4) | (pairs[2::4] << 2) | pairs[3::4]
        b = b.reshape(nf, per)
        sel = enc == e
        out[:, sel] = b[:, idx[sel]]
    return out

# --------------------------------------------------------------------------- deinterleave


def deinterleave(stream):
    """Convolutional byte deinterleaver, B = 52, M = 4 (shift-register form of Figure 5.5).
    Interleaved byte n was delayed by (n mod 52) * 4 * 52 bytes, so input byte m sits at
    output position m + 208 * (m mod 52)."""
    n = len(stream)
    m = np.arange(n)
    src = m + 208 * (m % 52)
    ok = src < n
    return stream[src[ok]]

# --------------------------------------------------------------------------- Reed-Solomon


def _gf_tables():
    exp = np.zeros(512, np.int64); log = np.zeros(256, np.int64)
    x = 1
    for i in range(255):
        exp[i] = x; log[x] = i
        x <<= 1
        if x & 0x100:
            x ^= 0x11D                                 # x^8 + x^4 + x^3 + x^2 + 1
    exp[255:510] = exp[:255]
    return exp, log


GF_EXP, GF_LOG = _gf_tables()


@njit(cache=True)
def _syndromes(cw, exp, log):
    S = np.zeros(20, np.int64)
    for j in range(20):                                # roots alpha^0 .. alpha^19
        s = 0
        for i in range(len(cw)):                       # Horner, highest degree first
            if s:
                s = exp[(log[s] + j) % 255]
            s ^= cw[i]
        S[j] = s
    return S


@njit(cache=True)
def _gmul(a, b, exp, log):
    if a == 0 or b == 0:
        return 0
    return exp[(log[a] + log[b]) % 255]


@njit(cache=True)
def _ginv(a, exp, log):
    return exp[(255 - log[a]) % 255]


@njit(cache=True)
def rs_decode(cw, exp, log):
    """Decode one 207-byte codeword in place. Returns number of corrected bytes, or -1."""
    S = _syndromes(cw, exp, log)
    if S.max() == 0:
        return 0
    # Berlekamp-Massey
    C = np.zeros(21, np.int64); B = np.zeros(21, np.int64)
    C[0] = 1; B[0] = 1
    L = 0; m = 1; bb = 1
    for n in range(20):
        d = S[n]
        for i in range(1, L + 1):
            d ^= _gmul(C[i], S[n - i], exp, log)
        if d == 0:
            m += 1
        elif 2 * L <= n:
            T = C.copy()
            coef = _gmul(d, _ginv(bb, exp, log), exp, log)
            for i in range(m, 21):
                C[i] ^= _gmul(coef, B[i - m], exp, log)
            L = n + 1 - L; B = T; bb = d; m = 1
        else:
            coef = _gmul(d, _ginv(bb, exp, log), exp, log)
            for i in range(m, 21):
                C[i] ^= _gmul(coef, B[i - m], exp, log)
            m += 1
    if L > 10:
        return -1
    # Chien search: codeword position p (0 = first byte) has degree 206 - p
    n = len(cw)
    locs = np.zeros(L, np.int64); nl = 0
    for p in range(n):
        deg = n - 1 - p
        xinv = exp[(255 - deg) % 255]                  # alpha^-deg
        v = 0
        for i in range(L + 1):
            if C[i]:
                v ^= _gmul(C[i], exp[(log[xinv] * i) % 255] if i else 1, exp, log)
        if v == 0:
            if nl >= L:
                return -1
            locs[nl] = p; nl += 1
    if nl != L:
        return -1
    # Forney (roots start at alpha^0, so b = 0): e = X * Omega(X^-1) / Lambda'(X^-1)
    Om = np.zeros(20, np.int64)
    for i in range(20):
        v = 0
        for j in range(i + 1):
            if j <= L:
                v ^= _gmul(C[j], S[i - j], exp, log)
        Om[i] = v
    for q in range(nl):
        p = locs[q]; deg = n - 1 - p
        X = exp[deg % 255]; Xi = exp[(255 - deg) % 255]
        num = 0
        for i in range(20):
            if Om[i]:
                num ^= _gmul(Om[i], exp[(log[Xi] * i) % 255] if i else 1, exp, log)
        den = 0
        for i in range(1, L + 1, 2):                   # formal derivative: odd terms
            if C[i]:
                den ^= _gmul(C[i], exp[(log[Xi] * (i - 1)) % 255] if i > 1 else 1, exp, log)
        if den == 0:
            return -1
        cw[p] ^= _gmul(_gmul(X, num, exp, log), _ginv(den, exp, log), exp, log)
    S2 = _syndromes(cw, exp, log)
    return nl if S2.max() == 0 else -1

# --------------------------------------------------------------------------- randomizer


def prbs_bytes(n, variant=0):
    """ATSC randomizer bytes (Figure 5.3): 16-bit Galois LFSR, G = x16+x13+x12+x11+x7+x6+x3+x+1,
    preload 0xF180, one shift per byte; output bits D0..D7 from stages X1, X3, X4, X7, X11, X12,
    X13, X14 (D7 = MSB). `variant` selects whether a byte is taken before (0) or after (1) the shift."""
    st = [0] * 17                                      # st[k] = stage X^k, k = 1..16
    for bitpos in (15, 14, 13, 12, 8, 7):              # 0xF180 -> X16 X15 X14 X13 X9 X8
        st[bitpos + 1] = 1
    taps_after = {1, 3, 6, 7, 11, 12, 13}              # adders feeding stages X2, X4, X7, X8, X12, X13, X14
    outs = (1, 3, 4, 7, 11, 12, 13, 14)
    res = np.zeros(n, np.uint8)

    def shift():
        fb = st[16]
        for k in range(16, 1, -1):
            st[k] = st[k - 1] ^ (fb if (k - 1) in taps_after else 0)
        st[1] = fb

    for i in range(n):
        if variant == 1:
            shift()
        v = 0
        for bitn, stage in enumerate(outs):
            v |= st[stage] << bitn
        res[i] = v
        if variant == 0:
            shift()
    return res
