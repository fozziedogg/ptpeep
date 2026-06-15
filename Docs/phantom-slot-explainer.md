# Phantom Slots: How 0x2425 Fixes Sentinel Slot Alignment

## The Sentinel Slot Table

PT allocates sentinel slots sequentially, one block per GID (group family):

```
  GID 0        GID 1      GID 2         GID 3
 (3 members)  (2 members) (1 member)   (4 members)
 ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
 │ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │  ← slot index
 └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
```

## What Happens When a Group Member Is Deleted

Say GID 1 originally had 3 members. User deletes the middle one.

The compound pool entry is removed, but the sentinel slot stays:

```
  Compound pool:                            Sentinel table:
  ┌─────────┐                               GID 0       GID 1        GID 2
  │ pos = 0 │  ← survives                  (3 members) (3 members!) (1 member)
  ├─────────┤                               ┌───┬───┬───┬───┬───┬───┬───┬──
  │ pos = 1 │  ← DELETED                   │ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ ...
  ├─────────┤                               └───┴───┴───┴───┴───┴───┴───┴──
  │ pos = 2 │  ← survives                            ▲
  └─────────┘                                        │
                                                  phantom
                                                  (empty but
                                                   still there)
```

## The Bug (before fix)

We counted slots by looking at surviving compounds only:

```
  "GID 1 max surviving pos = 2  →  3 slots"   ← happens to work (lucky)
  "GID 1 max surviving pos = 1  →  2 slots"   ← WRONG if pos=2 was deleted
```

When we undercount by 1 slot, everything after shifts:

```
  What we thought:           GID 1      GID 2         GID 3
                            (2 slots)  (1 slot)      (4 slots)
                            ┌───┬───┬───┬───┬───┬───┬───┐
  Our slot index:           │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │
                            └───┴───┴───┴───┴───┴───┴───┘

  Reality:                   GID 1        GID 2         GID 3
                            (3 slots!)   (1 slot)      (4 slots)
                            ┌───┬───┬───┬───┬───┬───┬───┬───┐
  Real slot index:          │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │10 │
                            └───┴───┴───┴───┴───┴───┴───┴───┘
                                        ↑
                                     phantom     ← we missed this

  GID 2 thinks it's slot 5, but it's really slot 6.
  GID 3 thinks it starts at slot 6, but really starts at 7.
  Every GID after the gap is off by 1. Multiple gaps accumulate.

                        ┌──────────────────────────────────┐
                        │  In honeybunch: hundreds of GIDs │
                        │  with multiple deletions = the   │
                        │  mysterious "offset of 72" that  │
                        │  we could never explain.         │
                        └──────────────────────────────────┘
```

## The Fix: 0x2425 Blocks

PT stores one 0x2425 block per GID with the TRUE member count:

```
  0x2425[0]:  members = 3     ← includes all original members
  0x2425[1]:  members = 3     ← even though one was deleted!
  0x2425[2]:  members = 1
  0x2425[3]:  members = 4

  Now the slot table lines up perfectly:

  GID 0       GID 1        GID 2      GID 3
  (3)         (3 ✓)        (1)        (4)
  ┌───┬───┬───┬───┬───┬───┬───┬───┬───┬───┬───┐
  │ 0 │ 1 │ 2 │ 3 │ 4 │ 5 │ 6 │ 7 │ 8 │ 9 │10 │
  └───┴───┴───┴───┴───┴───┴───┴───┴───┴───┴───┘
                      ▲
                   phantom — correctly accounted for,
                   downstream slots are aligned
```

Commit: f21cacf. One line changed in `PTXBlockDecoder.swift` slot mapping loop, plus 6 lines to read 0x2425 blocks.
