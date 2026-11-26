Sample data for the README screenshots (documentation addresses only). Regenerate the screenshots with

```sh
./scripts/build-app.sh
open -n "build/Roundhouse Dev.app" --args -demo "$PWD/Assets/screenshots/sample" \
    -snapshotFolder "$PWD/Assets/screenshots" -snapshotSelect "Core switch" -snapshotQuery pve -AppleLanguages '(en)'
```

`-demo` reads `connections.json` and `ssh_config` from this folder and saves nothing; entries tagged `offline`
show a red dot, the others green. `-demoWelcome YES` shows the first-launch welcome instead of the selected entry.

`bw` here is a stand-in for the Bitwarden CLI with made-up items (also used by the tests): in the demo the vault is
unlocked with its sample password, so the screenshots never touch a real vault.
