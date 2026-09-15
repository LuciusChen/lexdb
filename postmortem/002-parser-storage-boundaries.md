# Parser, Archive, and Storage Boundaries

## Problem

LDOCE and ODE each implemented connection management, attribute serialization,
relations, collocations, and finalization.  Both converters also retained the
complete MDX record list and a second decoded HTML list.  All three parsers
required MDX/LZO support merely to import an HTML parsing function.

The write boundary had two observable defects: failed entries left partial rows
behind when the conversion loop continued, and generated sense IDs and metadata
were written back into parser results.  Reusing parsed data could therefore
carry state from a previous database write.

## Decision

Use one small storage base in `lexdb_common.py`.  Its public `write_entry` owns
the transaction and successful-entry count.  Existing LDOCE/ODE writers supply
the dictionary-specific `_write_entry` mapping and reuse common SQL operations.
OALD uses the same transaction context with its existing bilingual writer.

Keep MDX/MDD I/O in `lexdb_mdx.py`, shared by the converters and HTML extraction
tool.  Reader imports happen when an archive is opened, and progress totals use
the reader's header count instead of materializing all record contents.  OALD
decodes within its per-record error handler so one malformed record remains
recoverable.

Opening the MDX reader and extracting requested audio must precede any output
database changes.  Review caught a regression where lazy reader imports could
fail after the existing database had already been removed; OALD could similarly
create or modify a database before the import failed.  Regression tests first
reproduced both cases, then preparation was moved before database initialization.

## Alternatives and Trade-offs

- A universal parser or a new hierarchy of typed entry models would force the
  distinct HTML grammars and metadata conventions into one shape.  Shared SQL
  and transaction ownership provide the immediate benefit without changing the
  parser output contract.
- A fully unified writer for OALD would require changing or parameterizing its
  bilingual columns, empty-value handling, compressed attributes, and nested
  namespace keys.  Keeping that mapping explicit avoids a database migration
  and hidden reader compatibility changes.
- A savepoint alone can commit each entry when no outer transaction exists.
  The shared transaction helper explicitly starts a batch first; releasing the
  savepoint never commits it.  Failed entries roll back without discarding
  previously completed entries in the batch.
- Copying just the attribute mapping is sufficient: writers add derived maps
  there and do not mutate nested parser data.  Deep-copying every entry would
  add cost without protecting any additional writes.

## Compatibility and Validation

CLI entry points and Schema 2.2 remain unchanged.  OALD's legacy namespace and
compression conventions remain supported.  The existing attribute omission
rules and dictionary-specific filtering stay in place; those need a separate
data-contract change if revised.  Preparation failures preserve existing output,
but once writing begins, per-entry rollback does not make replacement of an
entire dictionary atomic.

Regression checks cover missing reader dependencies and audio failures without
output database changes, writer input immutability,
rollback within an uncommitted batch, serialized attributes, record streaming,
archive ordering, and extraction paths staying within the audio directory.
Real MDX samples were converted with both versions: 82 records produced 86
entries, 1,096 senses, and 1,534 examples.  All table rows, including compressed
attribute bytes, matched after excluding the dictionary creation timestamp.
This is sample-based compatibility verification, not a complete conversion of
every supported dictionary edition.
