Sample data for the README screenshots (documentation addresses only). Regenerate the screenshots with

```sh
./scripts/build-app.sh
open -n build/Roundhouse.app --args -demo "$PWD/Assets/screenshots/sample" \
    -snapshotFolder "$PWD/Assets/screenshots" -snapshotSelect Proxmox -snapshotQuery pve -AppleLanguages '(en)'
```

`-demo` reads `connections.json` and `ssh_config` from this folder and saves nothing; entries tagged `offline`
show a red dot, the others green. `-demoWelcome YES` shows the first-launch welcome instead of the selected entry.
