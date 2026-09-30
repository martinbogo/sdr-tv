import sys, numpy as np, vsb, dfe, synth_vsb
S = "./scratch/"   # where the test reads and writes its data

def equalize(z, pk, M=32, FB=64, mus=(3e-4, 1e-3, 2e-4, 1e-4), truth=None, verbose=True):
    z = z / np.sqrt(np.mean(np.abs(z) ** 2))              # unit power: keeps LMS steps meaningful
    u0, off0 = vsb.field_grid(z, pk[0], pk[1], pad=200)
    err, wls, inv = vsb.train_fse(u0, off0, M=M)
    L = 2 * M + 1
    w = (wls[:L] - 1j * wls[L:2 * L]).astype(np.complex128)
    b = np.zeros(FB); hist = np.zeros(FB); c = float(wls[-1]); theta = 0.0
    N = vsb.FIELD
    outs = []
    for f in range(len(pk) - 1):
        u, off = vsb.field_grid(z, pk[f], pk[f + 1], pad=200)
        known = np.zeros(N, np.bool_); kval = np.zeros(N)
        tr = vsb.training(inv ^ (f % 2 == 1)); known[:len(tr)] = True; kval[:len(tr)] = tr
        n = np.arange(N); s4 = (n % 832) < 4; known |= s4; kval[s4] = vsb.SYNC[(n % 832)[s4]]
        soft, dec, c, theta = dfe.run(u.astype(np.complex128), off, N, known, kval, w, b, c, theta, hist, M, *mus)
        m = ~known
        tsnr = 10 * np.log10(21 / np.mean((soft[:len(tr)] - kval[:len(tr)]) ** 2))
        line = f"field {f}: training SNR {tsnr:5.1f} dB"
        if truth is not None:
            t = truth[f * N:(f + 1) * N] - 1.25
            line += f", true data SNR {10*np.log10(21/np.mean((soft[m]-t[m])**2)):5.1f} dB, symbol errors {np.mean(dec[m]!=t[m])*100:5.2f}%"
        if verbose: print(line + f", phase {theta:+.2f}")
        outs.append((soft, dec, known))
    return outs

if __name__ == "__main__":
    iq, a = synth_vsb.synth(nfields=5, echo=(3, 0.77 * np.exp(1j * 0.7)), snr_db=28)
    iq.tofile(S + "t.iq")
    x = vsb.load(S + "t.iq")
    fp = vsb.find_pilot(x, -6.69e6)
    n = np.arange(len(x)); y = x * np.exp(-2j * np.pi * fp / vsb.FS * n).astype(np.complex64)
    z = vsb.matched_2sps(y)
    pk = vsb.find_field_syncs(z)
    # align truth: field sync peak pk[0] is PN511 start = symbol 4 of field 0
    equalize(z, pk, truth=a)
