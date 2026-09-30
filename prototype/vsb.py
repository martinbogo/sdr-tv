"""8VSB front end: pilot lock, matched filter, symbol timing, segment and field sync.

Input is HackRF 8-bit IQ at 20 Msps with the ATSC channel somewhere in the band.
Output is the soft 8-level symbol stream, one row of 832 symbols per data segment,
with field sync segments identified.
"""
import numpy as np
import scipy.signal as ss

FS = 20e6
RS = 4.5e6 / 286 * 684                  # 10.762237762 Msymbols/s
PILOT_OFFSET = 309_440.559              # pilot above the lower channel edge (Rs/4 below centre... exact: (6e6 - Rs/2)/2)
ROLLOFF = 0.1152
SEG = 832


def load(path, seconds=None, offset_s=0.0):
    n = None if seconds is None else int(seconds * FS) * 2
    raw = np.fromfile(path, np.int8, count=-1 if n is None else n,
                      offset=int(offset_s * FS) * 2).astype(np.float32)
    x = raw[0::2] + 1j * raw[1::2]
    return (x - x.mean()).astype(np.complex64)


def find_pilot(x, f_guess):
    """Pilot frequency (Hz, relative to the tuned centre) near f_guess, by a long FFT."""
    n = 1 << 22
    seg = x[:n] * np.hanning(min(n, len(x)))
    sp = np.abs(np.fft.fft(seg, n))
    f = np.fft.fftfreq(n, 1 / FS)
    m = np.abs(f - f_guess) < 100e3
    k = np.flatnonzero(m)[np.argmax(sp[m])]
    # parabolic refinement on log magnitude
    a, b, c = np.log(sp[k - 1:k + 2])
    d = 0.5 * (a - c) / (a - 2 * b + c)
    return (k + d) * FS / n if (k + d) < n / 2 else (k + d - n) * FS / n


def pilot_to_dc(x, f_pilot):
    """Mix the pilot to 0 Hz and remove its residual phase so it sits on the positive real axis."""
    n = np.arange(len(x))
    y = x * np.exp(-2j * np.pi * f_pilot / FS * n).astype(np.complex64)
    # track slow residual phase: average over 100 us blocks, unwrap, interpolate
    blk = 2000
    nb = len(y) // blk
    ph = np.unwrap(np.angle(y[:nb * blk].reshape(nb, blk).mean(1)))
    ph = ss.medfilt(ph, 5)
    phi = np.interp(n, np.arange(nb) * blk + blk / 2, ph)
    return (y * np.exp(-1j * phi).astype(np.complex64)), ph


def rrc(num_taps, sps, beta):
    t = (np.arange(num_taps) - (num_taps - 1) / 2) / sps
    h = np.zeros_like(t)
    for i, ti in enumerate(t):
        if abs(ti) < 1e-9:
            h[i] = 1 - beta + 4 * beta / np.pi
        elif abs(abs(ti) - 1 / (4 * beta)) < 1e-9:
            h[i] = beta / np.sqrt(2) * ((1 + 2 / np.pi) * np.sin(np.pi / (4 * beta)) +
                                          (1 - 2 / np.pi) * np.cos(np.pi / (4 * beta)))
        else:
            h[i] = (np.sin(np.pi * ti * (1 - beta)) + 4 * beta * ti * np.cos(np.pi * ti * (1 + beta))) / \
                   (np.pi * ti * (1 - (4 * beta * ti) ** 2))
    return h / np.sqrt(np.sum(h ** 2))


def matched_2sps(y):
    """Resample to 2 samples/symbol and apply the VSB matched filter.

    With the pilot at DC the data occupy 0..Rs/2. The matched filter is a root-raised-cosine for
    symbol spacing 2T, shifted up by Rs/4; the real part of its output at the symbol instants is
    the 8-level data, the odd-lag ISI landing purely in the imaginary part.
    """
    z = ss.resample_poly(y, 1539, 1430)                 # 20 Msps -> 2 * Rs exactly (nominal)
    sps = 4                                             # samples per 2T at 2 * Rs
    h = rrc(4 * 32 + 1, sps, ROLLOFF) * np.exp(1j * np.pi / 4 * np.arange(4 * 32 + 1))
    z = ss.fftconvolve(z, h, mode="same")
    return z.astype(np.complex64)


SYNC = np.array([5, -5, -5, 5], float)
FRAC_SIGN = -1


def segment_sync(r, period=2 * SEG):
    """Correlate the real 2-sps signal against the 4-symbol segment sync; return per-segment
    fractional positions of the sync (in samples) and the correlation strength."""
    k = np.zeros(7); k[0::2] = SYNC
    c = np.correlate(r, k, mode="valid")
    # coarse: fold |c| over segments to find the phase
    nseg = len(c) // period - 1
    fold = np.abs(c[:nseg * period]).reshape(nseg, period).mean(0)
    p0 = int(np.argmax(fold))
    return c, p0, fold


def sinc_interp(z, t, taps=16):
    """Band-limited interpolation of z at fractional sample positions t (Kaiser-windowed sinc)."""
    i0 = np.floor(t).astype(np.int64)
    frac = (t - i0).astype(np.float32)
    ks = np.arange(-taps // 2 + 1, taps // 2 + 1)
    out = np.zeros(len(t), np.complex64)
    win_beta = 6.0
    for k in ks:
        idx = np.clip(i0 + k, 0, len(z) - 1)
        d = k - frac
        w = np.sinc(d) * np.i0(win_beta * np.sqrt(np.clip(1 - (d / (taps / 2)) ** 2, 0, 1))) / np.i0(win_beta)
        out += z[idx] * w.astype(np.float32)
    return out


def sync_times(z, p0, nseg, W=50):
    """Per-segment sync time (in 2-sps samples) from the complex segment-sync correlation.

    Near the sync the correlation phase advances by pi/2 per symbol (the Rs/4 VSB shift), so its
    phase gives the fractional timing: t = n - 4*phi/pi. One 4-symbol sync is too noisy on its own,
    so correlations are summed coherently over windows of W segments (the clock drifts only a
    fraction of a sample in that time), then the window times are interpolated per segment.
    """
    k = np.zeros(7, np.complex64); k[0::2] = SYNC
    P = 2.0 * SEG
    offs = np.arange(-8, 9)
    wt, wc = [], []
    t_start = float(p0)
    nwin = nseg // W
    for w in range(nwin):
        acc = np.zeros(len(offs), np.complex64)
        for i in range(W):
            n = int(round(t_start + i * P))
            if n + 8 + 7 >= len(z) or n - 8 < 0:
                break
            seg = z[n - 8:n + 8 + 7]
            acc += np.correlate(seg, k, mode="valid")
        j = int(np.argmax(np.abs(acc)))
        phi = np.angle(acc[j])
        frac = FRAC_SIGN * 4 * phi / np.pi
        while frac > 2: frac -= 4
        while frac < -2: frac += 4
        t0 = int(round(t_start)) + offs[j] + frac               # sync time of the window's first segment
        wt.append(t0); wc.append(np.abs(acc[j]) / W)
        if len(wt) >= 2:
            P = 0.7 * P + 0.3 * (wt[-1] - wt[-2]) / W           # track the sample-clock ratio
        t_start = t0 + W * P
    wt = np.array(wt)
    seg_idx = np.arange(nwin) * W
    ts = np.interp(np.arange(nwin * W), seg_idx, wt,
                   right=np.nan) if nwin > 1 else wt
    # extrapolate the last window with the final period
    last = np.isnan(ts)
    ts[last] = wt[-1] + (np.arange(nwin * W)[last] - seg_idx[-1]) * P
    return ts, np.array(wc)


def symbols(z, tsync):
    """Real-valued 832-symbol segments sampled at the recovered symbol instants."""
    nseg = len(tsync)
    step = np.diff(tsync, append=tsync[-1] + (tsync[-1] - tsync[-2])) / SEG   # samples per symbol, per segment
    t = tsync[:, None] + np.arange(SEG)[None, :] * step[:, None]
    zs = sinc_interp(z, t.ravel()).reshape(nseg, SEG)
    return zs


FIELD = 313 * SEG                           # symbols per field
VSB_MODE_8T = "000010100101111101011010"   # 8-VSB trellis-coded mode bits (Table 5.3)


def pn_levels(bits):
    return np.array([5.0 if b == "1" else -5.0 for b in bits])


def find_field_syncs(z):
    """Sample indices (2 sps) where each field's PN511 starts, with correlation phase."""
    import pn
    k = np.zeros(2 * 511 - 1, np.complex64); k[0::2] = pn_levels(pn.PN511) / 5
    c = ss.fftconvolve(z, k[::-1].conj(), mode="valid")
    a = np.abs(c)
    thr = 8 * np.median(a)
    idx = np.flatnonzero(a > thr)
    peaks = []
    for i in idx:
        if peaks and i - peaks[-1] < 1000:
            if a[i] > a[peaks[-1]]: peaks[-1] = i
        else:
            peaks.append(i)
    return np.array(peaks)


def field_grid(z, p0, p1, pad=200):
    """Resample one field onto an exact 2-samples-per-symbol grid starting 4 symbols (the segment
    sync) plus `pad` samples before PN511. Returns (u, offset) with symbol n of the field sync
    segment (n = 0 at the first segment-sync symbol) at u[offset + 2n]."""
    step = (p1 - p0) / (2 * FIELD)             # input samples per output half-symbol
    start = p0 - 2 * 4 * step - pad * step
    npts = 2 * FIELD + 2 * pad
    t = start + np.arange(npts) * step
    return sinc_interp(z, t), pad


def training(field_inverted):
    import pn
    seq = np.concatenate([SYNC, pn_levels(pn.PN511), pn_levels(pn.PN63),
                          -pn_levels(pn.PN63) if field_inverted else pn_levels(pn.PN63),
                          pn_levels(pn.PN63), pn_levels(VSB_MODE_8T)])
    return seq                                  # symbols 0 .. 727 of the field sync segment


def fse_matrix(u, off, n_idx, M):
    """Rows: [Re, Im] of u around symbol n (2-sps taps -M..M) plus a bias column."""
    pos = off + 2 * n_idx[:, None] + np.arange(-M, M + 1)[None, :]
    w = u[np.clip(pos, 0, len(u) - 1)]
    return np.hstack([w.real, w.imag, np.ones((len(n_idx), 1), np.float32)])


def train_fse(u, off, M=48, lam=1e-2):
    """Least-squares fractionally-spaced equalizer from the field sync training symbols.
    Tries both signs of the middle PN63 and keeps the better fit."""
    best = None
    for inv in (False, True):
        a = training(inv)
        n = np.arange(len(a))
        X = fse_matrix(u, off, n, M)
        A = X.T @ X + lam * np.eye(X.shape[1]) * np.trace(X.T @ X) / X.shape[1]
        w = np.linalg.solve(A, X.T @ a)
        err = np.mean((X @ w - a) ** 2)
        if best is None or err < best[0]:
            best = (err, w, inv)
    return best
