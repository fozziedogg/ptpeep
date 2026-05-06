#!/usr/bin/env swift
// Quick parse test — run with: swift Tests/parse_test.swift Tests/PeepTest.ptx

import Foundation

// ── Inline the source files ──────────────────────────────────────────────────
// (swiftc can't import project modules directly; we paste what we need)

// Pull in the three parser files as compile units by re-stating the path via
// the compiler's -Xfrontend pass. Since we can't do that in a script, we just
// compile all four files together below. Run this via the shell wrapper instead.

print("Use the shell wrapper: bash Tests/run_parse_test.sh Tests/PeepTest.ptx")
