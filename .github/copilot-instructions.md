# Workspace instructions

- Be terse.
- Assume the user is a knowledgeable IT professional.
- Keep guidance and docs project-agnostic.
- Keep tracking IDs consistent: F### features, BF### bug fixes, Q### questions, A### answers.
- When a feature is implemented, remove exactly one matching bullet from docs/IDEAS.md and add an F### entry to docs/CHANGELOG.md.
- When a bug is fixed, remove exactly one matching bullet from docs/BUGS.md and add a BF### entry to docs/CHANGELOG.md.
- When a question is answered, move it from open to answered in docs/QUESTIONS.md and include an A### answer block.
- Release trigger terms are only: patch send, minor send, major send.
- patch send means: make a patch version release commit/tag, then push commits and tags.
- minor send means: make a minor version release commit/tag, then push commits and tags.
- major send means: make a major version release commit/tag, then push commits and tags.
- Do not assume package-manager-specific release tooling.
- Shell assumptions: on Windows use PowerShell; on Linux use Bash with GNU utils.
- Before release actions, wait for explicit user confirmation that testing is acceptable.
- Use conventional commits and include relevant tracker IDs.
