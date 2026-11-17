#!/usr/bin/env python3
"""Packs the next-word network (vikey-data lm_en/train_nn.py: LSTM, tied embeddings) into iOS/Keyboard/SuggestNN.bin
for SuggestNN.swift. Run after pack_lm.py, with the venv that has torch:

    ~/.venvs/vikeydata/bin/python Tools/suggest/pack_nn.py [--src mix_r4] [--model lstm.pt]       English: SuggestNN.bin
    ~/.venvs/vikeydata/bin/python Tools/suggest/pack_nn.py --data ~/Work/vikey-data/lm_vi --model lstm_vi.pt \
        --lm SuggestVI --out SuggestVINN                                                          Vietnamese

Layout, little-endian, 4-byte aligned:
  "VKNN0001", then u32: V (network words, 4 markers first), E, H, nWords (SuggestEN.bin's)
  nnOf u16[nWords]     SuggestEN word id -> network id (0 = <unk>: not one of the network's words); pad
  emb f32[V*E]         token embeddings, also the output layer (tied)
  wih f32[4H*E], whh f32[4H*H]   LSTM weights, gates i, f, g, o (PyTorch order)
  bias f32[4H]         b_ih + b_hh
  projW f32[E*H], projB f32[E]   hidden -> embedding size
  outB f32[V]          output bias
float32 so Accelerate's BLAS reads the mapped file directly: its pages stay clean (not the keyboard's footprint).
"""
import os, struct, sys
import numpy as np, torch
HERE = os.path.dirname(os.path.abspath(__file__))
src = sys.argv[sys.argv.index('--src') + 1] if '--src' in sys.argv else 'mix_r4'
model = sys.argv[sys.argv.index('--model') + 1] if '--model' in sys.argv else 'lstm.pt'
def arg(k, d): return sys.argv[sys.argv.index(k) + 1] if k in sys.argv else d
D = os.path.expanduser(arg('--data', f'~/Work/vikey-data/lm_en/{src}'))
OUT = os.path.join(HERE, '..', '..', 'iOS', 'Keyboard', arg('--out', 'SuggestNN') + '.bin')
LM = os.path.join(HERE, '..', '..', 'iOS', 'Keyboard', arg('--lm', 'SuggestEN') + '.bin')

sd = torch.load(os.path.join(D, model), map_location='cpu')
emb = sd['emb.weight'].numpy(); V, E = emb.shape
wih, whh = sd['rnn.weight_ih_l0'].numpy(), sd['rnn.weight_hh_l0'].numpy(); H = whh.shape[1]
bias = (sd['rnn.bias_ih_l0'] + sd['rnn.bias_hh_l0']).numpy()
projW, projB, outB = sd['proj.weight'].numpy(), sd['proj.bias'].numpy(), sd['bias'].numpy()
nnv = [l.rstrip('\n') for l in open(os.path.join(D, 'nn_vocab.txt'), encoding='utf-8')]
NID = {w: i for i, w in enumerate(nnv)}

# SuggestEN.bin's words, in id order (its keys, before any display form)
b = open(LM, 'rb').read()
assert b[:8] == b'VKLM0002'
n = struct.unpack_from('<I', b, 8)[0]; blob_bytes = struct.unpack_from('<I', b, 8 + 16)[0]
offs = struct.unpack_from(f'<{n + 1}I', b, 32); blob = 32 + 4 * (n + 1)
keys = [b[blob + offs[i]:blob + offs[i + 1]].split(b'\t')[0].decode() for i in range(n)]
nn_of = [NID.get(k, 0) for k in keys]

def pad(x): return x + b'\0' * (-len(x) % 4)
f32 = lambda a: np.ascontiguousarray(a, dtype='<f4').tobytes()
out = b'VKNN0001' + struct.pack('<4I', V, E, H, n) + pad(struct.pack(f'<{n}H', *nn_of))
out += f32(emb) + f32(wih) + f32(whh) + f32(bias) + f32(projW) + f32(projB) + f32(outB)
open(OUT, 'wb').write(out)
print(f'V {V}, E {E}, H {H}; {sum(x > 0 for x in nn_of)} of {n} words in the network -> {os.path.relpath(OUT)} {len(out) / 1e6:.1f} MB')
