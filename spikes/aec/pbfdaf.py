"""Linear-only echo canceller: partitioned-block frequency-domain adaptive filter (overlap-save NLMS).

Subtracts the predicted speaker→room→mic path of the known reference and never gates the
near-end, so a voice sung over constant music is preserved (unlike call-oriented AECs whose
residual suppressor treats constant far-end as permanent double-talk).
"""

import numpy as np


def pbfdaf(mic, ref, block=512, partitions=32, mu=0.5, eps=1e-6, freeze_ratio=4.0):
    n_fft = 2 * block
    bins = block + 1
    W = np.zeros((partitions, bins), dtype=np.complex128)
    X = np.zeros((partitions, bins), dtype=np.complex128)
    power = np.full(bins, 1e-3)
    prev_ref = np.zeros(block)
    out = np.zeros(len(mic) // block * block)

    for start in range(0, len(out), block):
        cur_ref = ref[start:start + block]
        X = np.roll(X, 1, axis=0)
        X[0] = np.fft.rfft(np.concatenate([prev_ref, cur_ref]))
        prev_ref = cur_ref

        echo = np.fft.irfft((W * X).sum(axis=0))[block:]
        err = mic[start:start + block] - echo
        out[start:start + block] = err

        # crude double-talk guard: slow adaptation while the residual is much louder than the echo estimate
        e_pow, y_pow = np.mean(err ** 2), np.mean(echo ** 2) + 1e-12
        step = mu if e_pow < freeze_ratio * y_pow else mu * 0.05

        E = np.fft.rfft(np.concatenate([np.zeros(block), err]))
        power = 0.9 * power + 0.1 * np.abs(X[0]) ** 2
        grad = np.conj(X) * E / (partitions * power + eps)  # normalize by total filter input power
        g = np.fft.irfft(grad, n=n_fft, axis=1)
        g[:, block:] = 0  # gradient constraint (keeps it a linear convolution)
        W += step * np.fft.rfft(g, axis=1)
    return out.astype(np.float32)
