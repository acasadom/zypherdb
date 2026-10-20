"""Prints result files side by side, and the queries whose answers differ.

    python bench/comparison/table.py results/python-acmedb-10k.jsonl results/python-kuzu-10k.jsonl ...
"""
import json, sys
files = sys.argv[1:]
data = [{r["query"]: r for r in map(json.loads, open(f))} for f in files]
def fmt(r):
    if r is None: return "-"
    if "error" in r: return "error"
    if "seconds" in r: return f"{r['seconds']:.2f} s"
    us = r["median_us"]
    return f"{us/1e6:.2f} s" if us >= 1e6 else f"{us/1000:.1f} ms" if us >= 1000 else f"{us:.0f} µs"
print(f"{'query':<32}" + "".join(f"{f.rsplit('/', 1)[-1].replace('.jsonl', ''):>15}" for f in files))
for q in data[0]:
    print(f"{q:<32}" + "".join(f"{fmt(d.get(q)):>15}" for d in data))
print()
for q in data[0]:
    answers = [d.get(q, {}).get("answers") for d in data]
    if answers[0] and any(a != answers[0] for a in answers[1:]):
        print("DIFFER:", q, [str(a)[:80] for a in answers])
