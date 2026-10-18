# Regex dictionary sync, version 2

Mac and Windows use `dictionary:correction:regex:<pattern>` for regular-expression corrections. `<pattern>` is the unpadded Base64URL encoding of the original UTF-8 bytes. Do not trim, lowercase, fold accents, or normalize Unicode. `\d`, `\D`, `é`, `e`, decomposed `é`, and patterns with surrounding spaces are distinct. The `caseSensitive` flag changes matching behavior, not identity.

Terms and literal corrections keep their existing normalized version-1 IDs. A literal correction and a regex correction with identical original text can coexist. Changing a rule's mode or pattern changes its identity: publish the new entry and a tombstone for the previous ID.

## Operations and older clients

Regex upserts and tombstones use operation `schemaVersion: 2`. The collection remains `dictionary`; upserts must contain a correction with `isRegex: true` and the matching exact-pattern ID. Version 2 is not accepted for other collections or literal entries. The package manifest remains version 1, and literal corrections, terms, snippets, and history keep their existing operation formats.

Existing clients accept only schema-1 operations, so they ignore the new regex operations rather than folding their IDs and overwriting different patterns. Older Mac clients can report these files as an unsupported schema. All devices that need to exchange regex corrections must be upgraded. Literal sync remains available to older clients.

## Migration

Resolve version-1 operations in their original namespace before migrating regex upserts. An old tombstone or a later renamed/replaced entry suppresses its superseded version-1 regex upsert; deleted rules must not reappear on a newly upgraded device. Surviving legacy regex upserts are mapped to exact-pattern IDs and republished in version 2 on the next sync. Local export versions advance to `dictionary-v3` so existing entries publish their current metadata once.

Legacy tombstones do not target migrated version-2 identities, because a folded ID cannot distinguish `\d` from `\D`. During local migration, removing the old ID from the snapshot retires that old identity independently of the new rule. Use an upgraded client to delete a migrated regex rule.

Missing `isRegex` is different from an explicit `false`. A legacy update preserves a known local regex mode only for the exact same pattern and when it does not address a coexisting literal entry. The preserved mode is republished once. New legacy entries without a mode default to literal. At equal timestamps, an explicit mode takes precedence over an absent field.

## Verification

Both repositories contain identical fixtures in their test `Fixtures/PremiumSync` directories:

- `regex-dictionary-identities-v2.json`: byte-exact IDs, case, accents, Unicode composition, spaces, and an emoji.
- `upsert-dictionary-regex-v1.json`: legacy migration input.
- `upsert-dictionary-regex-v2.json`: shared version-2 wire payload.

Sync tests cover independent rules, literal/regex coexistence, targeted deletion, preserved legacy mode, one-time republishing, and tombstones that suppress legacy upserts without deleting migrated rules.

The dictionary HTTP APIs include `isRegex` in GET responses. PUT and DELETE use `(original, isRegex)` as their identity; omitted `isRegex` means literal, so older API clients cannot update or delete a regex accidentally. Invalid regex PUT requests return HTTP 400. To change modes, delete the old mode and create the new one.
