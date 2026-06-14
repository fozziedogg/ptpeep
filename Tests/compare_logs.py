#!/usr/bin/env python3
import re, sys, os

def parse_log(path):
    entries = {}
    track = None
    track_header_re = re.compile(r'^── (.+?) \[.*?\] ─')
    clip_re = re.compile(r'^\s*\[\d+\]\s+(.+?)\s{2,}start=\S+\s+len=\S+\s+file=(\S+)\s+\[(\d+)\](\s+Muted)?')
    with open(path) as f:
        for i, line in enumerate(f, 1):
            m = track_header_re.match(line)
            if m:
                track = m.group(1).strip()
                continue
            m = clip_re.match(line)
            if m and track:
                clip_name = m.group(1).strip()
                file_name = m.group(2)
                sample = int(m.group(3))
                muted = bool(m.group(4))
                if file_name in ('—', '-'):
                    continue
                key = (track, sample)
                if key not in entries:
                    entries[key] = (clip_name, file_name, muted, i)
    return entries

os.chdir(os.path.dirname(os.path.abspath(__file__)))
grouped = parse_log('honeybunch_PeepTest.log')
exposed = parse_log('honeybunch_PeepTestExposed.log')

g_keys = set(grouped.keys())
e_keys = set(exposed.keys())

common = g_keys & e_keys
matches = 0
file_mismatches = []
for k in sorted(common):
    g = grouped[k]
    e = exposed[k]
    if g[1] == e[1]:
        matches += 1
    else:
        file_mismatches.append((k, g, e))

raw_extras = g_keys - e_keys
raw_missing = e_keys - g_keys

def near_miss_filter(candidates, source_dict, ref_dict):
    truly_off = []
    for k in sorted(candidates):
        track, sample = k
        src = source_dict[k]
        found_near = False
        for delta in range(-2000, 2001):
            ref_key = (track, sample + delta)
            if ref_key in ref_dict:
                if ref_dict[ref_key][1] == src[1]:
                    found_near = True
                    break
        if not found_near:
            truly_off.append((k, src))
    return truly_off

truly_extra = near_miss_filter(raw_extras, grouped, exposed)
truly_missing = near_miss_filter(raw_missing, exposed, grouped)

print(f"=== Honeybunch Validation ===")
print(f"Grouped clips:  {len(grouped)}")
print(f"Exposed clips:  {len(exposed)}")
print(f"Common keys:    {len(common)}")
print(f"Exact matches:  {matches}")
print(f"File mismatches: {len(file_mismatches)}")
print(f"Raw extras (grouped not in exposed): {len(raw_extras)}")
print(f"Raw missing (exposed not in grouped): {len(raw_missing)}")
print(f"Near-miss extras filtered: {len(raw_extras) - len(truly_extra)}")
print(f"Near-miss missing filtered: {len(raw_missing) - len(truly_missing)}")
print(f"Truly extra:    {len(truly_extra)}")
print(f"Truly missing:  {len(truly_missing)}")

if file_mismatches:
    print(f"\n--- File Mismatches (first 5) ---")
    for k, g, e in file_mismatches[:5]:
        print(f"  Track={k[0]}  Sample={k[1]}")
        print(f"    Grouped: {g[0]}  file={g[1]}")
        print(f"    Exposed: {e[0]}  file={e[1]}")

if truly_extra:
    print(f"\n--- Truly Extra (first 5) ---")
    for k, info in truly_extra[:5]:
        print(f"  Track={k[0]}  Sample={k[1]}  clip={info[0]}  file={info[1]}{'  Muted' if info[2] else ''}")

if truly_missing:
    print(f"\n--- Truly Missing (first 5) ---")
    for k, info in truly_missing[:5]:
        print(f"  Track={k[0]}  Sample={k[1]}  clip={info[0]}  file={info[1]}{'  Muted' if info[2] else ''}")

print(f"\nAccuracy: {matches}/{len(exposed)} = {matches/len(exposed)*100:.1f}%")
