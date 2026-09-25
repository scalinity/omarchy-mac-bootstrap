# Troubleshooting

Start with `./omarchy-bootstrap doctor` and `./omarchy-bootstrap logs`.

## macOS

| Symptom | Cause | Fix |
| --- | --- | --- |
| "not in the Asahi device list" | M4 or newer, or an unknown model | Not supported upstream yet; check the [device list](https://asahilinux.org/docs/hw/devices/device-list/) |
| "experimental" | M3 family | Installer accepts it; display/USB are work in progress upstream |
| "partition layout could not be read exactly" | `diskutil info` lacks an offset or GUID, or disagrees with `diskutil list` | Restart macOS and run it again; if it persists, run First Aid on the disk from Recovery. Nothing is planned on a guess |
| "Another APFS container is on the internal disk" | a second macOS install or other APFS container | Not a layout this tool plans around |
| "did not report the resize limits" | `diskutil apfs resizeContainer … limits` did not answer | Restart macOS and try again; First Aid on the container from Recovery |
| Safe Linux maximum is far below free space | APFS snapshots or a pending update (`APFS resize overhead` in doctor), or free space split across separate regions | Finish macOS updates, delete Time Machine local snapshots (<https://alx.sh/tmcleanup>), re-plan. Separate regions are never added together |
| "Not enough space for Linux yet" | Less than 54 GB in one region after macOS keeps used + 38 GB + margin | Free space in macOS; the message says how much |
| "leading zero" / "too large" at a size prompt | ambiguous or impossible input | Type the number plainly, e.g. `8` or `250GB` |
| "the installer's storage behaviour may have changed" | a new installer version or OS template | `sources --check`; re-verify upstream (docs/UPSTREAM.md) before updating `lib/sources.sh` |
| "layout changed since it was surveyed" / "answers shown no longer hold" | the disk or macOS's free space changed before the launch | Run `./omarchy-bootstrap` again for a fresh plan |
| "stopped before finishing its first stage" | the installer was interrupted early | docs/RECOVERY.md, *Removing an unfinished install* |
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
| Setup "in progress" but nothing happens | The unit ran and stopped | `./omarchy-bootstrap resume` as root; upstream prints to tty1 only (Ctrl+Alt+F1) and keeps no log file |
| Encryption "not finished yet" in doctor | a migration is staged, or re-encryption is pending | Reboot: the initramfs continues it. Shared waits until it has finished |
| "Setup finishing" in doctor | upstream's last boot has not run yet | Reboot once more |
| SSH port not listening, or no authorized keys | sshd running is only one part of SSH access | `./omarchy-bootstrap dev` → SSH runs `omarchy-setup-security-sshd`, which also opens the firewall and authorizes keys |
| A developer module "failed" | its installer failed, or finished without installing (e.g. no aarch64 build) | The summary says which and why; fix, then rerun `./omarchy-bootstrap dev` |
| A prebuilt CLI crashes at start | 16 KiB pages on Asahi | Prefer the vendor's arm64 build or a from-source install |
| `pacman` lock warning in doctor | A stale `db.lck` | Only if no pacman is running: `sudo rm /var/lib/pacman/db.lck` |
| Slow or failing mirrors | Mirror trouble | Omarchy Mac ships `fix-mirrors.sh` in its repository |

## Shared storage

| Symptom | Cause | Fix |
| --- | --- | --- |
| Linux shows no completion code | Omarchy Mac or its encryption has not finished, or the plan is unknown here | `./omarchy-bootstrap status`; load the Phase 1 token with `resume <token>` once |
| "blocked" | the disk does not match the plan | `./omarchy-bootstrap shared` says why; [SHARED.md](SHARED.md#when-it-stops) says what to do |
| `/mnt/shared` hangs about ten seconds, then "No such device" | Shared is missing (another disk layout, or not created) | Check with `./omarchy-bootstrap doctor`; nothing is written onto the Linux root meanwhile |
| Shared mounted read-only | the kernel remounted exFAT after an error | Shut Linux down, run First Aid on the volume from macOS |
| Shared also appears under `/run/media` | a desktop automounter mounted it too | Unmount that copy; `/mnt/shared` is the managed mount |

## This tool

| Symptom | Cause | Fix |
| --- | --- | --- |
| "The state directory … is a symbolic link / writable by other users / owned by another user" | an unsafe `OMB_STATE_DIR` or state directory | Use a private directory you own; nothing is recorded there, and steps that need a record do not run |
| "Another omarchy-bootstrap run … is using" | a second recording run | Let the first finish; a lock left by a run that exited is cleared automatically |
| "Could not record … stopping before anything changes" | the state directory cannot be written | Free space or fix permissions, then run again |

## Output

| Symptom | Fix |
| --- | --- |
| Boxes or symbols look broken | `--ascii` (automatic on the Linux console) |
| Colours are unreadable | `--no-color` or `NO_COLOR=1` |
| Menus do not respond to arrows | Type the number and Enter; `b` goes back, `q` quits |
