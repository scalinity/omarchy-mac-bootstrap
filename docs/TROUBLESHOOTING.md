# Troubleshooting

Start with `./omarchy-bootstrap doctor` and `./omarchy-bootstrap logs`.

## macOS

| Symptom | Cause | Fix |
| --- | --- | --- |
| "not in the Asahi device list" | M4 or newer, or an unknown model | Not supported upstream yet; check the [device list](https://asahilinux.org/docs/hw/devices/device-list/) |
| "experimental" | M3 family | Installer accepts it; display/USB are work in progress upstream |
| Safe Linux maximum is far below free space | APFS snapshots or a pending update (`APFS resize overhead` in doctor) | Finish macOS updates, delete Time Machine local snapshots (<https://alx.sh/tmcleanup>), re-plan |
| "Not enough free space for Linux yet" | Less than 50 GB after the 38 GB macOS reserve | Free space in macOS; the message says how much |
| The installer's minimum differs from the plan | Free space changed since planning | The plan includes a 5 GB margin; re-run `./omarchy-bootstrap` to re-plan |
| "not an administrator" | The login user is not an admin | Log in as an admin user |
| Download or reachability failure | Network, or asahi-alarm.org down | Retry; `sources --check` shows what is reachable |
| "does not have the shape this tool expects" | Upstream changed the bootstrap | Read it (the tool opens it), then compare with `docs/UPSTREAM.md` |

## Linux

| Symptom | Cause | Fix |
| --- | --- | --- |
| No network | Wi-Fi not connected | `nmtui` → Activate a connection. If it errors right after connecting, reboot and retry |
| "must run as root" | Phase 2 needs root on the minimal image | Log in as `root` / `root` |
| "carries Omarchy 3.x" | The branch changed upstream | `sources --check`; decide deliberately before editing `lib/sources.sh` |
| "no longer declares: --keymap" | The setup script's flags changed | Same: re-verify upstream, then update `OMARCHY_MAC_SETUP_FLAGS` |
| Setup "in progress" but nothing happens | The unit ran and stopped | `./omarchy-bootstrap resume` as root, or check `/var/log/omarchy-mac-setup.log` |
| SSH stopped working after Omarchy | Omarchy's firewall blocks port 22 | `./omarchy-bootstrap dev` → SSH, or `omarchy-setup-security-sshd` |
| A prebuilt CLI crashes at start | 16 KiB pages on Asahi | Prefer the vendor's arm64 build or a from-source install |
| `pacman` lock warning in doctor | A stale `db.lck` | Only if no pacman is running: `sudo rm /var/lib/pacman/db.lck` |
| Slow or failing mirrors | Mirror trouble | Omarchy Mac ships `fix-mirrors.sh` in its repository |

## Output

| Symptom | Fix |
| --- | --- |
| Boxes or symbols look broken | `--ascii` (automatic on the Linux console) |
| Colours are unreadable | `--no-color` or `NO_COLOR=1` |
| Menus do not respond to arrows | Type the number and Enter; `b` goes back, `q` quits |
