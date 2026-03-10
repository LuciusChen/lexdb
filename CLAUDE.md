# lexdb Development Guide

This file distills the parts of `clutch/CLAUDE.md` that fit `lexdb`'s codebase and workflow.

## First Principles

- **Question every abstraction**: before adding a helper, layer, hook, or compatibility wrapper, ask whether it removes a real current cost in `lexdb`, not a hypothetical future one.
- **Keep the architecture explicit**: `lexdb.el` is the core API and data model, `lexdb-ui.el` is rendering and interaction, `lexdb-*.el` files are dictionary adapters, and `scripts/` is offline data conversion. Do not blur these boundaries.
- **Prefer simpler code over clever abstractions**: if a helper or layer does not remove real duplication or complexity in `lexdb`, do not add it.
- **Fewer files, clearer boundaries**: only split code when the new file has a genuinely distinct responsibility. Do not split for cosmetics.
- **Add features where the data actually lives**: dictionary-specific behavior belongs in the matching adapter or converter, not in generic UI or core code.
- **Delete dead paths instead of preserving them indefinitely**: do not keep stale compatibility shims unless users actively rely on them.
- **Converge UX, avoid parallel workflows**: if two commands or interaction paths do nearly the same thing, prefer one consistent model unless the distinction is genuinely valuable.
- **No side effects on load**: loading a file must not mutate user state beyond definitions and registrations that are required by that file's API.

## Architecture

- **Dependency direction is one-way**: adapters depend on `lexdb.el`; `lexdb-ui.el` depends on `lexdb.el`; core code must not depend on adapter files; generic code must not hardcode one dictionary's schema.
- **Keep file responsibilities narrow**:
  - `lexdb.el`: core structs, registry, lookup API, shared DB/cache helpers.
  - `lexdb-ui.el`: rendering, navigation, faces, interactive UI behavior.
  - `lexdb-ldoce.el` / `lexdb-oald.el` / `lexdb-ode.el`: adapter-specific queries and data shaping.
  - `scripts/*.py`: MDX/HTML parsing and SQLite generation.
- **Schema changes are cross-cutting**: if you change the SQLite schema or attribute layout, update Python writers, Emacs readers, and `schema.md` together.
- **Capability-driven design stays generic**: if rendering or lookup is optional per dictionary, model it as a capability or adapter hook instead of branching generic code around one source.
- **Reuse Emacs infrastructure**: prefer `completing-read`, `special-mode`, text properties, standard hooks, and built-in navigation facilities over custom mini-frameworks.

## Naming

- Public Elisp API uses the `lexdb-` prefix.
- Internal Elisp helpers use `lexdb--` or `lexdb-<adapter>--`.
- Adapter-specific public symbols use `lexdb-ldoce-`, `lexdb-oald-`, `lexdb-ode-`.
- Predicate names end in `-p`.
- Unused parameters are prefixed with `_`.
- Python helpers in `scripts/` should use descriptive snake_case names; avoid cryptic abbreviations unless they mirror the source format.

## Control Flow

- Prefer flat control flow with `when-let*`, `if-let*`, `pcase`, and `pcase-let` over deeply nested `let`/`if` chains.
- Use `cl-loop` when iteration logic is non-trivial; do not build large accumulators through manual mutation when a clearer loop is available.
- Separate pure data transformation from buffer mutation and side effects whenever practical.
- Interactive commands should stay thin: validate input, call internal logic, then render or message.

## Error Handling

- Use `user-error` for user-facing problems such as missing dictionaries, missing DB files, or invalid selections.
- Use `error` for programmer bugs or invariant violations.
- Wrap optional or recoverable adapter behavior with `condition-case` when failure should not block the main lookup path.
- Error messages should explain the actual failure plainly.

## State Management

- Use `defvar-local` for buffer-local UI state in `lexdb-ui.el`.
- Use plain `defvar` for shared registries, caches, and process-wide state.
- Use `defcustom` for user configuration, with accurate `:type` and `:group`.
- Keep adapter state keyed by adapter ID; avoid hidden global coupling between dictionaries.
- Major modes must make their per-buffer state variables buffer-local.

## Mode Definitions

- Read-only result buffers should derive from `special-mode` unless there is a strong reason not to.
- Use `define-derived-mode` rather than hand-rolling mode setup when a real mode is needed.
- Register hooks buffer-locally in mode bodies or setup functions using the LOCAL argument where applicable.
- Do not let loading a mode file enable behavior globally.

## UI and Rendering

- Read-only display buffers should derive from `special-mode` or another fitting built-in mode.
- Prefer rebuilding display buffers from structured entry data rather than re-parsing rendered text.
- Use text properties for semantic annotations that need to travel with text.
- Use overlays only for temporary visual effects.
- Keep UI code generic; adapter-specific formatting should be provided through data shape, capabilities, or explicit hooks.
- If a UI change affects navigation, key bindings, tabs, or visible sections, update `README.md` in the same change.

## Function Design

- Prefer small functions with one clear job. If a function becomes hard to scan, extract helpers.
- Name helpers after what they compute or render, not just where they are called.
- Keep pure data transformation separate from rendering and side effects whenever practical.
- Interactive commands should stay thin wrappers around internal functions.

## Completion

- Use standard `completing-read` for interactive selection.
- If completion-at-point is added later, keep it fast and buffer-local, and allow fallback when appropriate.

## Autoloads

- `;;;###autoload` belongs on real interactive entry points and other standard autoload targets only.
- Do not autoload internal helpers, `defvar`, or `defcustom` forms.
- Use `declare-function` when optional dependencies need to be referenced only for compilation.

## Adapter Rules

- Adapters translate dictionary-specific schema into generic `lexdb` data structures; they should not own generic UI behavior.
- Prefer compatibility at the boundary: normalize source-specific fields into shared entry/sense/pronunciation/relation structures, and keep raw metadata in adapter-specific keys only when necessary.
- Query code should be explicit and readable; avoid over-abstracting SQL fragments shared by only one adapter.
- If legacy schema support remains, keep the compatibility path isolated and clearly named.

## Python Conversion Scripts

- Keep conversion logic deterministic: identical input should produce equivalent schema output.
- Shared schema helpers belong in `scripts/lexdb_common.py`; parser-specific quirks stay in the corresponding converter.
- Favor correctness of extracted structure over aggressive cleanup that may discard dictionary data.
- When adding a new table, attribute key, or relation shape, document the intent in `schema.md`.

## Docs Consistency

- Any change to key bindings, defaults, setup, schema expectations, or user-visible workflow must update `README.md` and related docs in the same change.
- If code and docs diverge, treat code as the source of truth and fix docs immediately.

## Postmortems

- Read existing files in `postmortem/` before making significant changes in the same area.
- Significant design changes should leave a short decision record in `postmortem/NNN-topic.md`.
- Write a postmortem when:
  - changing the SQLite schema or compatibility story;
  - adding or removing a user-visible lookup or navigation workflow;
  - introducing a new adapter boundary, hook, or capability model;
  - keeping or removing a legacy code path after evaluating alternatives;
  - reverting an approach that turned out to be wrong.
- Focus the record on why: what alternatives were considered, what failed, what trade-offs were accepted, and what limitations remain.
- Do not write postmortems that merely restate the code.
- If a future contributor cannot tell why this approach was chosen, the record is incomplete.

## Pre-Submit Review

Before committing significant changes, step back and review the whole diff.

- **No heuristic shortcuts**: if a fix feels "good enough for now", it probably is not. Either do it correctly or explicitly document why it is deferred in a postmortem.
- **No redundancy**: check for duplicated logic, dead code, stale compatibility paths, or overlapping abstractions introduced by the change. Remove them.
- **Long-term correctness**: ask whether the approach still holds under less convenient paths such as unified config, legacy registration, missing data, repeated lookups, and UI-triggered follow-up actions.
- **Docs in sync**: any change to key bindings, defaults, workflow, schema expectations, or data structures must update `README.md` and, where applicable, add or update a postmortem.
- **Byte-compile clean**: batch byte-compiling the touched Elisp files must produce zero warnings.

## Quality Checks

- Elisp files should start with `lexical-binding: t` and end with the correct `(provide '...)` footer.
- Public functions and user options need docstrings.
- Before finishing non-trivial Elisp changes, run byte compilation on the touched files and fix warnings.
- For script changes, run the smallest realistic conversion or parsing check you can, rather than relying on inspection alone.
- If a change affects user-visible behavior or setup, update `README.md` at the same time.
