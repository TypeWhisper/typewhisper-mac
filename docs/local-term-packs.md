# Local term packs

**Dictionary > Term Packs** lists three kinds of packs. All of them are turned on
and off the same way: turning a pack on adds its terms and corrections to the
dictionary, turning it off removes the entries it added.

| | Built-in | Community | Local |
| --- | --- | --- | --- |
| Comes from | The app | The TypeWhisper term pack registry (`termpacks/` in this repository, reviewed in pull requests) | A JSON file you import |
| Updates | With app updates | **Update Available** when the registry has a newer version | Import the edited file again |
| Who has it | Everyone | Everyone | Only this Mac. Local packs are not reviewed, synced or uploaded |

Local packs are for vocabulary of your own: a team, a client, a project. To share
a pack with everyone, submit it to the registry (see below).

## Import, update, export, remove

- **Import:** click **Import Term Pack...** next to **Local Packs** and choose a
  file. The new pack starts turned off. Entries that are already in the
  dictionary, as your own entries or from another pack that is on, keep their
  owner and are not added twice.
- **Update:** edit the file and import it again. TypeWhisper asks before it
  replaces the imported pack with the same `id`. If the pack is on, its
  dictionary entries follow the new file right away; entries that are still in
  the pack keep the settings you changed, such as switched off or Vocabulary
  Boosting.
- **Export:** the **•••** menu of a local pack saves it as a JSON file. The file
  imports on any Mac.
- **Remove:** the same menu deletes the pack from this Mac and removes the
  entries it added to the dictionary.

## File format

A local pack uses the format of the community packs in
[`termpacks/`](../termpacks), so an exported pack can be submitted to the
registry unchanged:

```json
{
  "id": "acme-team-terms",
  "name": "Acme Team Terms",
  "description": "Product names and internal tools of the Acme team.",
  "names": { "de": "Acme-Teambegriffe" },
  "descriptions": { "de": "Produktnamen und interne Tools des Acme-Teams." },
  "icon": "person.3",
  "version": "1.0.0",
  "author": "Acme Docs Team",
  "terms": ["Acme Cloud", "Roadrunner", "QuickShip"],
  "corrections": [
    { "original": "quick ship", "replacement": "QuickShip", "caseSensitive": false }
  ]
}
```

| Field | Rule |
| --- | --- |
| `id` | Required. Lowercase letters, digits and hyphens, at most 64 characters. It must not be the ID of a built-in pack or a community pack, including the industry packs `real-estate`, `architecture` and `legal`. |
| `name`, `description`, `author` | Required, not empty. |
| `icon` | Required. An [SF Symbols](https://developer.apple.com/sf-symbols/) name. A symbol this macOS version does not have shows a box icon. |
| `version` | Required. Numbers separated by dots, such as `1.0` or `1.2.3`. |
| `names`, `descriptions` | Optional. Language code to text, shown instead of `name` and `description` in that app language. |
| `terms` | List of words. No duplicates (case-insensitive). |
| `corrections` | List of `original`, `replacement` and `caseSensitive`. `caseSensitive` defaults to `true`; an empty `replacement` removes the word. Each `original` appears once, because the dictionary keeps one correction per original. |

A pack needs at least one term or correction, and the file can be up to 2 MB.
Files that break a rule are not imported; the message names the field or entry
to fix. Exports are sorted by key and, like the registry files, leave out
an empty `terms` or `corrections` list.

## Storage and sync

- Pack files are stored as `LocalTermPacks/<id>.json` in TypeWhisper's
  Application Support folder (in the app container for the Mac App Store
  edition). **Export All Data** and **Delete All Data** include them.
- Whether a pack is on is stored separately from its file, with the states of
  the other packs in the app preferences (`activatedTermPackStates`).
- Cloud sync leaves out the dictionary entries of every pack that is on,
  built-in, community or local, so local pack entries do not reach other Macs or
  the iOS app. Pack states are not synced either.
- If the file of a pack that is on is missing, for example after preferences
  were copied from another Mac, TypeWhisper keeps its state and its dictionary
  entries. Importing the file again connects them to the pack.
- If a community pack later uses the same `id` as a local pack, the community
  pack keeps the ID. The local pack shows a warning and can be turned off but
  not on; change its `id` and import it again.

## Submitting a pack to the community registry

Export the pack and open a pull request that adds the file to `termpacks/`.
`scripts/assemble_termpacks.py` validates it, and the registry is updated after
review. There is no in-app submission or pack editor yet.
