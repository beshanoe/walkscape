"""Summarize an Espresso network (.espresso.net JSON + .espresso.shape JSON).

Usage: python3 -I espresso_summary.py <path/to/model.espresso.net>
Prints graph inputs/outputs with shapes, layer-type histogram, and conv stats.
"""

import collections
import json
import pathlib
import sys

net_path = pathlib.Path(sys.argv[1])
net = json.loads(net_path.read_text())
shape_path = net_path.with_name(net_path.name.replace(".espresso.net", ".espresso.shape"))
shapes = {}
if shape_path.exists():
    shapes = json.loads(shape_path.read_text()).get("layer_shapes", {})

layers = net.get("layers", [])
produced = collections.Counter()
consumed = collections.Counter()
for layer in layers:
    for t in str(layer.get("top", "")).split(","):
        if t:
            produced[t] += 1
    for b in str(layer.get("bottom", "")).split(","):
        if b:
            consumed[b] += 1


def fmt(name: str) -> str:
    s = shapes.get(name)
    if not s:
        return name
    dims = [s.get(k) for k in ("n", "k", "h", "w") if k in s]
    return f"{name} {dims}"


inputs = sorted(b for b in consumed if b not in produced)
outputs = sorted(t for t in produced if t not in consumed)
print("format_version:", net.get("format_version"), " layers:", len(layers))
print("inputs:")
for i in inputs:
    print("  ", fmt(i))
print("outputs:")
for o in outputs:
    print("  ", fmt(o))
types = collections.Counter(layer.get("type") for layer in layers)
print("layer types:", ", ".join(f"{t}×{n}" for t, n in types.most_common()))
names = [layer.get("name", "") for layer in layers]
interesting = [
    n
    for n in names
    if any(k in n.lower() for k in ("attn", "attention", "softmax", "memory", "mem", "gru", "lstm", "query", "key", "value", "affinity", "readout", "decoder", "encoder", "backbone", "upsample"))
]
print("sample layer names:", ", ".join(interesting[:40]))
