---
mode: agent
description: pre-release and send readiness check
---
You are preparing a release readiness review.

Tasks:
1. Review changed files and classify each change as feature, fix, docs, or refactor.
2. Verify tracker docs are aligned with workspace rules:
   - docs/CHANGELOG.md has entries for implemented features and fixes.
   - docs/BUGS.md or docs/IDEAS.md has only the single completed bullet removed when applicable.
   - tracker IDs follow F###, BF###, Q###, A### conventions.
3. Report any gaps or mismatches as an action list.
4. If everything is aligned, output a short "ready for patch/minor/major send" summary.
5. Keep release guidance tool-agnostic (do not assume package-manager-specific release tooling).

Constraints:
- Do not run destructive git commands.
- Do not create commits or tags unless explicitly asked.
- Prioritize concrete findings over long explanations.
