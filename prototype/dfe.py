"""Adaptive decision-feedback equalizer for 8VSB with decision-directed carrier phase tracking.

Feed-forward taps act on the complex 2-samples/symbol signal (fractionally spaced); the output is
the real part, as VSB puts the data there. Feedback taps cancel post-cursor echoes using past
decisions. Known symbols (field sync training, segment syncs) are used as decisions, so the
equalizer is trained there and runs decision-directed elsewhere.
"""
import numpy as np
from numba import njit

LV = np.array([-7.0, -5.0, -3.0, -1.0, 1.0, 3.0, 5.0, 7.0])


@njit(cache=True)
def _slice(v):
    # nearest of -7,-5,...,7
    k = np.floor((v + 8.0) / 2.0)
    if k < 0: k = 0
    if k > 7: k = 7
    return -7.0 + 2.0 * k


@njit(cache=True)
def run(u, off, nsym, known, kval, w, b, c, theta, hist, M, mu_w, mu_b, mu_th, mu_c):
    """Equalize nsym symbols; symbol n is centred at u[off + 2n]. State (w, b, c, theta, hist)
    is updated in place / returned so consecutive fields continue seamlessly."""
    FB = len(b)
    soft = np.empty(nsym)
    dec = np.empty(nsym)
    L = 2 * M + 1
    for n in range(nsym):
        base = off + 2 * n - M
        cr = np.cos(theta); ci = -np.sin(theta)
        acc_r = 0.0; acc_i = 0.0
        for i in range(L):
            xr = u[base + i].real; xi = u[base + i].imag
            # rotate input by -theta
            rr = xr * cr - xi * ci; ri = xr * ci + xi * cr
            wr = w[i].real; wi = w[i].imag
            acc_r += wr * rr - wi * ri
            acc_i += wr * ri + wi * rr
        y = acc_r + c
        for k in range(FB):
            y -= b[k] * hist[k]
        soft[n] = y
        d = kval[n] if known[n] else _slice(y)
        dec[n] = d
        e = d - y
        # LMS updates
        for i in range(L):
            xr = u[base + i].real; xi = u[base + i].imag
            rr = xr * cr - xi * ci; ri = xr * ci + xi * cr
            w[i] += mu_w * e * complex(rr, -ri)
        for k in range(FB):
            b[k] -= mu_b * e * hist[k]
        c += mu_c * e
        # phase: dy/dtheta = Im(sum w*x_rot) = acc_i
        theta += mu_th * e * acc_i
        # shift decision history
        for k in range(FB - 1, 0, -1):
            hist[k] = hist[k - 1]
        if FB > 0:
            hist[0] = d
    return soft, dec, c, theta
