# Sentinel Mapping Test Session Recipe

## Purpose
Build a controlled test session to crack the compound→sentinel mapping problem. Each save isolates one variable: basic mapping, empty groups, splits, slot reuse.

## Session Setup
Create a new session (any sample rate). Create 6 mono audio tracks. Record or import short distinct clips onto each — name them so they're instantly recognizable:

| Track | Clip name |
|-------|-----------|
| 1 | Apple |
| 2 | Banana |
| 3 | Cherry |
| 4 | Dog |
| 5 | Eagle |
| 6 | Fox |

Make sure each clip is at a different timeline position (doesn't matter where, just not overlapping across tracks you'll group).

## Step-by-Step Saves

### Save 1 — `SentinelTest_01_baseline.ptx`
No groups yet. Just the 6 clips on 6 tracks. (Gives us the "ungrouped" reference.)

### Save 2 — `SentinelTest_02_twogroups.ptx`
1. Select Apple + Banana + Cherry (tracks 1-3), group them → should auto-name "Group-01" or similar. **Rename it to "ABC"**
2. Select Dog + Eagle (tracks 4-5), group them → **Rename to "DE"**
3. Save

### Save 3 — `SentinelTest_03_emptygroup.ptx`
1. Create an empty clip group (select nothing, or select an empty region) — if PT won't let you create a truly empty group, select a tiny silent region on a new blank track, group it, then delete the audio from inside. The goal is to have a group with no meaningful audio. **Name it "EmptySlot"**
2. Save

### Save 4 — `SentinelTest_04_thirdgroup.ptx`
1. Select Fox (track 6) by itself, group it → **Rename to "F_solo"**
2. Save

### Save 5 — `SentinelTest_05_split.ptx`
1. Use Separate (Command+E or Edit > Separate Clip) to split group "ABC" into two pieces at roughly the midpoint. PT should create two new compound clips (something like "ABC-01" and "ABC-02" or similar split names)
2. **Don't rename them** — let PT auto-name so we can see what it does
3. Save

### Save 6 — `SentinelTest_06_regroup.ptx`
1. Ungroup one of the ABC split pieces
2. Regroup it (select the now-exposed clips and make a new group) → **Rename to "Rebuilt"**
3. Save

## Honeybunch Ground Truth
Save As `honeybunch_PeepTestD_ungrouped.ptx`, then select all, ungroup everything (Edit > Ungroup All), save. This gives ground truth for the existing complex session.

## What Each Save Tests
- **Saves 1-2:** Verify basic counter=sentinel mapping
- **Save 3:** Test whether empty groups consume a sentinel slot (empty-slot offset theory)
- **Save 4:** Verify the offset after an empty group
- **Save 5:** The split case — the exact operation that breaks the counter
- **Save 6:** Regroup after ungroup — tests slot reuse

## Diagnostic Scripts
Run against each .ptx file (from project root):
```bash
swift Tests/sentinel_diag2.swift Tests/SentinelTest_XX.ptx
swift Tests/sentinel_diag6.swift Tests/SentinelTest_XX.ptx
```
