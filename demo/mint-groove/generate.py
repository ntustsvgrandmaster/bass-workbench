#!/usr/bin/env python3
"""Render original demo assets. Requires NumPy; no samples, models or downloads."""
import hashlib
import json
from pathlib import Path
import wave
import xml.etree.ElementTree as ET

import numpy as np

ROOT = Path(__file__).resolve().parent
SR, BPM, BARS = 44100, 120, 16
SPB = 60 / BPM
LENGTH = 32.5  # 64 quarter notes plus release tail; no count-in
N = round(LENGTH * SR)
STRINGS = [43, 38, 33, 28, 23]  # MusicXML string 1 = highest (G2)
NAMES = [('C', 0), ('C', 1), ('D', 0), ('E', -1), ('E', 0), ('F', 0),
         ('F', 1), ('G', 0), ('A', -1), ('A', 0), ('B', -1), ('B', 0)]
# C, Am, F, G; then Dm, Am, F, G; resolve to C.
CHORDS = [(36, 'major'), (33, 'minor'), (29, 'major'), (31, 'major'),
          (36, 'major'), (33, 'minor'), (29, 'major'), (31, 'major'),
          (26, 'minor'), (33, 'minor'), (29, 'major'), (31, 'major'),
          (26, 'minor'), (31, 'major'), (36, 'major'), (36, 'major')]


def arrangement():
    events = []
    for bar, (root, quality) in enumerate(CHORDS):
        third = 3 if quality == 'minor' else 4
        if bar == 15:
            pattern = [(root, 4, False)]
        elif bar % 4 == 1:
            pattern = [(root + third, 1.5, False), (root + 7, .5, True),
                       (None, .5, False), (root, .5, False), (root + 12, 1, False)]
        elif bar % 4 == 3:
            pattern = [(root + 7, 1, False), (root, 1, False),
                       (root + third, .5, False), (root + 7, .5, False),
                       (root + 12, 1, False)]
        else:
            pattern = [(root, 1, False), (root + 7, .5, False),
                       (root + 12, .5, True), (root + third, 1, False),
                       (root + 7, .5, False), (root + 12, .5, False)]
        beat = bar * 4
        for pitch, duration, staccato in pattern:
            events.append(dict(bar=bar + 1, beat=beat, duration=duration,
                               midi=pitch, staccato=staccato))
            beat += duration
        assert beat == (bar + 1) * 4
    return events


def tone(midi, seconds, kind):
    t = np.arange(round(seconds * SR)) / SR
    f = 440 * 2 ** ((midi - 69) / 12)
    if kind == 'bass':
        y = sum(a * np.sin(2 * np.pi * f * h * t)
                for h, a in [(1, 1), (2, .36), (3, .17), (4, .07)])
        env = (1 - np.exp(-t / .003)) * np.exp(-t / .9)
    else:
        y = sum(a * np.sin(2 * np.pi * f * h * t)
                for h, a in [(1, 1), (2, .22), (3, .08)])
        env = (1 - np.exp(-t / .015)) * np.exp(-t / 1.0)
    release = min(len(t), round(.025 * SR))
    env[-release:] *= np.linspace(1, 0, release)
    return y * env


def place(track, signal, beat, gain):
    start = round(beat * SPB * SR)
    size = min(len(signal), N - start)
    track[start:start + size] += gain * signal[:size]


def audio(events):
    tracks = {name: np.zeros(N) for name in ['bass', 'harmony', 'drums']}
    for e in events:
        if e['midi'] is not None:
            gate = .45 if e['staccato'] else .91
            place(tracks['bass'], tone(e['midi'], e['duration'] * SPB * gate, 'bass'),
                  e['beat'], .24)
    rng = np.random.default_rng(20261123)
    for bar, (root, quality) in enumerate(CHORDS):
        offsets = [0, 3 if quality == 'minor' else 4, 7]
        for beat, duration in [(0, 1.8), (2, 1.8)]:
            for interval in offsets:
                place(tracks['harmony'], tone(root + 24 + interval, duration * SPB, 'keys'),
                      bar * 4 + beat, .085)
        if bar == 15:
            continue
        for beat in [0, 1.5, 2, 3.5]:
            t = np.arange(round(.22 * SR)) / SR
            kick = np.sin(2 * np.pi * (48 * t + 6 * (1 - np.exp(-35 * t))))
            place(tracks['drums'], kick * np.exp(-23 * t), bar * 4 + beat, .36)
        for beat in [1, 3]:
            t = np.arange(round(.16 * SR)) / SR
            noise = rng.uniform(-1, 1, len(t))
            snare = (.75 * noise + .25 * np.sin(2 * np.pi * 185 * t)) * np.exp(-26 * t)
            place(tracks['drums'], snare, bar * 4 + beat, .24)
        for half in range(8):
            t = np.arange(round(.055 * SR)) / SR
            noise = rng.uniform(-1, 1, len(t))
            hat = np.diff(noise, prepend=0) * np.exp(-80 * t)
            place(tracks['drums'], hat, bar * 4 + half / 2, .045 if half % 2 else .065)
    mix = sum(tracks.values())
    gain = .86 / max(abs(mix).max(), *(abs(y).max() for y in tracks.values()))
    # Shared gain, mono PCM16, identical start and length: stems sum to mix
    # with only independent 16-bit rounding error.
    for name, y in dict(tracks, mix=mix).items():
        pcm = np.rint(y * gain * 32767).astype('<i2')
        with wave.open(str(ROOT / f'{name}.wav'), 'wb') as out:
            out.setparams((1, 2, SR, 0, 'NONE', 'not compressed'))
            out.writeframes(pcm.tobytes())


def node(parent, tag, value=None, **attrs):
    e = ET.SubElement(parent, tag, attrs)
    if value is not None:
        e.text = str(value)
    return e


def pitch(parent, midi):
    step, alter = NAMES[midi % 12]
    p = node(parent, 'pitch')
    node(p, 'step', step)
    if alter:
        node(p, 'alter', alter)
    node(p, 'octave', midi // 12 - 1)


def score(events):
    doc = ET.Element('score-partwise', version='4.0')
    node(node(doc, 'work'), 'work-title', 'Mint Groove')
    ident = node(doc, 'identification')
    node(ident, 'creator', 'Bass Harmony Workbench demo generator', type='composer')
    node(ident, 'rights', 'Original synthetic demo; MIT License (see LICENSE.txt)')
    part = node(node(doc, 'part-list'), 'score-part', id='P1')
    node(part, 'part-name', '5-string Electric Bass')
    p = node(doc, 'part', id='P1')
    for bar, (root, quality) in enumerate(CHORDS):
        m = node(p, 'measure', number=str(bar + 1))
        if bar == 0:
            a = node(m, 'attributes')
            node(a, 'divisions', 4)
            node(node(a, 'key'), 'fifths', 0)
            time = node(a, 'time')
            node(time, 'beats', 4)
            node(time, 'beat-type', 4)
            node(a, 'staves', 2)
            for number, sign, line in [('1', 'F', 4), ('2', 'TAB', 5)]:
                c = node(a, 'clef', number=number)
                node(c, 'sign', sign)
                node(c, 'line', line)
            details = node(a, 'staff-details', number='2')
            node(details, 'staff-lines', 5)
            for line, midi in enumerate(reversed(STRINGS), 1):
                step, alter = NAMES[midi % 12]
                tuning = node(details, 'staff-tuning', line=str(line))
                node(tuning, 'tuning-step', step)
                if alter:
                    node(tuning, 'tuning-alter', alter)
                node(tuning, 'tuning-octave', midi // 12 - 1)
            # Bass notation sounds one octave below written; apply to both staves.
            tr = node(a, 'transpose')
            node(tr, 'diatonic', 0)
            node(tr, 'chromatic', 0)
            node(tr, 'octave-change', -1)
            d = node(m, 'direction', placement='above')
            mt = node(node(d, 'direction-type'), 'metronome')
            node(mt, 'beat-unit', 'quarter')
            node(mt, 'per-minute', BPM)
            node(d, 'staff', 1)
            node(d, 'sound', tempo=str(BPM))
        harmony = node(m, 'harmony')
        r = node(harmony, 'root')
        node(r, 'root-step', NAMES[root % 12][0])
        node(harmony, 'kind', quality, text='m' if quality == 'minor' else '')
        node(harmony, 'staff', 1)
        for staff in [1, 2]:
            if staff == 2:
                node(node(m, 'backup'), 'duration', 16)
            for e in [e for e in events if e['bar'] == bar + 1]:
                n = node(m, 'note')
                if e['midi'] is None:
                    node(n, 'rest')
                else:
                    pitch(n, e['midi'] + 12)
                node(n, 'duration', round(e['duration'] * 4))
                node(n, 'voice', staff)
                node(n, 'type', {4: 'whole', 1.5: 'quarter', 1: 'quarter', .5: 'eighth'}[e['duration']])
                if e['duration'] == 1.5:
                    node(n, 'dot')
                node(n, 'staff', staff)
                if e['midi'] is not None:
                    notation = node(n, 'notations')
                    if e['staccato']:
                        node(node(notation, 'articulations'), 'staccato')
                    if staff == 2:
                        candidates = [(i + 1, e['midi'] - open_midi)
                                      for i, open_midi in enumerate(STRINGS)
                                      if 0 <= e['midi'] - open_midi <= 12]
                        string, fret = min(candidates, key=lambda sf: (abs(sf[1] - 5), sf[0]))
                        tech = node(notation, 'technical')
                        node(tech, 'string', string)
                        node(tech, 'fret', fret)
        if bar == BARS - 1:
            node(node(m, 'barline', location='right'), 'bar-style', 'light-heavy')
    ET.indent(doc)
    ET.ElementTree(doc).write(ROOT / 'bass.musicxml', encoding='utf-8', xml_declaration=True)


def main():
    events = arrangement()
    audio(events)
    score(events)
    manifest = dict(title='Mint Groove', bpm=BPM, time_signature='4/4', bars=BARS,
                    first_downbeat_seconds=0, stem_offset_seconds=0,
                    duration_seconds=LENGTH, sample_rate=SR,
                    pitch_convention='MIDI sounding pitch; C4=60; notation written one octave higher',
                    provenance='Original procedural composition and synthesis; no third-party samples',
                    chords=[dict(bar=i+1, root_midi=r, quality=q) for i, (r, q) in enumerate(CHORDS)],
                    bass_events=events,
                    sha256={name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                            for name in ['mix.wav', 'bass.wav', 'harmony.wav', 'drums.wav', 'bass.musicxml']})
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Generated {BARS} bars at {BPM} BPM, {LENGTH}s, 4 synchronized WAV files and MusicXML.')


if __name__ == '__main__':
    main()
