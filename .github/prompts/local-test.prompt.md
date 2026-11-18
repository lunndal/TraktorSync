---
mode: agent
description: manual test checklist for the current change
---
You are validating a completed project change.

Tasks:
1. Inspect the current git diff and summarize what changed.
2. Propose a short manual test checklist tailored to those changes.
3. Keep tests concrete, simple, and executable by a human in the relevant runtime context.
4. Include quick pass/fail criteria for each step.
5. End with a compact risk note about what is not covered.
6. Where command-line validation is needed, use OS-appropriate assumptions:
	- Windows: PowerShell
	- Linux: Bash with GNU utils

Formatting:
- Use numbered steps.
- Keep each step one sentence where possible.
- Do not include commit, version bump, or push instructions unless explicitly requested.
