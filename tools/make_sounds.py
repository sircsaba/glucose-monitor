"""Makes the app's alarm sounds (original, synthesized here, free to use).

Run:  python3 tools/make_sounds.py   (needs numpy and scipy)
Writes 10 WAV files into assets/sounds/.
"""
import os

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, lfilter

SR = 22050
OUT = os.path.join(os.path.dirname(__file__), '..', 'assets', 'sounds')
rng = np.random.default_rng(7)


def note_hz(n):
    """MIDI note number to frequency."""
    return 440.0 * 2 ** ((n - 69) / 12)


def t_axis(sec):
    return np.arange(int(sec * SR)) / SR


def env(length, attack=0.01, decay=1.0):
    t = np.arange(length) / SR
    e = np.exp(-t / decay)
    a = int(attack * SR)
    if a > 0:
        e[:a] *= np.linspace(0, 1, a)
    return e


def add(buf, sig, at):
    i = int(at * SR)
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[: j - i]


def piano(freq, dur=2.2):
    t = t_axis(dur)
    s = (np.sin(2 * np.pi * freq * t) + 0.45 * np.sin(4 * np.pi * freq * t) + 0.2 * np.sin(6 * np.pi * freq * t)
         + 0.08 * np.sin(8 * np.pi * freq * t))
    return s * env(len(t), 0.008, 0.7)


def bell(freq, dur=3.0, decay=1.2):
    t = t_axis(dur)
    parts = [(1.0, 1.0), (2.76, 0.5), (5.40, 0.25), (8.93, 0.12)]
    s = sum(a * np.sin(2 * np.pi * freq * r * t) * np.exp(-t / (decay / r ** 0.5)) for r, a in parts)
    return s * env(len(t), 0.003, 10)


def pluck(freq, dur=2.0, damp=0.996):
    n = int(dur * SR)
    period = int(SR / freq)
    buf = rng.uniform(-1, 1, period)
    out = np.zeros(n)
    for i in range(n):
        out[i] = buf[i % period]
        buf[i % period] = damp * 0.5 * (buf[i % period] + buf[(i + 1) % period])
    return lfilter(*butter(2, 3000 / (SR / 2)), out)


def strings(freqs, dur):
    t = t_axis(dur)
    s = np.zeros(len(t))
    for f in freqs:
        vib = 1 + 0.003 * np.sin(2 * np.pi * 5 * t)
        for h in range(1, 7):
            s += (1 / h) * np.sin(2 * np.pi * f * h * vib * t + rng.uniform(0, 6))
    s = lfilter(*butter(2, 2200 / (SR / 2)), s)
    a = int(0.7 * SR)
    e = np.ones(len(t))
    e[:a] = np.linspace(0, 1, a)
    e[-a:] = np.linspace(1, 0, a)
    return s * e


def finish(name, x, fade=0.05):
    x = x - np.mean(x)
    f = int(fade * SR)
    if f > 0:
        x[:f] *= np.linspace(0, 1, f)
        x[-f:] *= np.linspace(1, 0, f)
    peak = np.max(np.abs(x)) or 1.0
    x = x / peak * 0.7
    wavfile.write(os.path.join(OUT, name + '.wav'), SR, (x * 32767).astype(np.int16))
    print('wrote', name, round(len(x) / SR, 1), 's')


def main():
    os.makedirs(OUT, exist_ok=True)

    # 1. Morning mist: soft piano arpeggio over a quiet pad.
    buf = np.zeros(int(8.5 * SR))
    seq = [60, 64, 67, 72, 69, 67, 64, 67, 57, 60, 64, 69, 67, 64, 62, 64]
    for i, n in enumerate(seq):
        add(buf, piano(note_hz(n)) * 0.6, i * 0.5)
    buf += 0.15 * strings([note_hz(48), note_hz(55)], 8.5)
    finish('morning_mist', buf, 0.3)

    # 2. Lullaby strings: slow chords.
    chords = [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
    buf = np.zeros(int(10.5 * SR))
    for i, c in enumerate(chords):
        add(buf, strings([note_hz(n) for n in c], 3.0) * 0.5, i * 2.5)
    finish('lullaby_strings', buf, 0.4)

    # 3. Ocean calm: swelling filtered noise and a low pad.
    t = t_axis(10)
    noise = np.cumsum(rng.normal(0, 1, len(t)))
    noise = noise - lfilter(*butter(1, 0.5 / (SR / 2), 'low'), noise)
    noise = lfilter(*butter(2, 900 / (SR / 2)), noise)
    noise /= np.max(np.abs(noise))
    swell = 0.35 + 0.65 * (0.5 - 0.5 * np.cos(2 * np.pi * t / 5.0))
    buf = noise * swell * 0.8 + 0.25 * strings([note_hz(45), note_hz(52), note_hz(57)], 10)
    finish('ocean_calm', buf, 0.5)

    # 4. Wind chimes.
    buf = np.zeros(int(9 * SR))
    scale = [72, 74, 76, 79, 81, 84, 86, 88]
    at = 0.0
    while at < 7.5:
        add(buf, bell(note_hz(int(rng.choice(scale))), 2.5, 0.9) * rng.uniform(0.3, 0.7), at)
        at += rng.uniform(0.18, 0.6)
    finish('wind_chimes', buf, 0.3)

    # 5. Soft guitar: plucked arpeggio.
    buf = np.zeros(int(8.5 * SR))
    pattern = [55, 59, 62, 67, 62, 59, 57, 60, 64, 69, 64, 60, 55, 59, 62, 67]
    for i, n in enumerate(pattern):
        add(buf, pluck(note_hz(n), 2.0) * 0.6, i * 0.5)
    finish('soft_guitar', buf, 0.3)

    # 6. Music box: an original little tune.
    tune = [(76, 0.4), (79, 0.4), (84, 0.8), (83, 0.4), (79, 0.4), (81, 0.8), (79, 0.4), (76, 0.4), (77, 0.4),
            (74, 0.4), (76, 1.2)]
    buf = np.zeros(int(7.5 * SR))
    at = 0.0
    for n, d in tune:
        tt = t_axis(1.6)
        f = note_hz(n)
        s = (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * 3 * f * tt)) * env(len(tt), 0.002, 0.45)
        add(buf, s * 0.6, at)
        at += d
    finish('music_box', buf, 0.3)

    # 7. Gentle bell every 2 seconds.
    buf = np.zeros(int(6 * SR))
    for i in range(3):
        add(buf, bell(note_hz(69), 2.0, 1.0), i * 2.0)
    finish('gentle_bell', buf)

    # 8. Classic alarm clock: bursts of fast beeps.
    buf = np.zeros(int(4 * SR))
    tb = t_axis(0.07)
    beep = np.sign(np.sin(2 * np.pi * 2300 * tb)) * 0.5 + 0.5 * np.sin(2 * np.pi * 2300 * tb)
    for burst in range(4):
        for k in range(4):
            add(buf, beep, burst * 1.0 + k * 0.12)
    finish('classic_alarm', buf, 0.005)

    # 9. Beeps.
    buf = np.zeros(int(3 * SR))
    tb = t_axis(0.15)
    beep = np.sin(2 * np.pi * 880 * tb) * env(len(tb), 0.005, 10)
    for burst in range(2):
        for k in range(3):
            add(buf, beep, burst * 1.5 + k * 0.3)
    finish('beeps', buf, 0.005)

    # 10. Siren: rising and falling tone.
    t = t_axis(4.8)
    f = 600 + 800 * (0.5 - 0.5 * np.cos(2 * np.pi * t / 1.2))
    phase = 2 * np.pi * np.cumsum(f) / SR
    tri = 2 / np.pi * np.arcsin(np.sin(phase))
    finish('siren', tri, 0.01)


if __name__ == '__main__':
    main()
