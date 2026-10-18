# Regex dictionary sync, version 2

Mac and Windows use `dictionary:correction:regex:<pattern>` for regular-expression corrections. `<pattern>` is the unpadded Base64URL encoding of the original UTF-8 bytes. Do not trim, lowercase, fold accents, or normalize Unicode. `\d`, `\D`, `é`, `e`, decomposed `é`, and patterns with surrounding spaces are distinct. The `caseSensitive` flag changes matching behavior, not identity.

Terms and literal corrections keep their existing normalized version-1 IDs. A literal correction and a regex correction with identical original text can coexist. Changing a rule's mode or pattern changes its identity: publish the new entry and a tombstone for the previous ID.

## Operations and older clients

Regex upserts and tombstones use operation `schemaVersion: 2`. The collection remains `dictionary`; upserts must contain a correction with `isRegex: true` and the matching exact-pattern ID. Version 2 is not accepted for other collections or literal entries. The package manifest remains version 1, and literal corrections, terms, snippets, and history keep their existing operation formats.

Existing clients accept only schema-1 operations, so they ignore the new regex operations rather than folding their IDs and overwriting different patterns. Older Mac clients can report these files as an unsupported schema. All devices that need to exchange regex corrections must be upgraded. Literal sync remains available to older clients.

## Migration

Resolve version-1 operations in their original namespace before migrating regex upserts. An old tombstone or a later renamed/replaced entry suppresses its superseded version-1 regex upsert; deleted rules must not reappear on a newly upgraded device. Surviving legacy regex upserts are mapped to exact-pattern IDs and republished in version 2 on the next sync. Local export versions advance to `dictionary-v3` so existing entries publish their current metadata once.

Legacy tombstones do not target migrated version-2 identities, because a folded ID cannot distinguish `\d` from `\D`. For each pre-`dictionary-v3` local identity, recover its last synchronized mode and exact pattern from the winning version-1 operations already recorded as applied. Newly arrived remote edits must not change which pattern a local deletion targets. If that known regex still exists under its exact-pattern ID, withdraw the old folded ID without a tombstone, preserving the rule on older peers. If the regex was deleted, renamed, or changed to literal before the first upgraded sync, publish a version-2 tombstone for its previous exact ID; also publish the usual version-1 tombstone when the old folded ID is absent locally. This prevents another upgraded peer's version-2 upsert from restoring the removed regex. A known literal still gets its normal version-1 tombstone, including when the user changed it to regex before the first upgraded sync. Use an upgraded client to delete a migrated regex rule.

Before its first export, an upgraded Mac repairs regex modes that an older Mac dropped when receiving Windows version-1 operations. Repair requires a surviving version-1 regex operation already recorded as applied, its folded ID in pre-`dictionary-v3` local state, and a local literal with the same UTF-8 original, replacement, timestamp, case sensitivity, and enabled state. The repair retains the local entry's identity and usage count. Locally edited literals and literals exported by a version-2-capable client are not reclassified. Repair runs before publication so an old copy cannot be republished as an explicit literal, including when Windows has already published the version-2 rule.

Missing `isRegex` is different from an explicit `false`. A legacy update preserves a known local regex mode only for the exact same pattern and when it does not address a coexisting literal entry. The preserved mode is republished once. New legacy entries without a mode default to literal. At equal timestamps, an explicit mode takes precedence over an absent field.

## Verification

Both repositories contain identical fixtures in their test `Fixtures/PremiumSync` directories:

- `regex-dictionary-identities-v2.json`: byte-exact IDs, case, accents, Unicode composition, spaces, and an emoji.
- `upsert-dictionary-regex-v1.json`: legacy migration input.
- `upsert-dictionary-regex-v2.json`: shared version-2 wire payload.

Sync tests cover independent rules, literal/regex coexistence, targeted deletion, preserved legacy mode, one-time republishing, upgrades with already-synced state, deletion/renaming/mode changes before the first upgraded sync, and tombstones that suppress legacy upserts without deleting migrated rules.

The dictionary HTTP APIs include `isRegex` in GET responses. PUT and DELETE use `(original, isRegex)` as their identity; omitted `isRegex` means literal, so older API clients cannot update or delete a regex accidentally. Invalid regex PUT requests return HTTP 400. To change modes, delete the old mode and create the new one.
