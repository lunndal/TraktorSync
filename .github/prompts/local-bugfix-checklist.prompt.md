---
mode: agent
description: bugfix checklist with regression focus
---
You are reviewing a bugfix

Tasks:
1. Identify the intended bug behavior change from the current diff and nearby code.
2. List the most likely regressions introduced by this fix.
3. Produce a focused manual checklist that verifies:
   - the bug is fixed,
   - adjacent behavior still works,
   - no obvious regressions were introduced.
4. Include one negative test (unexpected input or edge flow) when relevant.
5. If tracker docs need updates, note the expected `BF###` changelog entry and any required bullet removal in `docs/BUGS.md`.

Output format:
- Section 1: "Bugfix intent" (2-4 bullets)
- Section 2: "Regression risks" (2-6 bullets)
- Section 3: "Manual checklist" (numbered)
