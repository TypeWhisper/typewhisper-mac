# Community Plugin Registry

Add one JSON file per community plugin in this directory. Use the plugin ID as
the filename, for example:

```
com.example.my-plugin.json
```

Each entry is validated in pull requests. Entries without `releases[]` are
source-review metadata only and are not published as installable marketplace
plugins.

Community entries must use `source: "community"`. Release metadata, when
present, belongs inside `releases[]`.

The TypeWhisper marketplace only supports TypeWhisper-built community
artifacts. If a community entry includes `releases[]`, each `downloadURL` must
point to a GitHub Release asset under `TypeWhisper/typewhisper-mac`. Contributor
repository ZIPs, personal release assets, and other external artifact URLs are
not supported by the community registry.

After source review, a maintainer publishes an installable community release by
running `plugin-release.yml` with `distribution_source=community`. That workflow
builds, signs, hosts, and writes the release metadata to
`gh-pages/plugins-community-v1.json`.
