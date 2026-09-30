"""Ideal 8VSB transmission as HackRF-style IQ, for testing the receiver front end."""
import numpy as np, scipy.signal as ss, vsb, pn

LV = np.array([-7, -5, -3, -1, 1, 3, 5, 7.])


def field_symbols(rng, nfields, inverted_first=False):
    out = []
    for f in range(nfields):
        fs = np.concatenate([vsb.training(inverted_first ^ (f % 2 == 1)),
                             np.tile(vsb.pn_levels(pn.PN63), 2)[:92], rng.choice(LV, 12)])
        out.append(fs)
        for s in range(312):
            out.append(np.concatenate([vsb.SYNC, rng.choice(LV, 828)]))
    return np.concatenate(out)


def synth(nfields=4, f_pilot=-6.6897e6, snr_db=30, seed=0, echo=None):
    rng = np.random.default_rng(seed)
    a = field_symbols(rng, nfields) + 1.25                 # pilot: DC offset of 1.25
    up = np.zeros(2 * len(a), np.complex64); up[0::2] = a  # 2 samples/symbol
    h = vsb.rrc(4 * 32 + 1, 4, vsb.ROLLOFF) * np.exp(1j * np.pi / 4 * np.arange(4 * 32 + 1))
    xb = ss.fftconvolve(up, h, mode="same")                # complex VSB baseband, pilot at DC
    if echo:
        d, g = echo
        xb = xb + g * np.roll(xb, int(2 * d))
    x = ss.resample_poly(xb, 1430, 1539)                   # 2*Rs -> 20 Msps
    n = np.arange(len(x))
    x = x * np.exp(2j * np.pi * f_pilot / vsb.FS * n)
    p = np.mean(np.abs(x) ** 2)
    x = x + np.sqrt(p / 10 ** (snr_db / 10) / 2) * (rng.normal(size=len(x)) + 1j * rng.normal(size=len(x)))
    x *= 12 / np.sqrt(np.mean(np.abs(x) ** 2))            # ~ -21 dBFS like the capture
    iq = np.empty(2 * len(x), np.int8)
    iq[0::2] = np.clip(np.round(x.real), -128, 127); iq[1::2] = np.clip(np.round(x.imag), -128, 127)
    return iq, a
