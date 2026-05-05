# Community Plugin Registry

Add one JSON file per community plugin in this directory. Use the plugin ID as
the filename, for example:

```
com.example.my-plugin.json
```

Each entry is validated in pull requests and published to
`plugins-community-v1.json` on `gh-pages` after it lands on `main`.

Community entries must use `source: "community"` and put release metadata inside
`releases[]`.
