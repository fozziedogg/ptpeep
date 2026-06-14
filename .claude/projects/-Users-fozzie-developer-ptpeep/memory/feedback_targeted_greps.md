---
name: Use targeted Grep instead of full file reads
description: Always use Grep to find line numbers then Read with offset/limit; never read large files whole
type: feedback
---

Use Grep to locate code before reading it. Never read a large file in full when a targeted approach works.

**Why:** Full file reads (1000+ line Swift files) waste tokens significantly.

**How to apply:**
1. Grep for the function/symbol name with `output_mode: "content"` and `context: 5–10` to see it inline
2. If edits are needed, Grep to get the line number, then `Read` with `offset` + `limit` to confirm the exact text
3. Only read a full file when truly necessary (e.g., first-time architectural understanding of a new file)
