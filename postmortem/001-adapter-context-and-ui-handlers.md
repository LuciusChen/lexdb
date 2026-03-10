# Adapter Context and UI Handler Registration

## Background

`lexdb` had grown two kinds of hidden coupling:

- adapter implementations still relied on hardcoded adapter IDs and legacy global path variables, so multiple adapters of the same type could not stay isolated;
- `lexdb.el` directly required and called `lexdb-ui.el`, which inverted the intended core/UI dependency direction.

These problems started showing up as both architectural drift and concrete byte-compilation warnings.

## Decision

Use two small mechanisms instead of a larger rewrite:

- bind the currently executing adapter dynamically while core API functions invoke adapter callbacks;
- let `lexdb-ui.el` register display/audio handlers with `lexdb.el`, so core search logic calls abstract handlers instead of requiring UI functions directly.

## Why This Approach

- It fixes adapter isolation without changing every adapter callback signature.
- It keeps the current public command surface intact, so the package does not need a disruptive API split.
- It removes the direct core -> UI dependency while staying small enough to land safely in one refactor.

## Alternatives Considered

- Pass adapter IDs or adapter structs through every adapter callback explicitly.
  This is cleaner in the abstract, but it would force a broad signature rewrite across the whole package.

- Move all interactive search and playback commands out of `lexdb.el` into `lexdb-ui.el`.
  This would produce a stricter boundary, but it is a larger user-facing reshuffle and was unnecessary for fixing the current coupling.

- Keep the current design and only silence compiler warnings.
  Rejected because the warnings came from real architectural problems, not just formatting issues.

## Trade-offs

- Dynamic adapter context is still an implicit mechanism; contributors need to know adapter callbacks run inside a bound context.
- UI handler registration means interactive use now assumes `lexdb-ui.el` is loaded before display-oriented commands run.

## Remaining Limitations

- The package still keeps some legacy configuration variables for compatibility.
- A future cleanup may still choose to move more interactive commands into `lexdb-ui.el` if the boundary needs to become stricter.

## Lessons Learned

- Fixing architectural violations at the core layer was not enough; UI code also invoked adapter hooks directly, so the adapter-context change had to cover the full core -> UI -> adapter call chain.
- A clean byte-compilation result did not guarantee runtime correctness. The missed failures came from real lookup flows: first search after `lexdb-init`, UI-triggered lemma suggestions, and adapter hooks such as collocations and prefetch.
- Changing dependency direction also changed initialization behavior. Existing user setups that loaded adapters but not `lexdb-ui.el` needed an explicit compatibility path, so lazy UI loading was required.
- For future boundary refactors, the minimum validation set should include:
  - search after unified `lexdb-init`;
  - legacy `lexdb-*-register` setup;
  - UI-driven follow-up lookups and adapter hook paths.
