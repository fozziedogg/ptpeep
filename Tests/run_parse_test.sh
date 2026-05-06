#!/bin/bash
# Compiles the parser files + test entry point and runs the log writer.
# Usage: bash Tests/run_parse_test.sh Tests/PeepTest.ptx

PTX="${1:-Tests/PeepTest.ptx}"
cd "$(dirname "$0")/.." || exit 1

swiftc \
  PTPeep/Parser/PTXSession.swift \
  PTPeep/Parser/PTXBlockDecoder.swift \
  PTPeep/Parser/PTXParser.swift \
  Tests/PTXParserMain.swift \
  -o /tmp/ptx_parse_test \
  && /tmp/ptx_parse_test "$PTX"
