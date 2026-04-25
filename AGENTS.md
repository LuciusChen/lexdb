# lexdb Agent Guide

This file is the canonical instruction file for AI-assisted development in
`lexdb`.

Rules copied from shared `coding-guidelines` are adapted here. Treat this file
as self-contained; do not require agents to consult external guideline
repositories at runtime.

## Core Principles

- **Question every abstraction**: before adding a layer, file, helper, hook, or indirection, ask whether it solves a current `lexdb` problem. If the answer is hypothetical, do not add it.
- **Simplify relentlessly**: three similar lines are better than a premature abstraction. A single large file is better than several tiny files with unclear boundaries.
- **Fewer files, clearer boundaries**: split only when a file has a genuinely distinct responsibility. Never split for cosmetic reasons.
- **Prefer boring code**: a straightforward conditional chain is easier to debug than a clever dispatch hierarchy.
- **Delete dead paths instead of preserving them indefinitely**: remove unused code entirely. Do not keep stale compatibility shims unless users actively rely on them.
- **Converge UX, avoid parallel workflows**: if two commands or interaction paths do nearly the same thing, prefer one consistent model unless the distinction is genuinely valuable.
- **No side effects on load**: loading a file must not mutate user state beyond definitions and registrations required by that file's API.

## Diagnosis and Change Discipline

- **Find the root cause before changing behavior**: do not patch timing, caching, or control flow until you can name the failing layer and explain why it is responsible.
- **One failed fix narrows the hypothesis**: if the first attempted fix does not hold, reduce the hypothesis space and gather evidence. Do not stack another speculative patch on top.
- **Two failed fixes stop the patching loop**: after two failed fixes on the same issue, stop changing behavior and switch to diagnosis only.
- **Fix the right layer**: move the fix to the layer that actually owns the problem instead of compensating elsewhere.
- **Keep experiments narrow**: start new directions with the smallest slice that proves the approach is worth having. Do not expand scope before the first slice shows real value.

## Architecture

- **Dependency direction is one-way**: adapters depend on `lexdb.el`; `lexdb-ui.el` depends on `lexdb.el`; core code must not depend on adapter files; generic code must not hardcode one dictionary's schema.
- **Keep file responsibilities narrow**:
  - `lexdb.el`: core structs, registry, lookup API, shared DB/cache helpers.
  - `lexdb-ui.el`: rendering, navigation, faces, interactive UI behavior.
  - `lexdb-ldoce.el`, `lexdb-oald.el`, `lexdb-ode.el`: adapter-specific queries and data shaping.
  - `scripts/*.py`: MDX/HTML parsing and SQLite generation.
- **Schema changes are cross-cutting**: if you change the SQLite schema or attribute layout, update Python writers, Emacs readers, and `schema.md` together.
- **Capability-driven design stays generic**: if rendering or lookup is optional per dictionary, model it as a capability or adapter hook instead of branching generic code around one source.
- **Reuse Emacs infrastructure**: prefer `completing-read`, `special-mode`, text properties, standard hooks, and built-in navigation facilities over custom mini-frameworks.

## Naming

- Public Elisp API uses the `lexdb-` prefix.
- Internal Elisp helpers use `lexdb--` or `lexdb-<adapter>--`.
- Adapter-specific public symbols use `lexdb-ldoce-`, `lexdb-oald-`, or `lexdb-ode-`.
- Do not call adapter-private helpers such as `lexdb-ldoce--...` from other
  files. If logic is genuinely shared, promote it to `lexdb.el` as a
  `lexdb--...` helper with a clear contract.
- Predicate names end in `-p`.
- Unused parameters are prefixed with `_`.
- Python helpers in `scripts/` should use descriptive snake_case names; avoid cryptic abbreviations unless they mirror the source format.

## Elisp Control Flow

- Avoid deep `let` -> `if` -> `let` chains. Favor flat, linear control flow.
- Use `if-let*` and `when-let*` for conditional binding.
- Use `pcase` and `pcase-let` for structured destructuring instead of nested `car`, `cdr`, or `nth`.
- Use `cl-loop` when iteration logic is non-trivial; do not build large accumulators through manual mutation when a clearer loop is available.
- Prefer `cl-loop` over `dolist` plus manual accumulators for non-trivial iteration. `cl-reduce` is acceptable for simple single-operation folds.
- Separate pure data transformation from buffer mutation and side effects whenever practical.
- Interactive commands should stay thin: validate input, call internal logic, then render or message.

## Error Handling

- Errors must surface, not hide. Do not add fallback/default returns that silently swallow failures.
- Catch at the boundary, nowhere else. Only top-level command or adapter boundaries should catch and convert recoverable failures.
- Use `user-error` for user-caused problems such as missing dictionaries, missing DB files, invalid selections, or invalid commands.
- Use `error` for programmer bugs or invariant violations.
- Use `condition-case` only for recoverable failures. Wrap non-essential or optional operations so errors never block primary results.
- Error messages should state what is wrong, not what should be; for example, "Not connected" instead of "Must be connected".

## State Management

- Use `defvar-local` for all per-buffer UI state in `lexdb-ui.el`.
- Use plain `defvar` for shared registries, caches, and process-wide state.
- Use `defcustom` for user-configurable values. Always specify a precise `:type` and `:group`.
- Keep adapter state keyed by adapter ID; avoid hidden global coupling between dictionaries.
- Major modes must make their per-buffer state variables buffer-local.

## Mode Definitions

- Read-only result buffers should derive from `special-mode` unless there is a strong reason not to.
- Editing buffers should derive from the right parent mode.
- Use `define-derived-mode` rather than hand-rolling mode setup when a real mode is needed.
- Register hooks buffer-locally in mode bodies or setup functions using the LOCAL argument where applicable.
- Do not let loading a mode file enable behavior globally.

## UI and Rendering

- Read-only display buffers should derive from `special-mode` or another fitting built-in mode.
- Prefer rebuilding display buffers from structured entry data rather than re-parsing rendered text.
- Use text properties for semantic annotations that need to travel with text.
- Use overlays only for temporary visual effects.
- Keep UI code generic; adapter-specific formatting should be provided through data shape, capabilities, or explicit hooks.
- If a UI change affects navigation, key bindings, tabs, visible sections, defaults, or user-visible workflow, update `README.md` in the same change.

## Function Design

- Prefer small functions with one clear job. If a function becomes hard to scan, extract helpers.
- Keep functions under roughly 30 lines where practical, but do not split cohesive rendering logic into unclear fragments just to satisfy the number.
- Name helpers after what they compute or render, not just where they are called from.
- Keep pure data transformation separate from rendering and side effects whenever practical.
- Interactive commands should stay thin wrappers around internal functions.

## Completion

- Use standard `completing-read` for interactive selection.
- If completion-at-point is added later, keep it fast and buffer-local, and allow fallback when appropriate.

## Autoloads

- Add `;;;###autoload` to real user-facing commands and user-facing minor modes.
- Do not autoload internal helpers, variables, `defcustom` forms, or private modes.
- Use `declare-function` when optional dependencies need to be referenced only for compilation.

## Dependencies

- `cl-lib` functions require `(require 'cl-lib)`; do not rely on transitive loading.
- Avoid `eval-when-compile` for runtime-needed dependencies.
- Before using a newer Emacs API, verify when the symbol was introduced and guard or avoid symbols above the project's declared baseline.

## Adapter Rules

- Adapters translate dictionary-specific schema into generic `lexdb` data structures; they should not own generic UI behavior.
- Prefer compatibility at the boundary: normalize source-specific fields into shared entry/sense/pronunciation/relation structures, and keep raw metadata in adapter-specific keys only when necessary.
- Query code should be explicit and readable; avoid over-abstracting SQL fragments shared by only one adapter.
- If legacy schema support remains, keep the compatibility path isolated and clearly named.
- Do not let one dictionary's schema leak into generic code. Use capabilities, hooks, or namespaced metadata.

## Python Conversion Scripts

- Keep conversion logic deterministic: identical input should produce equivalent schema output.
- Shared schema helpers belong in `scripts/lexdb_common.py`; parser-specific quirks stay in the corresponding converter.
- Favor correctness of extracted structure over aggressive cleanup that may discard dictionary data.
- When adding a new table, attribute key, or relation shape, document the intent in `schema.md`.

## Documentation Discipline

- User-visible changes must update docs in the same commit. Any change to key bindings, defaults, configuration, schema expectations, or user-facing workflow must update `README.md` and related docs.
- Code is the source of truth. If code and docs diverge, fix docs immediately.
- If a change affects SQLite schema, attribute keys, or relation shape, update `schema.md` as well as code.

## Tests and Quality Checks

- Tests must fail when the code is wrong. If deleting or breaking the function under test does not turn the test red, the test is worthless.
- Use diverse inputs, boundary cases, and distinguishable expected values. Do not rely on hard-coded expectations that a stub can satisfy.
- When fixing a bug, first reproduce it with the smallest failing check practical for this repository, confirm the check fails, then fix the code.
- If no proper test harness exists for the changed area, use a targeted batch
  evaluation, SQLite query, or converter run that demonstrates the behavior
  before and after the change.
- Elisp files should start with `lexical-binding: t` and end with the correct `(provide '...)` footer.
- Public functions and user options need docstrings.
- Docstring first lines should be complete sentences ending with a period.
- Argument names in docstrings should be UPPERCASED.
- Before finishing non-trivial Elisp changes, byte-compile the touched files and fix warnings.
- Run `checkdoc` and `package-lint` when preparing distributable package changes or when touching package headers.
- For script changes, run the smallest realistic conversion or parsing check you can, rather than relying on inspection alone.

## MELPA and Package Conventions

- First line format: `;;; file.el --- Short description -*- lexical-binding: t; -*-`.
- The package description should not contain "for Emacs" or repeat the package name.
- Keep package descriptions under 60 characters.
- Main package files should declare direct dependencies in `Package-Requires`.
- Last line format: `;;; file.el ends here`.

## Postmortems

- Read existing files in `postmortem/` before making significant changes in the same area.
- Significant design changes should leave a short decision record in `postmortem/NNN-topic.md`.
- Write a postmortem when:
  - changing the SQLite schema or compatibility story;
  - adding or removing a user-visible lookup or navigation workflow;
  - introducing a new adapter boundary, hook, or capability model;
  - choosing between non-obvious architectural approaches;
  - keeping or removing a legacy code path after evaluating alternatives;
  - reverting or abandoning an approach that turned out to be wrong;
  - deliberately deferring a known limitation.
- Focus the record on why: what alternatives were considered, what failed, what trade-offs were accepted, and what limitations remain.
- Do not write postmortems that merely restate the code.
- If a future contributor cannot tell why this approach was chosen, the record is incomplete.

## Pre-Submit Review

Before committing significant changes, step back and review the whole diff.

- Read the full diff before committing. Every changed line should be intentional.
- Compile clean: byte-compiling touched Elisp files must produce zero warnings.
- Run the smallest relevant checks for the changed area, and run the full suite if one exists.
- Update tests when behavior changes; search existing tests for changed functions.
- No heuristic shortcuts: if a fix feels "good enough for now", either do it correctly or explicitly document why the rest is deferred.
- No redundancy: check for duplicated logic, dead code, stale compatibility paths, or overlapping abstractions introduced by the change. Remove them.
- Long-term correctness: ask whether the approach still holds under less convenient paths such as unified config, legacy registration, missing data, repeated lookups, and UI-triggered follow-up actions.
- Docs in sync: any change to key bindings, defaults, workflow, schema expectations, or data structures must update `README.md` and, where applicable, add or update a postmortem.
