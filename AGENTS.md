# Repository conventions

## Code organisation

- Follow local style so the repository reads as one cohesive codebase.
- Group and order related declarations logically throughout the repository, not just in Ruby code. Use consistent names,
  placement, and spacing to make relationships clear.
- Use blank lines to separate logical steps and final return values, without fragmenting closely related code.
- Separate standard-library, third-party, and project requires with blank lines, keeping `require_relative` separate.
  Respect load-order dependencies and order semantically rather than alphabetically.
- Prefer `atomic-ruby`'s CAS-based queues and synchronisation in server internals. Use mutex-backed alternatives only
  when their semantics justify them, and avoid busy-spinning across blocking operations.

## Documentation and commits

- Keep comments focused on what and why. Explain implementation details only when the intent is otherwise unclear.
- Normally match commit subjects to changelog entries. Preserve separate entries for distinct changes worth calling out.
- Use inline code formatting for code references in commit subjects and changelog entries where applicable.

## Tests

- Load `test_helper` first in test files and group test-support requires together, respecting boot dependencies.
- Rely on assertions' default failure messages rather than adding custom messages.
- Follow suite conventions for descriptions, setup, and assertions. Use Minitest's `parallelize_me!` when tests can
  safely run independently.
