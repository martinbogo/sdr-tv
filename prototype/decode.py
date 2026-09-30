"""Offline ATSC 1.0 decoder: HackRF IQ capture -> MPEG transport stream.

    python3 decode.py <capture.iq> <pilot offset Hz> <out.ts> [seconds]
"""
import sys, time
import numpy as np
import vsb, dfe, fec


def equalize_fields(z, pk, M=32, FB=64, warm=12, mus=(3e-4, 3e-5, 1e-4, 1e-5)):
    """Adaptive DFE over every field. The first `warm` fields are run twice so the taps have
    converged before any output is kept."""
    z = z / np.sqrt(np.mean(np.abs(z) ** 2))
    u0, off0 = vsb.field_grid(z, pk[0], pk[1], pad=200)
    err, wls, inv0 = vsb.train_fse(u0, off0, M=M)
    L = 2 * M + 1
    w = (wls[:L] - 1j * wls[L:2 * L]).astype(np.complex128)
    b = np.zeros(FB); hist = np.zeros(FB); c = float(wls[-1]); theta = 0.0
    N = vsb.FIELD
    n = np.arange(N)
    s4 = (n % 832) < 4
    nfield = len(pk) - 1
    order = list(range(min(warm, nfield))) + list(range(nfield))
    soft_out, snrs = {}, {}
    for pass_i, f in enumerate(order):
        u, off = vsb.field_grid(z, pk[f], pk[f + 1], pad=200)
        known = s4.copy(); kval = np.zeros(N); kval[s4] = vsb.SYNC[(n % 832)[s4]]
        tr = vsb.training(inv0 ^ (f % 2 == 1)); known[:len(tr)] = True; kval[:len(tr)] = tr
        soft, dec, c, theta = dfe.run(u.astype(np.complex128), off, N, known, kval, w, b, c, theta,
                                      hist, M, *mus)
        if pass_i >= min(warm, nfield):
            soft_out[f] = soft
            snrs[f] = 10 * np.log10(21 / np.mean((soft[:len(tr)] - kval[:len(tr)]) ** 2))
    return [soft_out[f] for f in range(nfield)], [snrs[f] for f in range(nfield)]


def data_symbols(soft):
    """312 x 828 data symbols of one field (skipping the field sync segment and segment syncs)."""
    return soft[832:].reshape(312, 832)[:, 4:].ravel()


def main(path, f_pilot, out, seconds=1.5):
    t0 = time.time()
    x = vsb.load(path, seconds=seconds)
    fp = vsb.find_pilot(x, f_pilot)
    y, _ = vsb.pilot_to_dc(x, fp)
    del x
    z = vsb.matched_2sps(y)
    del y
    pk = vsb.find_field_syncs(z)
    print(f"front end: pilot {fp/1e3:.3f} kHz, {len(pk)} field syncs ({time.time()-t0:.1f}s)")
    softs, snrs = equalize_fields(z, pk)
    print(f"equalizer: training SNR per field {np.round(snrs, 1)} ({time.time()-t0:.1f}s)")
    fields = np.array([data_symbols(s) for s in softs])
    inter = fec.trellis_decode(fields)                   # (nfields, 64584) interleaved bytes
    print(f"trellis decoded {inter.size} bytes ({time.time()-t0:.1f}s)")
    stream = inter.ravel()
    deint = fec.deinterleave(stream)
    ncw = len(deint) // 207
    cws = deint[:ncw * 207].reshape(ncw, 207).astype(np.int64)
    # sanity: count codewords with zero syndromes before correction
    clean = sum(fec._syndromes(cws[i].copy(), fec.GF_EXP, fec.GF_LOG).max() == 0 for i in range(ncw))
    fixed = np.array([fec.rs_decode(cws[i], fec.GF_EXP, fec.GF_LOG) for i in range(ncw)])
    print(f"Reed-Solomon: {ncw} codewords, {clean} error-free, {np.sum(fixed > 0)} corrected, "
          f"{np.sum(fixed < 0)} uncorrectable ({time.time()-t0:.1f}s)")
    return cws, fixed


if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]), sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 1.5)


def to_ts(cws, fixed, variant):
    """Derandomize the 187 data bytes of each good codeword and prepend the 0x47 sync byte.
    The randomizer restarts at every data field (312 packets)."""
    prbs = fec.prbs_bytes(312 * 187, variant).reshape(312, 187)
    pkts = []
    for t in range(len(cws)):
        if fixed[t] < 0:
            continue
        data = cws[t, :187].astype(np.uint8) ^ prbs[t % 312]
        pkts.append(np.concatenate([[0x47], data]).astype(np.uint8))
    return np.array(pkts)


def pid_summary(pkts):
    pid = ((pkts[:, 1].astype(int) & 0x1F) << 8) | pkts[:, 2]
    tei = (pkts[:, 1] & 0x80) != 0
    u, cnt = np.unique(pid, return_counts=True)
    top = sorted(zip(cnt, u), reverse=True)[:8]
    return tei.mean(), len(u), top
