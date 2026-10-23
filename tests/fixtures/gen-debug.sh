# shellcheck shell=bash
# SSH observations, synthetic; none of these commands is executed.
for dbg_class in off key-only passwords key-only-mixed passwords-mixed cannot-tell user; do
  dbg_uid=0 dbg_user=root
  if [ "$dbg_class" = user ]; then dbg_uid=1000 dbg_user=alex; fi
  dbg_dir=dbg-ssh-$dbg_class
  linux "$dbg_dir" "$dbg_uid" "$dbg_user" btrfs /dev/nvme0n1p6 '' '' 0 1 absent
  put "$dbg_dir/cmd/sshd_enabled" disabled
  put "$dbg_dir/cmd/sshd_enabled.rc" 1
  put "$dbg_dir/root/etc/ssh/sshd_config" 'Include /etc/ssh/sshd_config.d/*.conf'
  put "$dbg_dir/root/etc/ssh/sshd_config.d/99-archlinux.conf" 'KbdInteractiveAuthentication no'
  put "$dbg_dir/cmd/sshd_policy" "passwordauthentication no
kbdinteractiveauthentication no
permitrootlogin prohibit-password"
  put "$dbg_dir/cmd/alarm_status" 'alarm L 2026-10-22 0 99999 7 -1'
  if [ "$dbg_class" != off ]; then
    put "$dbg_dir/cmd/sshd_active" active
    rm -f "$dbg_dir/cmd/sshd_active.rc"
  fi
  case "$dbg_class" in
    passwords | passwords-mixed)
      put "$dbg_dir/cmd/sshd_policy" "passwordauthentication yes
kbdinteractiveauthentication no
permitrootlogin prohibit-password"
      put "$dbg_dir/cmd/alarm_status" 'alarm P 2026-10-22 0 99999 7 -1'
      ;;
    cannot-tell)
      put "$dbg_dir/cmd/sshd_policy.rc" 1
      ;;
  esac
  case "$dbg_class" in
    *-mixed)
      sed -e 's/^passwordauthentication/PasswordAuthentication/' \
        -e 's/^kbdinteractiveauthentication/KbdInteractiveAuthentication/' \
        -e 's/^permitrootlogin/PermitRootLogin/' "$dbg_dir/cmd/sshd_policy" >"$dbg_dir/cmd/sshd_policy.mixed"
      mv "$dbg_dir/cmd/sshd_policy.mixed" "$dbg_dir/cmd/sshd_policy"
      ;;
  esac
done
unset dbg_class dbg_uid dbg_user dbg_dir
