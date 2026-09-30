# Vendored Hermes native plugins

`hermes-laya` and `hermes-laya-handoff` are the Hermes-side decision
surface for this daemon (see `docs/INSTALL.md §2b`). They are installed
by `Scripts/install_hermes_plugin.sh` — standalone or as step 7 of
`install-macos.sh` / part of `agent_install.sh`.

**Provenance:** vendored from
[`Andrei-cloud/laya-plugin`](https://github.com/Andrei-cloud/laya-plugin)
`hermes/plugin/` at commit `b7df5a7` (multiplex-safe home resolution +
category-nested skill discovery + JSON-string tool results). The plugin
library under each `lib/` is itself synced from that repo's `server/`
by its `scripts/sync_plugin_lib.py` — this checkout carries the
resulting byte-identical copies.

Updating them: re-copy from the Python repo after pulling its fixes —

```sh
for p in hermes-laya hermes-laya-handoff; do
  rsync -a --exclude __pycache__ \
    ../laya-plugin/hermes/plugin/$p hermes/plugin/
done
```

then re-run the sandbox check (`./Scripts/install_hermes_plugin.sh
--check-only --json`) and bump the provenance commit above. The plugins
are Python stdlib-only at runtime (RemoteEngine over loopback); they
never import Swift-repo code and never load the model in-process.
