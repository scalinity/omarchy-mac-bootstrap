# shellcheck shell=bash
# shellcheck disable=SC2034 # record and action callbacks set their caller's globals
# Restore only checked bundle bytes, as the everyday user. The journal is
# history: every outcome is re-read from the home, never inferred from exit 0.
# Needs common, state, records, linux, shared, migrate_bundle and agents.

RST_IDS='restore.apply restore.undo'

_recx_replace() {
  case "$1" in
    family) REC_HDR='omb-replace 1' REC_MAX_BYTES=61440 REC_MAX_RECS=0 REC_SEALED=0 REC_ORDER=replace ;;
    spec) [ "$2" = replace ] || return 1; REC_SPEC='dest:bytes' ;;
    card) REC_CARD='*' ;;
    unique) REC_UKEYS=dest ;;
    *) return 1 ;;
  esac
}
_recx_rstlog() {
  case "$1" in
    family) REC_HDR='omb-restore-log 1' REC_MAX_BYTES=16777216 REC_MAX_RECS=0 REC_SEALED=0 REC_ORDER=event ;;
    spec) [ "$2" = event ] || return 1
      REC_SPEC='step:enum(prepare|placed|kept|undo-plan|undone|status) item:bytes dest:bytes before:bytes? after:bytes? state:id reason:text?' ;;
    card) REC_CARD='*' ;;
    unique) REC_UKEYS='' ;;
    *) return 1 ;;
  esac
}

# Agent receipts may occur between ordinary journal events. Admit their
# complete lines separately so neither family's ordered format is weakened.
_recx_rstagent() {
  case "$1" in
    family) REC_HDR='omb-restore-agent 1' REC_MAX_BYTES=16777216 REC_MAX_RECS=0 REC_SEALED=0 REC_ORDER=agent ;;
    spec) [ "$2" = agent ] || return 1; REC_SPEC='tool:enum(claude-code|codex|opencode) ran:enum(1)' ;;
    card) REC_CARD='*' ;;
    unique) REC_UKEYS='' ;;
    *) return 1 ;;
  esac
}

# Fixed read-only reader over paths obtained through sys_path (or our private
# scratch/state). lstat throughout; O_NOFOLLOW on files; no agent/config runs.
# A folder's fingerprint includes names, types, modes, contents and link text.
# Device boundaries, special entries and unreadable trees refuse the item.
# shellcheck disable=SC2016
RST_NODE_PL='
use strict; use warnings; use Errno qw(ENOENT ENOTDIR); use Digest::SHA qw(sha256_hex); use Fcntl qw(:DEFAULT :mode);
my ($p,$how)=@ARGV; my $n=0; my $bytes=0;
sub enc { my $s=shift; $s =~ s/([^A-Za-z0-9._~\/:\@+,-])/sprintf("%%%02X",ord($1))/ge; $s }
sub node {
  my ($p,$dev)=@_; die "too many entries" if ++$n > 20000;
  my @s=lstat($p); die "cannot stat" unless @s;
  die "another device" if defined($dev) && $s[0] != $dev;
  my $m=sprintf("%04o",$s[2]&07777);
  if (S_ISLNK($s[2])) { my $t=readlink($p); die "cannot read link" unless defined $t; return "link:".enc($t) }
  if (S_ISREG($s[2])) {
    die "file too large" if $s[7] > 67108864;
    $bytes += $s[7]; die "tree too large" if $bytes > 2147483648;
    sysopen(my $f,$p,O_RDONLY|O_NOFOLLOW) or die "cannot open";
    my @t=stat($f); die "file changed" unless @t && $s[0]==$t[0] && $s[1]==$t[1];
    my $h=Digest::SHA->new(256); $h->addfile($f); close($f) or die "cannot close";
    return "file:$m:".$h->hexdigest;
  }
  if (S_ISDIR($s[2])) {
    opendir(my $d,$p) or die "cannot list";
    my @names=sort grep { $_ ne "." && $_ ne ".." } readdir($d); closedir($d);
    my $v=""; for my $k (@names) { $v .= enc($k)."\t".node("$p/$k",$s[0])."\n" }
    return "dir:$m:".sha256_hex($v);
  }
  die "special entry";
}
my @s=lstat($p);
if ($how eq "meta") { die "missing" unless @s; print "$s[0] $s[4] ",sprintf("%04o",$s[2]&07777),"\n"; exit }
if (!@s) { die "cannot stat" unless $! == ENOENT || $! == ENOTDIR; print "absent\n"; exit }
my $value=node($p,undef); print $how eq "size" ? "$bytes\n" : "$value\n";
'
_rst_node() { RST_NODE=$(LC_ALL=C perl -e "$RST_NODE_PL" -- "$1" node 2>/dev/null); }
_rst_size() { RST_SIZE=$(LC_ALL=C perl -e "$RST_NODE_PL" -- "$1" size 2>/dev/null); }
_rst_meta() { RST_META=$(LC_ALL=C perl -e "$RST_NODE_PL" -- "$1" meta 2>/dev/null); }
_rst_field() { _rec_field_raw "$1" "$2"; _rec_dec_into "$3" "$REC_RAW"; }
_rst_say() {
  _rst_text "$2"
  local message=$RST_TEXT
  if [ "${RST_CORE:-0}" = 1 ]; then
    if [ "${RST_DEFER:-0}" = 1 ]; then rec_line message level "$1" text "$message" >>"$RST_W/notices"
    else core_message "$1" "$message"; fi
    return
  fi
  case "$1" in ok) ui_ok "$message" ;; warn) ui_warn "$message" ;; fail) ui_fail "$message" ;; *) ui_info "$message" ;; esac
}
_rst_text() { RST_TEXT=$(printf '%s' "$1" | LC_ALL=C tr '\000-\037\177-\377' '?' | cut -c1-2048); }
_rst_wire_row() {
  local value prefix
  rec_line_v row kind "$1" key "$2"
  prefix=$REC_LINE
  shift 2
  for value in "$@"; do
    _rst_text "$value"
    rec_enc_v "$RST_TEXT"
    prefix="$prefix"$'\t'"col=$REC_ENC"
  done
  printf '%s\n' "$prefix"
}

_rst_safe_rel() {
  case "$1" in '' | /* | */ | *//* | . | .. | ./* | ../* | */./* | */../* | */. | */..) return 1 ;; esac
  [ "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')" = "$1" ]
}
# Protect Omarchy's own files, lazy wrappers and the restore's state, including
# an ancestor folder that would move one of them aside whole.
_rst_dest_ok() {
  local p
  _rst_safe_rel "$1" || return 1
  for p in .local/state/omarchy .local/state/omarchy-mac-bootstrap .config/omarchy/defaults/agent .local/bin/claude .local/bin/codex .local/bin/opencode .agents/skills/omarchy .claude/skills/omarchy .codex/skills/omarchy .config/opencode/skills/omarchy; do
    case "$1/" in "$p/"*) return 1 ;; esac
    case "$p/" in "$1/"*) return 1 ;; esac
  done
  case "$RST_HOME/$1/" in "$OMB_STATE_DIR/"*) return 1 ;; esac
  case "$OMB_STATE_DIR/" in "$RST_HOME/$1/"*) return 1 ;; esac
}
_rst_home() {
  _rst_safe_rel "${HOME#/}" || return 1
  case "$HOME" in /*) ;; *) return 1 ;; esac
  RST_HOME=$(sys_path "${HOME%/}")
  [ -d "$RST_HOME" ] && [ ! -L "$RST_HOME" ] && [ -O "$RST_HOME" ] || return 1
  # Also refuse a symlink in the absolute home prefix.
  local p=/ part rest=${RST_HOME#/}
  while [ -n "$rest" ]; do
    part=${rest%%/*}; if [ "$rest" = "$part" ]; then rest=''; else rest=${rest#*/}; fi
    p=${p%/}/$part
    [ -d "$p" ] && [ ! -L "$p" ] || return 1
  done
  _rst_meta "$RST_HOME" || return 1
  RST_DEVICE=${RST_META%% *}
}
# The whole existing prefix must be owned real folders on the home device.
# Create missing parents one at a time only after consent.
_rst_parents() {
  local rel=$1 create=$2 p=$RST_HOME part rest mode=0700
  case "$rel" in .local/* | .config/*) mode=0755 ;; esac
  rest=${rel%/*}; [ "$rest" != "$rel" ] || return 0
  while [ -n "$rest" ]; do
    part=${rest%%/*}; if [ "$rest" = "$part" ]; then rest=''; else rest=${rest#*/}; fi
    p=$p/$part
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then
      [ "$create" = 1 ] || return 0
      run mkdir -p -m "$mode" -- "$p" >/dev/null || return 1
    fi
    [ -d "$p" ] && [ ! -L "$p" ] && [ -O "$p" ] || return 1
    _rst_meta "$p" || return 1
    [ "${RST_META%% *}" = "$RST_DEVICE" ] || return 1
  done
}
_rst_guard() {
  RST_WHY=''
  if [ "$EUID" = 0 ] || [ "${OMB_UID:-}" = 0 ]; then RST_WHY='Restore never runs as root.'; return 1; fi
  [ "${OMB_PLATFORM:-}" = linux ] || { RST_WHY='Restore runs on Linux after Omarchy.'; return 1; }
  cfg_load
  lx_detect >/dev/null 2>&1
  lx_setup_complete || { RST_WHY="Omarchy is not finished: $LX_INCOMPLETE_WHY"; return 1; }
  _rst_home || { RST_WHY='The home is not a real folder owned by this user.'; return 1; }
}

# List only finished UTC directories. DIR can be the media root, bundles
# directory, or an individual finished bundle. Keep descending insertion order
# with a byte comparison, independent of the machine locale; no sort command.
_rst_candidates() {
  local base=$1 p name i j inserted
  RST_CAND=()
  if [ -z "$base" ]; then
    shared_lx_state >/dev/null 2>&1
    [ "$SHARED_STATE" = ready ] || return 0
    base=$(sys_path "$SHARED_MNT")
    shared_lx_mount >/dev/null 2>&1
    if [ "$SH_MOUNT" = armed ]; then
      # Reading the already configured automount triggers it; its identity is
      # checked again before any bundle is opened.
      [ -d "$base/omarchy-mac-bootstrap/bundles" ] || return 0
      shared_lx_mount >/dev/null 2>&1
    fi
    [ "$SH_MOUNT" = verified ] || return 0
  fi
  case "$base" in /*) ;; *) return 0 ;; esac
  [ -d "$base" ] && [ ! -L "$base" ] || return 0
  if [ -d "$base/omarchy-mac-bootstrap/bundles" ]; then base=$base/omarchy-mac-bootstrap/bundles; fi
  if [ -f "$base/bundle.omb" ]; then
    _whole "${base##*/}" '^[0-9]{8}T[0-9]{6}Z$' || return 0
    RST_CAND=("$base")
    return 0
  fi
  for p in "$base"/*; do
    [ -d "$p" ] && [ ! -L "$p" ] || continue
    name=${p##*/}
    _whole "$name" '^[0-9]{8}T[0-9]{6}Z$' || continue
    inserted=0 i=0
    while [ "$i" -lt "${#RST_CAND[@]}" ]; do
      if [[ "$name" > "${RST_CAND[i]##*/}" ]]; then
        j=${#RST_CAND[@]}
        while [ "$j" -gt "$i" ]; do RST_CAND[j]=${RST_CAND[j-1]}; j=$((j - 1)); done
        RST_CAND[i]=$p inserted=1
        break
      fi
      i=$((i + 1))
    done
    [ "$inserted" = 1 ] || RST_CAND+=("$p")
  done
}
_rst_bundle() {
  local wanted=${1:-} p check origin at items size
  RST_BUNDLE='' RST_RUN='' RST_ORIGIN='' RST_AT=''
  : >"$RST_W/bundles"
  _rst_candidates "${OMB_RESTORE_DIR:-}"
  for p in ${RST_CAND[@]+"${RST_CAND[@]}"}; do
    check=ok origin=unknown at=unknown items=0 size=0
    if bndl_check "$p"; then
      rec_find bundle
      rec_get_into origin "$REC_AT_I" model
      rec_get_into at "$REC_AT_I" at
      rec_get_into items "$REC_AT_I" items
      rec_get_into size "$REC_AT_I" bytes
      _bndl_sha "$p/bundle.omb" || return 1
      if [ -z "$RST_BUNDLE" ] && { [ -z "$wanted" ] || [ "$wanted" = "${p##*/}" ] || [ "$wanted" = "$BNDL_SHA" ]; }; then
        RST_BUNDLE=$p RST_ORIGIN=$origin RST_AT=$at
      fi
    else check=$BNDL_WHY; fi
    _rst_wire_row bundles "${p##*/}" "$origin" "$at" "$items" "$size" "$check" >>"$RST_W/bundles" || return 1
  done
  [ -n "$RST_BUNDLE" ] || { RST_WHY='No finished bundle passes the bundle check.'; return 1; }
  # bndl_check's admitted records are copied before another family is read.
  bndl_check "$RST_BUNDLE" || return 1
  RST_BT=("${REC_T[@]}") RST_BL=("${REC_L[@]}") RST_BN=$REC_N
  _bndl_sha "$RST_BUNDLE/bundle.omb" || return 1
  RST_RUN=$BNDL_SHA
  RST_LOG=$OMB_STATE_DIR/restore/runs/$RST_RUN.log
  RST_BACK=$OMB_STATE_DIR/restore/backups/$RST_RUN
}

# The log reader copies only LF-terminated lines, ignoring a torn tail. A bad
# complete record blocks the run. Journal paths never become command paths.
_rst_log_load() {
  local line
  : >"$RST_W/log"
  printf 'omb-restore-agent 1\n' >"$RST_W/agents" || return 1
  RST_LOG_HEADER=0
  _rst_parents "${OMB_STATE_DIR#"$RST_HOME"/}/restore/runs/$RST_RUN.log" 0 || return 1
  [ -e "$RST_LOG" ] || { [ ! -L "$RST_LOG" ]; return; }
  [ -f "$RST_LOG" ] && [ ! -L "$RST_LOG" ] && [ -O "$RST_LOG" ] || return 1
  _bndl_size "$RST_LOG" && [ "$BNDL_SIZE" -le 16777216 ] || return 1
  while IFS= read -r line; do
    case "$line" in
      *$'\tomb-torn=1') continue ;;
      agent$'\t'*) printf '%s\n' "$line" >>"$RST_W/agents" || return 1; continue ;;
    esac
    printf '%s\n' "$line" >>"$RST_W/log" || return 1
  done <"$RST_LOG"
  if [ ! -s "$RST_W/log" ]; then return 0; fi
  RST_LOG_HEADER=1
  rec_admit_file rstagent - "$RST_W/agents" || return 1
  rec_admit_file rstlog - "$RST_W/log" || return 1
  # Strip the header, preserving the admitted bytes and order.
  tail -n +2 "$REC_TMP/doc" >"$RST_W/events"
}
_rst_history() {
  # RST_H_*: the last placement plan and the last completed undo for DEST.
  local line dest step
  RST_H_BEFORE='' RST_H_AFTER='' RST_H_STEP='' RST_H_STATE=''
  [ -f "$RST_W/events" ] || return 0
  while IFS= read -r line; do
    _rst_field "$line" dest dest
    [ "$dest" = "$1" ] || continue
    _rst_field "$line" step step
    if [ "$step" = prepare ] || [ "$step" = undo-plan ] || [ "$step" = kept ]; then
      _rst_field "$line" before RST_H_BEFORE
      _rst_field "$line" after RST_H_AFTER
    fi
    RST_H_STEP=$step
    _rst_field "$line" state RST_H_STATE
  done <"$RST_W/events"
}

# These writers receive scratch paths or fingerprint-only journal lines through
# run. Setting commands use run_withheld so their values never enter its argv
# display or log. Each journal line is flushed; interrupted tails are framed.
rst_stage_write() (
  umask 077
  set -C
  cat -- "$1" >"$2" || exit 1
  chmod "$3" "$2"
)
rst_log_write() (
  umask 077
  local last present=${3:-0}
  if [ ! -e "$1" ]; then (set -C; : >"$1") || exit 1; fi
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || exit 1
  if [ -s "$1" ]; then
    last=$(tail -c 1 "$1" | od -An -tu1 | tr -d ' ')
    # Append a framing marker to an interrupted tail, so the reader ignores
    # exactly that torn line even after later events. No old byte is changed.
    if [ "$last" != 10 ]; then printf '\tomb-torn=1\n' >>"$1" && sync || exit 1; fi
  fi
  if [ "$present" != 1 ]; then printf 'omb-restore-log 1\n' >>"$1" && sync || exit 1; fi
  printf '%s\n' "$2" >>"$1" && sync
)
_rst_append() {
  local line=$1 boundary=$2
  if omb_fail_at restore.log || omb_fail_at "$boundary"; then RST_LOG_FAILED=1; return 1; fi
  if ! run rst_log_write "$RST_LOG" "$line" "${RST_LOG_HEADER:-0}" >/dev/null; then RST_LOG_FAILED=1; return 1; fi
  RST_LOG_HEADER=1
  omb_stop_at restore.log
  omb_stop_at "$boundary"
}
_rst_log() {
  rec_line_v event step "$1" item "$2" dest "$3" before "$4" after "$5" state "$6" reason "${7:-}"
  _rst_append "$REC_LINE" restore.log || return 1
  printf '%s\n' "$REC_LINE" >>"$RST_W/events" || return 1
}
_rst_agent_log() {
  case "$1" in claude-code | codex | opencode) ;; *) return 1 ;; esac
  rec_line_v agent tool "$1" ran 1
  _rst_append "$REC_LINE" restore.agent
}

_rst_ready() {
  local rel p
  [ "$OMB_INTENT" = act ] && [ "$OMB_PERSIST" = 1 ] && [ "$OMB_DRY_RUN" != 1 ] || return 1
  case "$OMB_STATE_DIR/" in "$RST_HOME/"*) ;; *) RST_WHY='Restore state and backups must be inside the home.'; return 1 ;; esac
  rel=${OMB_STATE_DIR#"$RST_HOME"/}/restore/runs/x
  _rst_parents "$rel" 1 || return 1
  rel=${OMB_STATE_DIR#"$RST_HOME"/}/restore/backups/$RST_RUN/x
  _rst_parents "$rel" 1 || return 1
  for p in "$OMB_STATE_DIR/restore" "$OMB_STATE_DIR/restore/runs" "$OMB_STATE_DIR/restore/backups" "$RST_BACK"; do
    run chmod 0700 -- "$p" >/dev/null || return 1
  done

}

_rst_add() {
  # KIND ITEM DEST MODE SOURCE/TARGET: one whole placement unit.
  local n=$RST_N
  RST_KIND[n]=$1 RST_ITEM[n]=$2 RST_DEST[n]=$3 RST_MODE[n]=$4 RST_SRC[n]=${5:-}
  RST_N=$((n + 1))
}
# Build desired trees in private scratch; all file/link entries beneath the
# highest dir of their item belong to that one unit, including empty folders.
_rst_units() {
  local i=0 j t item dest mode src root k rel target
  RST_N=0 RST_KIND=() RST_ITEM=() RST_DEST=() RST_MODE=() RST_SRC=()
  RST_OLD=() RST_NEW=() RST_ACTION=() RST_STATUS=() RST_REASON=()
  while [ "$i" -lt "$RST_BN" ]; do
    t=${RST_BT[i]}
    case "$t" in
      dir | file | link)
        _rst_field "${RST_BL[i]}" item item
        _rst_field "${RST_BL[i]}" dest dest
        root=''
        j=0
        while [ "$j" -lt "$RST_N" ]; do
          if [ "${RST_KIND[j]}" = dir ] && [ "${RST_ITEM[j]}" = "$item" ]; then
            case "$dest/" in "${RST_DEST[j]}/"*) root=$j; break ;; esac
          fi
          j=$((j + 1))
        done
        [ -z "$root" ] || { i=$((i + 1)); continue; }
        _rst_field "${RST_BL[i]}" mode mode
        case "$t" in
          file) _rst_field "${RST_BL[i]}" sha256 src; src=$RST_BUNDLE/objects/$src ;;
          link) _rst_field "${RST_BL[i]}" target src ;;
          dir)
            src=$RST_W/want/$i
            mkdir -p "$src" || return 1
            chmod "$mode" "$src" || return 1
            j=0
            while [ "$j" -lt "$RST_BN" ]; do
              k=${RST_BT[j]}
              case "$k" in dir | file | link) ;; *) j=$((j + 1)); continue ;; esac
              _rst_field "${RST_BL[j]}" item target
              _rst_field "${RST_BL[j]}" dest rel
              if [ "$target" = "$item" ]; then
                case "$rel" in
                  "$dest"/*)
                    rel=${rel#"$dest"/}
                    if [ "${rel%/*}" != "$rel" ]; then mkdir -p "${src}/${rel%/*}" || return 1; fi
                    _rst_field "${RST_BL[j]}" mode target
                    case "$k" in
                      dir) mkdir -p "$src/$rel" && chmod "$target" "$src/$rel" || return 1 ;;
                      file)
                        _rst_field "${RST_BL[j]}" sha256 target
                        [ -f "$RST_BUNDLE/objects/$target" ] && [ ! -L "$RST_BUNDLE/objects/$target" ] || return 1
                        cp "$RST_BUNDLE/objects/$target" "$src/$rel" || return 1
                        _bndl_sha "$src/$rel" && [ "$BNDL_SHA" = "$target" ] || return 1
                        _rst_field "${RST_BL[j]}" mode target
                        chmod "$target" "$src/$rel" || return 1 ;;
                      link) _rst_field "${RST_BL[j]}" target target; ln -s -T -- "$target" "$src/$rel" || return 1 ;;
                    esac
                    ;;
                esac
              fi
              j=$((j + 1))
            done
            ;;
        esac
        _rst_add "$t" "$item" "$dest" "$mode" "$src"
        ;;
      macpath)
        _rst_field "${RST_BL[i]}" item item
        _rst_add note "$item" "@macpath$i" '' "${RST_BL[i]}"
        ;;
      package | setting | skip)
        _rst_field "${RST_BL[i]}" item item
        if [ "$t" = setting ]; then
          _rst_field "${RST_BL[i]}" kind root
          _rst_field "${RST_BL[i]}" name dest
          _rst_add "$t" "$item" "$root:$dest" '' "${RST_BL[i]}"
        else _rst_add "$t" "$item" "@$i" '' "${RST_BL[i]}"; fi
        ;;
    esac
    i=$((i + 1))
  done
  # Sourcing the carried shell file is a generated whole-file placement too.
  i=0
  while [ "$i" -lt "$RST_N" ]; do
    if [ "${RST_DEST[i]}" = .config/omarchy-mac-bootstrap/shell.bash ]; then
      _rst_add bashrc shell:bash .bashrc 0644 ''
      break
    fi
    i=$((i + 1))
  done
}

_rst_unit_destinations() {
  local i=0 j
  while [ "$i" -lt "$RST_N" ]; do
    j=0
    while [ "$j" -lt "$i" ]; do
      [ "${RST_DEST[i]}" != "${RST_DEST[j]}" ] || return 1
      if [ "${RST_KIND[j]}" = dir ]; then case "${RST_DEST[i]}/" in "${RST_DEST[j]}/"*) return 1 ;; esac; fi
      if [ "${RST_KIND[i]}" = dir ]; then case "${RST_DEST[j]}/" in "${RST_DEST[i]}/"*) return 1 ;; esac; fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

# Package grammars are rechecked on Linux, before argv is formed. No repo/name
# reaches omarchy-pkg-add. No fallback method or source build is invented.
_rst_pkg_fields() {
  _rst_field "$1" method RST_METHOD
  _rst_field "$1" target RST_TARGET
  _rst_field "$1" version RST_VERSION
  _rst_field "$1" layer RST_LAYER
}
_rst_pkg_ok() {
  case "$RST_METHOD:$RST_LAYER" in
    pacman:packages | provided:packages | mise:runtimes | mise-backend:tools | npm:tools | uv:tools | cargo-binstall:tools | go:tools | flatpak:tools | agent:ai) ;;
    *) return 1 ;;
  esac
  [ -z "$RST_VERSION" ] || _whole "$RST_VERSION" '^[A-Za-z0-9][A-Za-z0-9._+-]*$' || return 1
  case "$RST_METHOD" in
    pacman) _whole "$RST_TARGET" '^[a-z0-9@_+][a-z0-9@._+-]*$' ;;
    mise) _whole "$RST_TARGET" '^[a-z0-9][a-z0-9-]*$' ;;
    mise-backend) _whole "$RST_TARGET" '^(aqua|github|ubi):[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' ;;
    npm) _whole "$RST_TARGET" '^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$' ;;
    uv | cargo-binstall) _whole "$RST_TARGET" '^[A-Za-z0-9][A-Za-z0-9._-]*$' ;;
    go) _whole "$RST_TARGET" '^[a-z0-9][a-z0-9.-]*\.[a-z]+(/[A-Za-z0-9._~-]+)+$' ;;
    flatpak) _whole "$RST_TARGET" '^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$' ;;
    agent) case "$RST_TARGET" in claude | claude-code | codex | opencode) return 0 ;; *) return 1 ;; esac ;;
    provided) _whole "$RST_TARGET" '^((pkg|cmd):[a-z0-9@_+][a-z0-9@._+-]*|file:/[A-Za-z0-9._/-]+)$' ;;
    *) return 1 ;;
  esac
}
_rst_pkg_present() {
  local p base v executable
  case "$RST_METHOD" in
    pacman) sys_cmd "rst_q_$RST_TARGET" pacman -Q "$RST_TARGET" >/dev/null ;;
    provided)
      p=${RST_TARGET#*:}
      case "$RST_TARGET" in
        pkg:*) sys_cmd "rst_q_$p" pacman -Q "$p" >/dev/null ;;
        cmd:*) sys_has "$p" ;;
        file:*) p=$(sys_path "$p"); [ -f "$p" ] && [ ! -L "$p" ] ;;
      esac ;;
    agent)
      p=$RST_TARGET; [ "$p" != claude ] || p=claude-code
      declare -F agent_observe >/dev/null || return 1
      agent_observe "$p" >/dev/null || return 1
      case "${AG_INSTALLED:-none}" in mise | other) return 0 ;; *) return 1 ;; esac ;;
    mise | mise-backend)
      base=$(sys_path "$HOME/.local/share/mise/installs/$RST_TARGET")
      [ -d "$base" ] && [ ! -L "$base" ] || return 1
      for p in "$base"/*; do
        [ -d "$p" ] && [ ! -L "$p" ] && [ "${p##*/}" != latest ] || continue
        if [ -n "$RST_VERSION" ]; then
          case "${p##*/}" in "$RST_VERSION" | "$RST_VERSION".*) ;; *) continue ;; esac
        fi
        executable=${RST_TARGET##*/}
        case "$executable" in python) executable=python3 ;; rust) executable=rustc ;; erlang) executable=erl ;; esac
        for v in "$p/bin/$executable" "$p/$executable"; do
          [ -f "$v" ] && [ -x "$v" ] && return 0
        done
      done
      return 1 ;;
    uv)
      p=$(sys_path "$HOME/.local/share/uv/tools/$RST_TARGET/uv-receipt.toml")
      [ -f "$p" ] && [ ! -L "$p" ] ;;
    npm)
      base=$(sys_path "$HOME/.local/share/mise/installs/node")
      for v in "$base"/*; do
        [ -d "$v" ] && [ ! -L "$v" ] || continue
        p=$v/lib/node_modules/$RST_TARGET/package.json
        [ -f "$p" ] && [ ! -L "$p" ] && return 0
      done
      return 1 ;;
    cargo-binstall)
      p=$(sys_path "$HOME/.cargo/bin/$RST_TARGET")
      [ -f "$p" ] && [ ! -L "$p" ] && [ -x "$p" ] ;;
    go)
      p=$(sys_path "$HOME/go/bin/${RST_TARGET##*/}")
      [ -f "$p" ] && [ ! -L "$p" ] && [ -x "$p" ] ;;
    flatpak)
      p=$(sys_path "$HOME/.local/share/flatpak/app/$RST_TARGET")
      [ -d "$p" ] && [ ! -L "$p" ] ;;
    *) return 1 ;;
  esac
}
_rst_agent_signed() {
  local id=$1
  [ "$id" != claude ] || id=claude-code
  declare -F agent_observe >/dev/null || return 1
  agent_observe "$id" >/dev/null || return 1
  [ "${AG_SIGNIN:-0}" = 1 ]
}

# Check only whether a named environment variable exists, never its value.
_rst_secrets_needed() {
  local names name __present
  RST_NEEDS=''
  names=$(printf '%s' "$1" | LC_ALL=C awk '{ s=$0; while (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
    print substr(s,RSTART+2,RLENGTH-3); s=substr(s,RSTART+RLENGTH) } }' | awk '!seen[$0]++')
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    _whole "$name" '^[A-Za-z_][A-Za-z0-9_]*$' || return 1
    eval '__present=${'"$name"'+set}'
    if [ "$__present" != set ]; then RST_NEEDS="${RST_NEEDS:+$RST_NEEDS, }$name"; fi
  done <<END_NAMES
$names
END_NAMES
}

_rst_setting_now() {
  local kind tool name f
  _rst_field "$1" kind kind; _rst_field "$1" tool tool; _rst_field "$1" name name
  RST_VALUE='' RST_SETTING_PRESENT=0
  [ "${#name}" -le 512 ] || return 1
  _whole "$name" '^[A-Za-z][A-Za-z0-9._/:@+-]*$' || return 1
  case "$kind:$tool" in
    git:git)
      case "$name" in user.name | user.email | init.defaultBranch | core.editor | core.pager | core.autocrlf | core.whitespace | core.excludesfile | init.defaultbranch | pull.rebase | pull.ff | push.default | push.autosetupremote | push.followtags | fetch.prune | fetch.prunetags | merge.conflictstyle | merge.ff | diff.algorithm | diff.colormoved | rebase.autosquash | rebase.autostash | rebase.updaterefs | rerere.enabled | branch.sort | tag.sort | column.ui | color.ui | help.autocorrect | commit.verbose | status.showuntrackedfiles | log.date | alias.* | url.*.insteadof | url.*.pushinsteadof) ;;
        *) return 1 ;;
      esac
      # git --file reads text only: no includes, pager, filters or helpers.
      f=$RST_HOME/.gitconfig
      _rst_parents .gitconfig 0 && { [ ! -e "$f" ] || { [ -f "$f" ] && [ ! -L "$f" ]; }; } || return 1
      sys_cmd "rst_git_$name" git config --file "$f" --no-includes --get "$name" >"$RST_W/git.value"
      case $? in 0) RST_SETTING_PRESENT=1 ;; 1) ;; *) return 1 ;; esac
      RST_VALUE=$(cat "$RST_W/git.value"; printf '.')
      RST_VALUE=${RST_VALUE%.}
      RST_VALUE=${RST_VALUE%$'\n'}
      ;;
    mcp:claude)
      _whole "$name" '^[A-Za-z0-9][A-Za-z0-9_-]*$' || return 1
      f=$RST_HOME/.claude.json
      _rst_parents .claude.json 0 || return 1
      if [ -e "$f" ] || [ -L "$f" ]; then
        [ -f "$f" ] && [ ! -L "$f" ] || return 1
        RST_VALUE=$(jq -cS --arg k "$name" '.mcpServers[$k] // null' "$f" 2>/dev/null) || return 1
        if [ "$RST_VALUE" = null ]; then RST_VALUE=''; else RST_SETTING_PRESENT=1; fi
      fi
      ;;
    *) return 1 ;;
  esac
  RST_SETTING_FP=$(sha256_str "$RST_SETTING_PRESENT:$RST_VALUE")
}
_rst_review_one() {
  local n=$1 kind=${RST_KIND[$1]} dest=${RST_DEST[$1]} path src v key mode
  RST_ACTION[n]=place RST_STATUS[n]=ready RST_REASON[n]='' RST_OLD[n]=absent RST_NEW[n]=''
  case "$kind" in
    file | dir | link | bashrc)
      path=$RST_HOME/$dest src=${RST_SRC[n]}
      if [ "$kind" = file ]; then
        if [ ! -f "$src" ] || [ -L "$src" ] || ! _bndl_sha "$src" || [ "$BNDL_SHA" != "${src##*/}" ]; then
          RST_STATUS[n]=blocked RST_REASON[n]='The bundle object changed after its check.'; return
        fi
      fi
      if ! _rst_dest_ok "$dest" || ! _rst_parents "$dest" 0 || ! _rst_node "$path"; then
        RST_STATUS[n]=blocked RST_REASON[n]='A protected path, link, device boundary or unreadable entry stops this item.'; return
      fi
      RST_OLD[n]=$RST_NODE
      if [ "$RST_NODE" != absent ]; then
        _rst_meta "$path" || { RST_STATUS[n]=blocked; return; }
        [ "${RST_META%% *}" = "$RST_DEVICE" ] || { RST_STATUS[n]=blocked RST_REASON[n]='The destination is on another device.'; return; }
      fi
      if [ "$kind" = bashrc ]; then
        case "${RST_OLD[n]}" in absent | file:*) ;; *) RST_STATUS[n]=blocked RST_REASON[n]='.bashrc is not a regular file.'; return ;; esac
        src=$RST_W/bashrc
        : >"$src"
        [ "${RST_OLD[n]}" = absent ] || cat "$path" >"$src" || return 1
        if ! grep -qxF 'source ~/.config/omarchy-mac-bootstrap/shell.bash # omarchy-mac-bootstrap' "$src"; then
          printf '\n%s\n' 'source ~/.config/omarchy-mac-bootstrap/shell.bash # omarchy-mac-bootstrap' >>"$src" || return 1
        fi
        RST_SRC[n]=$src
      elif [ "$dest" = .config/opencode/opencode.json ]; then
        case "${RST_OLD[n]}" in absent | file:*) ;; *) RST_STATUS[n]=blocked RST_REASON[n]='OpenCode configuration is not a regular file.'; return ;; esac
        v=$RST_W/opencode.json
        if [ "${RST_OLD[n]}" = absent ]; then key=$RST_W/empty.json; printf '{}\n' >"$key"; else key=$path; fi
        jq -sS 'if length == 2 and all(.[]; type == "object") then .[0] * .[1] else error("configuration must be an object") end' "$key" "$src" >"$v" || {
          RST_STATUS[n]=blocked RST_REASON[n]='OpenCode JSON could not be merged.'; return; }
        src=$v RST_SRC[n]=$v
      fi
      # Never widen the permissions of a replaced file or folder.
      v=${RST_OLD[n]}
      _rst_history "$dest"
      _rst_backup_name "$dest"
      if [ "$v" = absent ] && [ "$RST_H_STEP" != undone ] &&
        _rst_node "$RST_BACKUP" && [ "$RST_NODE" = "$RST_H_BEFORE" ]; then v=$RST_NODE; fi
      case "$kind:$v" in
        file:file:* | bashrc:file:* | dir:dir:*)
          mode=${v#*:}; mode=${mode%%:*}
          printf -v mode '%04o' "$((0$mode & 0${RST_MODE[n]}))"
          RST_MODE[n]=$mode
          if [ "$kind" = dir ]; then chmod "$mode" "$src" || return 1; fi ;;
      esac
      if [ "$kind" = link ]; then
        rec_enc_v "$src"; RST_NEW[n]=link:$REC_ENC
      elif [ "$kind" = dir ]; then
        _rst_node "$src" || return 1; RST_NEW[n]=$RST_NODE
      else
        _bndl_sha "$src" || return 1; RST_NEW[n]=file:${RST_MODE[n]}:$BNDL_SHA
      fi
      _rst_history "$dest"
      _rst_backup_name "$dest"
      if [ "$RST_H_STEP" != undone ] && [ -n "$RST_H_BEFORE" ] && [ "$RST_H_BEFORE" != absent ] &&
        { [ -e "$RST_BACKUP" ] || [ -L "$RST_BACKUP" ]; }; then
        RST_REASON[n]="The original is in $RST_BACKUP; undo returns it when the destination is free."
        case "$RST_H_STEP:$RST_H_STATE" in
          prepare:* | status:blocked | status:failed)
            if [ "${RST_OLD[n]}" != absent ] && [ "${RST_OLD[n]}" != "${RST_NEW[n]}" ] && [ "${RST_OLD[n]}" != "$RST_H_BEFORE" ]; then
              # Keep must not replace an unfinished placement's history with
              # the intervening object's fingerprint: undo still owes the original.
              RST_ACTION[n]=blocked RST_STATUS[n]=blocked
              return
            fi ;;
        esac
      fi
      if [ "${RST_OLD[n]}" = "${RST_NEW[n]}" ]; then
        RST_ACTION[n]=in-place RST_STATUS[n]=in-place
      elif [ "$RST_H_STEP" = kept ] && [ "$RST_H_AFTER" = "${RST_OLD[n]}" ]; then
        RST_ACTION[n]=conflict RST_STATUS[n]=kept
      elif [ "${RST_OLD[n]}" != absent ]; then RST_ACTION[n]=conflict
      fi
      ;;
    package)
      _rst_pkg_fields "${RST_SRC[n]}"
      RST_ACTION[n]=install
      if ! _rst_pkg_ok; then RST_STATUS[n]=blocked RST_REASON[n]='The package target or version is invalid.'
      elif _rst_pkg_present; then
        RST_ACTION[n]=in-place RST_STATUS[n]=in-place
        if [ "$RST_METHOD" = agent ] && ! _rst_agent_signed "$RST_TARGET"; then
          RST_STATUS[n]=needs-sign-in RST_REASON[n]='Installed files are present; sign in with the tool.'
        fi
      else
        case "$RST_METHOD" in
          cargo-binstall | go | flatpak) RST_ACTION[n]=command RST_STATUS[n]=command RST_REASON[n]="$RST_METHOD $RST_TARGET${RST_VERSION:+@$RST_VERSION}" ;;
          provided) RST_STATUS[n]=blocked RST_REASON[n]='The capability Omarchy was expected to provide is missing.' ;;
          pacman) sys_cmd "rst_si_$RST_TARGET" pacman -Si "$RST_TARGET" >/dev/null || { RST_STATUS[n]=blocked RST_REASON[n]='pacman does not offer this package.'; } ;;
          mise | mise-backend | agent) sys_has mise || { RST_STATUS[n]=blocked RST_REASON[n]='mise is unavailable.'; } ;;
          npm | uv) sys_has "$RST_METHOD" || { RST_STATUS[n]=blocked RST_REASON[n]="$RST_METHOD is unavailable."; } ;;
        esac
      fi
      _rst_history "$dest"
      if [ "${RST_STATUS[n]}" = ready ] && [ "$RST_H_STATE" = failed ]; then
        RST_STATUS[n]=failed RST_REASON[n]='The last install did not produce the expected files.'
      fi
      ;;
    setting)
      _rst_field "${RST_SRC[n]}" value v
      if _rst_setting_now "${RST_SRC[n]}"; then
        RST_OLD[n]=$RST_SETTING_FP
        _rst_field "${RST_SRC[n]}" kind key
        if [ "$key" = mcp ]; then v=$(printf '%s' "$v" | jq -cS .) || return 1; fi
        RST_NEW[n]=$(sha256_str "1:$v")
        if [ "${RST_OLD[n]}" = "${RST_NEW[n]}" ]; then RST_ACTION[n]=in-place RST_STATUS[n]=in-place
        elif [ "$RST_SETTING_PRESENT" = 1 ]; then RST_ACTION[n]=conflict
        else RST_ACTION[n]=install; fi
        if [ "${RST_STATUS[n]}" = in-place ] && [ "$key" = mcp ]; then
          _rst_secrets_needed "$v"
          if [ -n "$RST_NEEDS" ]; then RST_STATUS[n]=needs-secret RST_REASON[n]="Set: $RST_NEEDS"; fi
        fi
        _rst_history "$dest"
        if [ "${RST_ACTION[n]}" = conflict ] && [ "$RST_H_STEP" = kept ] && [ "$RST_H_AFTER" = "${RST_OLD[n]}" ]; then RST_STATUS[n]=kept; fi
      else RST_ACTION[n]=command RST_STATUS[n]=command RST_REASON[n]='This setting needs its owner command by hand.'; fi
      ;;
    note)
      _rst_field "${RST_SRC[n]}" path v
      _rst_field "${RST_SRC[n]}" dest key
      RST_ACTION[n]=command RST_STATUS[n]=kept RST_REASON[n]="Source path $v in $key is kept verbatim."
      ;;
    skip)
      _rst_field "${RST_SRC[n]}" reason v
      RST_ACTION[n]=command RST_STATUS[n]=kept RST_REASON[n]=$v
      case "$v" in
        *needs-secret*) RST_ACTION[n]=needs-secret RST_STATUS[n]=needs-secret ;;
        *sign-in* | *signin*) RST_ACTION[n]=needs-sign-in RST_STATUS[n]=needs-sign-in ;;
      esac
      ;;
  esac
}
_rst_load() {
  local wanted=${1:-} n=0
  RST_STATE=blocked RST_WHY='' RST_N=0 RST_BUNDLE='' RST_RUN='' RST_HOME='' RST_ORIGIN='' RST_AT='' RST_COUNTS='0 items'
  omb_tmp_init || return 1
  case "$OMB_TMP" in */omarchy-bootstrap.*) ;; *) RST_WHY='Restore needs its own private scratch.'; return 1 ;; esac
  [ -d "$OMB_TMP" ] && [ ! -L "$OMB_TMP" ] && [ -O "$OMB_TMP" ] || return 1
  RST_W=$OMB_TMP/restore
  [ ! -L "$RST_W" ] && [ ! -L "$RST_W/want" ] || return 1
  rm -rf "$RST_W/want" || return 1
  mkdir -p "$RST_W/want" || return 1
  : >"$RST_W/events"
  : >"$RST_W/bundles"
  _rst_guard || return 0
  _rst_bundle "$wanted" || return 0
  case "$OMB_STATE_DIR/" in "$RST_HOME/"*) ;; *) RST_WHY='Restore state and backups must be inside the home.'; return 0 ;; esac
  if ! _rst_parents "${OMB_STATE_DIR#"$RST_HOME"/}/restore/backups/$RST_RUN/x" 0; then RST_WHY='The backup path is not safe.'; return 0; fi
  _rst_log_load || { RST_WHY='The restore log cannot be read.'; return 0; }
  _rst_units || return 1
  if ! _rst_unit_destinations; then RST_STATE=blocked RST_WHY='Two restore units overlap a destination.'; RST_N=0; return 0; fi
  while [ "$n" -lt "$RST_N" ]; do _rst_review_one "$n" || return 1; n=$((n + 1)); done
  _rst_state
}
_rst_state() {
  local n=0 pending=0 blocked=0 done=0
  while [ "$n" -lt "${RST_N:-0}" ]; do
    case "${RST_STATUS[n]}" in placed | in-place | kept | needs-sign-in | needs-secret) done=$((done + 1)) ;; blocked) blocked=$((blocked + 1)); pending=$((pending + 1)) ;; *) pending=$((pending + 1)) ;; esac
    n=$((n + 1))
  done
  if [ "$pending" = 0 ]; then RST_STATE=complete
  elif [ "$blocked" = "${RST_N:-0}" ]; then RST_STATE=blocked
  elif [ ! -e "$RST_LOG" ]; then RST_STATE=not-started
  else RST_STATE=partial; fi
  RST_COUNTS="$done of ${RST_N:-0} items done; $blocked blocked"
}

# Health uses the status classifier alone: no projection, diff, install or
# persistent write. A subshell keeps the caller's machine/record globals intact.
# Verified means placed/in-place; blocked, untried and person-waiting items
# are pending. An unreadable bundle/log/home is not a zero-item success.
rst_status_counts() (
  local n=0 verified=0 kept=0 failed=0 pending=0
  OMB_INTENT=read OMB_PERSIST=0
  _rst_load >/dev/null 2>&1 || return 1
  [ -n "${RST_BUNDLE:-}" ] && [ -z "$RST_WHY" ] || return 1
  while [ "$n" -lt "$RST_N" ]; do
    case "${RST_STATUS[n]}" in
      placed | in-place) verified=$((verified + 1)) ;;
      kept) kept=$((kept + 1)) ;;
      failed) failed=$((failed + 1)) ;;
      *) pending=$((pending + 1)) ;;
    esac
    n=$((n + 1))
  done
  printf '%s %s %s %s\n' "$verified" "$kept" "$failed" "$pending"
)

_rst_replace_doc() {
  local i=1 gap=0 __v line dest n found
  RST_REPLACE=() RST_INVALID=''
  : >"$RST_W/replace"
  while [ "$i" -le 14 ]; do
    if core_arg_into "replace.$i" __v; then
      [ "$gap" = 0 ] || { RST_INVALID='Replacement parts must be contiguous.'; return 1; }
      printf '%s' "$__v" >>"$RST_W/replace" || return 1
    else gap=1; fi
    i=$((i + 1))
  done
  [ -s "$RST_W/replace" ] || printf 'omb-replace 1\n' >"$RST_W/replace"
  rec_admit_file replace - "$RST_W/replace" || { RST_INVALID='The replacement document does not admit.'; return 1; }
  i=0
  while [ "$i" -lt "$REC_N" ]; do
    rec_get_into dest "$i" dest
    found=0 n=0
    while [ "$n" -lt "$RST_N" ]; do
      if [ "${RST_DEST[n]}" = "$dest" ] && [ "${RST_ACTION[n]}" = conflict ]; then found=1; break; fi
      n=$((n + 1))
    done
    [ "$found" = 1 ] || { RST_INVALID='A replacement names no conflict in this review.'; return 1; }
    RST_REPLACE+=("$dest")
    i=$((i + 1))
  done
}
_rst_replacing() {
  local d
  for d in ${RST_REPLACE[@]+"${RST_REPLACE[@]}"}; do [ "$d" != "$1" ] || return 0; done
  return 1
}
_rst_backup_name() { RST_BACKUP=$RST_BACK/$(sha256_str "$1"); }
# Retain unexpected/partial bytes and older completed cycles without ever
# reusing an occupied name. The no-clobber move checks the chosen name too.
_rst_preserve() {
  local src=$1 base=$2 spare=$2 i=0
  while [ -e "$spare" ] || [ -L "$spare" ]; do i=$((i + 1)); spare=$base.$i; done
  run mv -T --update=none-fail -- "$src" "$spare" >/dev/null
}
_rst_stage_clean() {
  local stage=$1 path=$2 expected=$3
  [ -e "$stage" ] || [ -L "$stage" ] || return 0
  _rst_node "$path" && [ "$RST_NODE" = "$expected" ] || return 1
  _rst_node "$stage" && [ "$RST_NODE" = "$expected" ] || return 1
  run rm -r -- "$stage" >/dev/null
}
_rst_checkpoint() { omb_fail_at "$1" && return 1; return 0; }
_rst_mark() {
  RST_STATUS[$1]=$2 RST_REASON[$1]=${3:-}
  _rst_log status "${RST_ITEM[$1]}" "${RST_DEST[$1]}" '' '' "$2" "${3:-}"
}
# No-clobber at the final name, with -T even for links/files. A directory
# that appears at DEST must never become an implicit parent of the new file.
_rst_transfer() {
  local src=$1 dest=$2 fp=$3 text
  case "$fp" in
    file:*) run ln -T -- "$src" "$dest" >/dev/null && run rm -- "$src" >/dev/null ;;
    link:*) _rec_dec_into text "${fp#link:}"
      run ln -s -T -- "$text" "$dest" >/dev/null && run rm -- "$src" >/dev/null ;;
    dir:*) run mv -T --update=none-fail -- "$src" "$dest" >/dev/null ;;
    *) return 1 ;;
  esac
}
_rst_stage() {
  local n=$1 stage=$2 kind=${RST_KIND[$1]}
  _rst_checkpoint restore.stage || return 1
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    # A stale stage can only be ours if its journal plan binds its bytes.
    _rst_history "${RST_DEST[n]}"
    [ "$RST_H_AFTER" = "${RST_NEW[n]}" ] || return 1
    if _rst_node "$stage" && [ "$RST_NODE" = "${RST_NEW[n]}" ]; then run rm -r -- "$stage" >/dev/null || return 1
    else
      # A short write may leave only part of the stage. Preserve those bytes
      # whole, including an unexpected entry, rather than guessing ownership.
      _rst_backup_name "${RST_DEST[n]}"
      _rst_preserve "$stage" "$RST_BACKUP.stage" || return 1
    fi
  fi
  case "$kind" in
    file | bashrc) run rst_stage_write "${RST_SRC[n]}" "$stage" "${RST_MODE[n]}" >/dev/null || return 1 ;;
    dir)
      [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 1
      run cp -a -T -- "${RST_SRC[n]}" "$stage" >/dev/null || return 1 ;;
    link) run ln -s -T -- "${RST_SRC[n]}" "$stage" >/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  _rst_node "$stage" && [ "$RST_NODE" = "${RST_NEW[n]}" ] || return 1
  run sync >/dev/null || return 1
  omb_stop_at restore.stage
}
_rst_place() {
  local n=$1 dest=${RST_DEST[$1]} path stage old=${RST_OLD[$1]} new=${RST_NEW[$1]} backup
  path=$RST_HOME/$dest stage=$RST_HOME/$dest.omb-new-$RST_RUN
  omb_pause_at restore.recheck
  if ! _rst_parents "$dest" 1 || ! _rst_node "$path" || [ "$RST_NODE" != "$old" ]; then
    _rst_mark "$n" blocked 'The destination changed since the review, or its parent is no longer safe.'
    return
  fi
  _rst_backup_name "$dest"; backup=$RST_BACKUP
  _rst_history "$dest"
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    # Resume only a recorded rename of the exact reviewed original. A second
    # replacement never overwrites that original or reuses its backup name.
    _rst_node "$backup" || return 1
    if [ "$RST_H_STEP" = undone ] && [ "$old" = "$RST_NODE" ]; then
      _rst_preserve "$backup" "$backup.previous" || return 1
      _rst_log prepare "${RST_ITEM[n]}" "$dest" "$old" "$new" ready || return 1
    elif [ "$RST_H_BEFORE" = "$RST_NODE" ] && [ "$RST_H_AFTER" = "$new" ] && [ "$old" = absent ]; then
      # Settle an interrupted backup move before retrying the placement.
      run mv -T --update=none-fail -- "$backup" "$path" >/dev/null || return 1
      old=$RST_H_BEFORE RST_OLD[n]=$RST_H_BEFORE
    elif [ "$RST_H_BEFORE" != "$RST_NODE" ] || [ "$RST_H_AFTER" != "$new" ]; then
      _rst_mark "$n" blocked 'A prior backup needs attention; it will never be overwritten.'; return
    elif [ "$old" = "$RST_NODE" ]; then
      _rst_preserve "$backup" "$backup.previous" || return 1
    else
      _rst_mark "$n" blocked "The original is in $backup; undo returns it when the destination is free."; return
    fi
  else
    _rst_log prepare "${RST_ITEM[n]}" "$dest" "$old" "$new" ready || return 1
  fi
  _rst_stage "$n" "$stage" || { _rst_mark "$n" failed 'The private stage could not be written or read back.'; return; }
  # Recheck both prefix and object after staging, immediately before renaming.
  if ! _rst_parents "$dest" 0 || ! _rst_node "$path" || [ "$RST_NODE" != "$old" ]; then
    _rst_mark "$n" blocked 'The destination changed while staging.'; return
  fi
  if [ "$old" != absent ]; then
    _rst_meta "$path" || return 1
    if [ "${RST_META%% *}" != "$RST_DEVICE" ]; then _rst_mark "$n" blocked 'The destination is on another device.'; return; fi
    _rst_checkpoint restore.backup || { _rst_mark "$n" failed 'The backup move was refused.'; return; }
    run mv -T --update=none-fail -- "$path" "$backup" >/dev/null || { _rst_mark "$n" blocked 'The original could not be moved whole into its backup.'; return; }
    run sync >/dev/null || return 1
    omb_stop_at restore.backup
    if ! _rst_node "$backup" || [ "$RST_NODE" != "$old" ]; then
      run mv -T --update=none-fail -- "$backup" "$path" >/dev/null || return 1
      _rst_mark "$n" blocked 'The original changed while moving; it was put back.'; return
    fi
  fi
  omb_pause_at restore.place
  if ! _rst_parents "$dest" 0 || ! _rst_checkpoint restore.place || ! _rst_transfer "$stage" "$path" "$new"; then
    if [ "$old" != absent ] && _rst_parents "$dest" 0 && [ ! -e "$path" ] && [ ! -L "$path" ]; then
      run mv -T --update=none-fail -- "$backup" "$path" >/dev/null || :
    fi
    _rst_mark "$n" blocked "Placement refused. The original is at $path or its backup $backup; undo returns a backup when the destination is free."; return
  fi
  run sync >/dev/null || return 1
  omb_stop_at restore.place
  if ! _rst_node "$path" || [ "$RST_NODE" != "$new" ]; then _rst_mark "$n" failed 'The placed item did not read back.'; return; fi
  _rst_log placed "${RST_ITEM[n]}" "$dest" "$old" "$new" placed || return 1
  RST_STATUS[n]=placed
}
_rst_install() {
  local n=$1 spec id kind tool name value
  if [ "${RST_KIND[n]}" = setting ]; then
    _rst_setting_now "${RST_SRC[n]}" && [ "$RST_SETTING_FP" = "${RST_OLD[n]}" ] || {
      _rst_mark "$n" blocked 'The setting changed since the review.'; return; }
    _rst_field "${RST_SRC[n]}" kind kind
    _rst_field "${RST_SRC[n]}" tool tool
    _rst_field "${RST_SRC[n]}" name name
    _rst_field "${RST_SRC[n]}" value value
    _rst_backup_name "${RST_DEST[n]}"
    RST_BACKUP=$RST_BACKUP.setting
    _rst_history "${RST_DEST[n]}"
    if [ -e "$RST_BACKUP" ] || [ -L "$RST_BACKUP" ]; then
      if [ "$RST_H_STEP" = undone ]; then _rst_preserve "$RST_BACKUP" "$RST_BACKUP.previous" || return 1
      elif ! _rst_setting_saved "${RST_OLD[n]}"; then
        if [ -z "$RST_H_STEP" ] || [ "$RST_H_BEFORE" = "${RST_OLD[n]}" ]; then
          # A short backup write precedes its prepare event; the original is
          # still the freshly checked setting, so preserve and rebuild it.
          _rst_preserve "$RST_BACKUP" "$RST_BACKUP.partial" || return 1
        else _rst_mark "$n" blocked 'The previous setting backup cannot be verified.'; return; fi
      fi
    fi
    if [ ! -e "$RST_BACKUP" ] && [ ! -L "$RST_BACKUP" ]; then
      (umask 077; printf '%s' "$RST_VALUE" >"$RST_W/setting.value") || return 1
      _rst_checkpoint restore.setting || return 1
      run rst_stage_write "$RST_W/setting.value" "$RST_BACKUP" 0600 >/dev/null || return 1
      run sync >/dev/null || return 1
      omb_stop_at restore.setting
    fi
    _rst_log prepare "${RST_ITEM[n]}" "${RST_DEST[n]}" "${RST_OLD[n]}" "${RST_NEW[n]}" ready || return 1
    if [ "$kind" = git ]; then
      run_withheld 8 git config --file "$RST_HOME/.gitconfig" --no-includes -- "$name" "$value" >/dev/null 2>&1 || :
    else
      declare -F agent_observe >/dev/null || { _rst_mark "$n" blocked 'The AI tool table is unavailable.'; return; }
      agent_observe claude-code >/dev/null
      if [ "${AG_INSTALLED:-none}" = none ]; then _rst_mark "$n" blocked 'Claude Code is not installed.'; return; fi
      run_withheld 5 claude mcp add-json "$name" "$value" --scope user >/dev/null 2>&1 || :
    fi
    _rst_say info "Undo uses the private setting backup $RST_BACKUP (restore undo)."
    if _rst_setting_now "${RST_SRC[n]}" && [ "$RST_SETTING_FP" = "${RST_NEW[n]}" ]; then
      _rst_mark "$n" placed
    else _rst_mark "$n" failed 'The setting did not read back.'; fi
    return
  fi
  _rst_pkg_fields "${RST_SRC[n]}"
  _rst_pkg_ok || return 1
  spec=$RST_TARGET${RST_VERSION:+@$RST_VERSION}
  _rst_log prepare "${RST_ITEM[n]}" "${RST_DEST[n]}" '' '' ready || return 1
  case "$RST_METHOD" in
    mise | mise-backend)
      run env MISE_NODE_COMPILE=false MISE_PYTHON_COMPILE=false MISE_RUBY_COMPILE=false MISE_ERLANG_COMPILE=false mise use -g --quiet "$spec" || : ;;
    npm) run npm install -g --ignore-scripts -- "$spec" || : ;;
    uv) run uv tool install --no-build -- "$RST_TARGET${RST_VERSION:+==$RST_VERSION}" || : ;;
    agent)
      id=$RST_TARGET; [ "$id" != claude ] || id=claude-code
      declare -F agent_install >/dev/null || { _rst_mark "$n" blocked 'The AI tool installer is unavailable.'; return; }
      AG_INSTALL_RAN=0 AG_INSTALL_OUTCOME=failed AG_WHY=''
      if ! agent_install "$id"; then _rst_mark "$n" failed "${AG_WHY:-The AI install did not complete.}"; return; fi
      case "$AG_INSTALL_OUTCOME" in
        success | already-satisfied) ;;
        *) _rst_mark "$n" failed "${AG_WHY:-The AI install has no successful outcome.}"; return ;;
      esac
      if [ "$AG_INSTALL_RAN" = 1 ]; then _rst_agent_log "$id" || return 1; fi
      ;;
  esac
  if _rst_pkg_present; then
    if [ "$RST_METHOD" = agent ] && ! _rst_agent_signed "$RST_TARGET"; then _rst_mark "$n" needs-sign-in 'Installed files are present; sign in with the tool.'
    else _rst_mark "$n" placed; fi
  else _rst_mark "$n" failed 'The installed files are not present.'; fi
}
# Private values are read only for their owner command, never interpolated into
# a journal event, message or reversal hint. Preserve empty/trailing-newline values.
_rst_setting_saved() {
  local expected=$1
  _rst_node "$RST_BACKUP" || return 1
  case "$RST_NODE" in file:0600:*) ;; *) return 1 ;; esac
  [ -O "$RST_BACKUP" ] || return 1
  RST_SAVED_VALUE=$(cat "$RST_BACKUP"; printf '.')
  RST_SAVED_VALUE=${RST_SAVED_VALUE%.}
  RST_SAVED_PRESENT=1
  if [ "$(sha256_str "1:$RST_SAVED_VALUE")" = "$expected" ]; then return 0; fi
  RST_SAVED_PRESENT=0
  [ -z "$RST_SAVED_VALUE" ] && [ "$(sha256_str '0:')" = "$expected" ]
}
_rst_undo_setting() {
  local n=$1 kind name old=$RST_H_BEFORE after=$RST_H_AFTER
  _rst_setting_now "${RST_SRC[n]}" || return 1
  if [ "$RST_SETTING_FP" = "$old" ]; then
    _rst_log undone "${RST_ITEM[n]}" "${RST_DEST[n]}" "$old" "$after" undone; return
  fi
  [ "$RST_SETTING_FP" = "$after" ] || return 1
  _rst_backup_name "${RST_DEST[n]}"; RST_BACKUP=$RST_BACKUP.setting
  _rst_setting_saved "$old" || return 1
  _rst_field "${RST_SRC[n]}" kind kind
  _rst_field "${RST_SRC[n]}" name name
  _rst_log undo-plan "${RST_ITEM[n]}" "${RST_DEST[n]}" "$old" "$after" ready || return 1
  _rst_checkpoint restore.undo || return 1
  if [ "$kind" = git ]; then
    if [ "$RST_SAVED_PRESENT" = 1 ]; then
      run_withheld 8 git config --file "$RST_HOME/.gitconfig" --no-includes -- "$name" "$RST_SAVED_VALUE" >/dev/null 2>&1 || :
    else run git config --file "$RST_HOME/.gitconfig" --no-includes --unset-all -- "$name" >/dev/null 2>&1 || :; fi
  else
    if [ "$RST_SAVED_PRESENT" = 1 ]; then
      run_withheld 5 claude mcp add-json "$name" "$RST_SAVED_VALUE" --scope user >/dev/null 2>&1 || :
    else run claude mcp remove "$name" --scope user >/dev/null 2>&1 || :; fi
  fi
  omb_stop_at restore.undo
  _rst_setting_now "${RST_SRC[n]}" && [ "$RST_SETTING_FP" = "$old" ] || return 1
  _rst_log undone "${RST_ITEM[n]}" "${RST_DEST[n]}" "$old" "$after" undone
}
_rst_commands() {
  local n=$1 kind tool name value
  if [ "${RST_KIND[n]}" = package ]; then
    _rst_pkg_fields "${RST_SRC[n]}"
    case "$RST_METHOD" in
      cargo-binstall) _rst_say info "Run by hand: cargo binstall --disable-strategies compile,quick-install $RST_TARGET${RST_VERSION:+@$RST_VERSION}" ;;
      go) _rst_say info "Run by hand: go install $RST_TARGET@${RST_VERSION:-latest}" ;;
      flatpak) _rst_say info "Run by hand: flatpak install flathub $RST_TARGET" ;;
    esac
  elif [ "${RST_KIND[n]}" = setting ]; then
    _rst_field "${RST_SRC[n]}" kind kind; _rst_field "${RST_SRC[n]}" tool tool
    _rst_field "${RST_SRC[n]}" name name; _rst_field "${RST_SRC[n]}" value value
    if [ "$kind:$tool" = plugin:claude ]; then
      case "$name" in marketplace:*) _rst_say info "Run by hand: claude plugin marketplace add $value" ;;
        *) _rst_say info "Run by hand: claude plugin install $name --scope user" ;; esac
    fi
  fi
}
_rst_progress() {
  local n=$1
  [ "${RST_CORE:-0}" = 1 ] || return 0
  [ "${RST_PROGRESS_SEEN[n]:-0}" != 1 ] || return 0
  RST_PROGRESS_SEEN[n]=1
  RST_PROGRESS_COUNT=$((RST_PROGRESS_COUNT + 1))
  _rst_text "${RST_ITEM[n]}"
  core_emit progress action restore.apply 'done' "$RST_PROGRESS_COUNT" total "$RST_N" unit item label "$RST_TEXT"
}

_rst_apply() {
  local n=0 layer kind needed=0 pkg_failed=0 total=${RST_N:-0} line level text
  local -a packages=() pkg_indexes=()
  local review=${RST_REVIEW:-} bundle=${RST_BUNDLE##*/} stage
  _rst_load "$bundle" && _rst_dataset || return 1
  if [ "$review" != "$RST_GEN" ]; then _rst_say fail 'Restore refused: the review changed.'; return 1; fi
  [ "$RST_STATE" != blocked ] || return 1
  RST_LOG_FAILED=0
  local expected_run=$RST_RUN
  _rst_guard || return 1
  bndl_check "$RST_BUNDLE" && _bndl_sha "$RST_BUNDLE/bundle.omb" && [ "$BNDL_SHA" = "$expected_run" ] || return 1
  if [ "$OMB_DRY_RUN" = 1 ]; then _rst_say info 'Dry run: the review is unchanged; no package, file or log is written.'; return 0; fi
  ui_confirm_word restore 'Apply this reviewed restore? Type restore' || return 1
  while [ "$n" -lt "$total" ]; do
    case "${RST_KIND[n]}" in file | dir | link | bashrc)
      stage=$RST_HOME/${RST_DEST[n]}.omb-new-$RST_RUN
      _rst_history "${RST_DEST[n]}"
      if [ "${RST_OLD[n]}" = "${RST_NEW[n]}" ] && [ "$RST_H_AFTER" = "${RST_NEW[n]}" ] &&
        { [ -e "$stage" ] || [ -L "$stage" ]; }; then
        if ! _rst_stage_clean "$stage" "$RST_HOME/${RST_DEST[n]}" "${RST_NEW[n]}"; then
          _rst_backup_name "${RST_DEST[n]}"
          _rst_ready && _rst_preserve "$stage" "$RST_BACKUP.stage" || return 1
        fi
      fi ;;
    esac
    n=$((n + 1))
  done
  n=0
  # A completed rerun performs no mutation, including log appends or chmod.
  while [ "$n" -lt "$total" ]; do
    case "${RST_STATUS[n]}:${RST_ACTION[n]}" in
      ready:* | failed:* | kept:conflict) if [ "${RST_STATUS[n]}" != kept ] || _rst_replacing "${RST_DEST[n]}"; then needed=1; fi ;;
    esac
    n=$((n + 1))
  done
  RST_PROGRESS_SEEN=() RST_PROGRESS_COUNT=0
  if [ "$needed" != 1 ]; then
    n=0
    while [ "$n" -lt "$total" ]; do _rst_progress "$n"; n=$((n + 1)); done
    return 0
  fi
  _rst_ready || return 1
  RST_DEFER=1
  : >"$RST_W/notices" || return 1
  n=0
  while [ "$n" -lt "$total" ]; do
    if [ "${RST_KIND[n]}" = package ]; then
      if [ "${RST_STATUS[n]}" = blocked ]; then pkg_failed=1; fi
      if [ "${RST_STATUS[n]}" != ready ] && [ "${RST_STATUS[n]}" != failed ]; then n=$((n + 1)); continue; fi
      _rst_pkg_fields "${RST_SRC[n]}"
      if [ "$RST_METHOD" = pacman ]; then
        _rst_log prepare "${RST_ITEM[n]}" "${RST_DEST[n]}" '' '' ready || return 1
        packages+=("$RST_TARGET") pkg_indexes+=("$n")
      fi
    fi
    n=$((n + 1))
  done
  if [ "${#packages[@]}" -gt 0 ]; then
    run omarchy-pkg-add "${packages[@]}" || :
    for n in "${pkg_indexes[@]}"; do
      _rst_pkg_fields "${RST_SRC[n]}"
      if _rst_pkg_present; then _rst_mark "$n" placed || return 1
      else pkg_failed=1; _rst_mark "$n" failed 'pacman -Q does not show the package.' || return 1; fi
      _rst_progress "$n"
    done
  fi
  for layer in runtimes tools ai files settings; do
    n=0
    while [ "$n" -lt "$total" ]; do
      kind=${RST_KIND[n]}
      case "$kind" in
        package) _rst_pkg_fields "${RST_SRC[n]}"; kind=$RST_LAYER ;;
        file | dir | link | bashrc) kind=files ;;
        setting) kind=settings ;;
        skip) kind=files ;;
      esac
      if [ "$kind" = "$layer" ]; then
        case "${RST_STATUS[n]}" in
          in-place | placed | blocked | needs-sign-in | needs-secret) ;;
          command) _rst_commands "$n" ;;
          kept)
            if [ "${RST_ACTION[n]}" = conflict ] && _rst_replacing "${RST_DEST[n]}"; then
              if [ "$pkg_failed" = 1 ]; then _rst_mark "$n" blocked 'An earlier install did not complete.' || return 1
              elif [ "$kind" = files ]; then _rst_place "$n" || return 1
              else _rst_install "$n" || return 1; fi
            fi ;;
          *)
            if [ "$pkg_failed" = 1 ]; then _rst_mark "$n" blocked 'An earlier install did not complete.' || return 1
            elif [ "${RST_ACTION[n]}" = conflict ] && ! _rst_replacing "${RST_DEST[n]}"; then
              _rst_log kept "${RST_ITEM[n]}" "${RST_DEST[n]}" "${RST_OLD[n]}" "${RST_OLD[n]}" kept || return 1
              RST_STATUS[n]=kept
            elif [ "$kind" = files ]; then _rst_place "$n" || return 1
            else _rst_install "$n" || return 1; fi
            ;;
        esac
        _rst_progress "$n"
      fi
      n=$((n + 1))
    done
    n=0
    while [ "$n" -lt "$total" ]; do
      if [ "${RST_KIND[n]}" = package ]; then
        _rst_pkg_fields "${RST_SRC[n]}"
        if [ "$RST_LAYER" = "$layer" ]; then
          case "${RST_STATUS[n]}" in failed | blocked) pkg_failed=1 ;; esac
        fi
      fi
      n=$((n + 1))
    done
  done
  _rst_state
  if [ "${RST_CORE:-0}" = 1 ]; then
    n=0
    while [ "$n" -lt "$total" ]; do
      _rst_progress "$n"
      n=$((n + 1))
    done
    RST_DEFER=0
    while IFS= read -r line; do
      _rst_field "$line" level level; _rst_field "$line" text text
      core_message "$level" "$text"
    done <"$RST_W/notices"
  fi
  _rst_say info "Restore: $RST_STATE; $RST_COUNTS. Omarchy's agent picker chooses its default; permissive launch modes remain Omarchy's choice."
  [ "$RST_STATE" = complete ]
}

# Rebuild a stopped copy only after preserving its partial bytes.
_rst_undo_stage() {
  local stage=$1 backup=$2 old=$3
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    if _rst_node "$stage" && [ "$RST_NODE" = "$old" ]; then return 0; fi
    _rst_preserve "$stage" "$backup.undo-stage" || return 1
  fi
  run cp -a -T -- "$backup" "$stage" >/dev/null || return 1
  _rst_node "$stage" && [ "$RST_NODE" = "$old" ]
}
_rst_undo_file() {
  local n=$1 path=$RST_HOME/${RST_DEST[$1]} stage backup old=$RST_H_BEFORE after=$RST_H_AFTER current step=$RST_H_STEP
  _rst_backup_name "${RST_DEST[n]}"; backup=$RST_BACKUP
  stage=$path.omb-undo-$RST_RUN
  _rst_parents "${RST_DEST[n]}" 0 && _rst_node "$path" || return 1
  current=$RST_NODE
  if [ "$step" = undo-plan ] && [ "$current" = absent ] && { [ -e "$backup.placed" ] || [ -L "$backup.placed" ]; }; then
    if ! _rst_node "$backup.placed" || [ "$RST_NODE" != "$after" ]; then
      run mv -T --update=none-fail -- "$backup.placed" "$path" >/dev/null || return 1
      _rst_say warn "Undo refused: the changed destination was put back from $backup.placed."
      return 1
    fi
  fi
  if [ "$current" = "$old" ]; then
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      if ! _rst_stage_clean "$stage" "$path" "$old"; then _rst_preserve "$stage" "$backup.undo-stage" || return 1; fi
    fi
    _rst_log undone "${RST_ITEM[n]}" "${RST_DEST[n]}" "$old" "$after" undone; return
  fi
  # A stopped/failed placement still owns the original in its named backup.
  # Return it directly when free; never overwrite an intervening editor save.
  if [ "$current" = absent ] && [ "$old" != absent ] &&
    { [ "$step" = prepare ] || [ "$step" = undo-plan ] || { [ "$step" = status ] && [ "$RST_H_STATE" != placed ]; }; }; then
    _rst_node "$backup" && [ "$RST_NODE" = "$old" ] || return 1
    if [ "$step" = undo-plan ]; then
      _rst_node "$backup.placed" && [ "$RST_NODE" = "$after" ] || return 1
      _rst_undo_stage "$stage" "$backup" "$old" || return 1
      _rst_transfer "$stage" "$path" "$old" || return 1
    else run mv -T --update=none-fail -- "$backup" "$path" >/dev/null || return 1; fi
    run sync >/dev/null || return 1
    _rst_log undone "${RST_ITEM[n]}" "${RST_DEST[n]}" "$old" "$after" undone; return
  fi
  if [ "$current" != "$after" ]; then
    _rst_say warn "Undo refused: ${RST_DEST[n]} changed since placement; any original remains in $backup."
    return 1
  fi
  if [ "$old" != absent ]; then
    _rst_node "$backup" && [ "$RST_NODE" = "$old" ] || return 1
  fi
  _rst_ready || return 1
  _rst_log undo-plan "${RST_ITEM[n]}" "${RST_DEST[n]}" "$old" "$after" ready || return 1
  if [ "$old" != absent ]; then _rst_undo_stage "$stage" "$backup" "$old" || return 1; fi
  _rst_checkpoint restore.undo && _rst_parents "${RST_DEST[n]}" 0 || return 1
  if [ -e "$backup.placed" ] || [ -L "$backup.placed" ]; then
    _rst_preserve "$backup.placed" "$backup.placed.previous" || return 1
  fi
  # Judge the bytes that actually moved, after moving them. If an editor saved
  # between the read and rename, put that save back before refusing this item.
  run mv -T --update=none-fail -- "$path" "$backup.placed" >/dev/null || return 1
  if ! _rst_node "$backup.placed" || [ "$RST_NODE" != "$after" ]; then
    run mv -T --update=none-fail -- "$backup.placed" "$path" >/dev/null || {
      _rst_say warn "Undo refused; the changed destination is preserved in $backup.placed."; return 1; }
    _rst_say warn "Undo refused: ${RST_DEST[n]} changed while moving and was put back."
    return 1
  fi
  if [ "$old" != absent ]; then _rst_transfer "$stage" "$path" "$old" || return 1; fi
  run sync >/dev/null || return 1
  omb_stop_at restore.undo
  _rst_node "$path" && [ "$RST_NODE" = "$old" ] || return 1
  _rst_log undone "${RST_ITEM[n]}" "${RST_DEST[n]}" "$old" "$after" undone
}
_rst_undo() {
  local n=$RST_N changed=0
  [ "$RST_STATE" != blocked ] && [ "$n" -gt 0 ] || return 1
  ui_confirm_word undo 'Undo unchanged restored files and settings? Type undo' || return 1
  [ "$OMB_DRY_RUN" != 1 ] || { _rst_say info 'Dry run: no restored items are changed.'; return 0; }
  RST_LOG_FAILED=0
  while [ "$n" -gt 0 ]; do
    n=$((n - 1))
    _rst_history "${RST_DEST[n]}"
    case "$RST_H_STEP" in prepare | placed | status | undo-plan) ;; *) continue ;; esac
    [ -n "$RST_H_AFTER" ] || continue
    case "${RST_KIND[n]}" in
      file | dir | link | bashrc) _rst_undo_file "$n" || changed=1 ;;
      setting) _rst_undo_setting "$n" || { _rst_say warn "Undo refused for setting ${RST_DEST[n]}; its private backup is retained."; changed=1; } ;;
    esac
    [ "$RST_LOG_FAILED" != 1 ] || return 1
  done
  [ "$changed" = 0 ]
}

# -------------------------- Text and protocol projections ------------------
_rst_layer() {
  case "${RST_KIND[$1]}" in
    package) _rst_pkg_fields "${RST_SRC[$1]}"; RST_ROW_LAYER=$RST_LAYER ;;
    setting) RST_ROW_LAYER=settings ;;
    *) RST_ROW_LAYER=files ;;
  esac
}
_rst_default() {
  local seed
  seed=$(sys_path "/etc/skel/$1")
  _rst_node "$seed" && [ "$RST_NODE" != absent ] && [ "$RST_NODE" = "$2" ]
}

_rst_rows() {
  local n=0 kind dest now from label item line op text k diffout tool name
  for kind in review conflicts diff status; do : >"$RST_W/$kind" || return 1; done
  while [ "$n" -lt "${RST_N:-0}" ]; do
    _rst_layer "$n"
    dest=${RST_DEST[n]} item=${RST_ITEM[n]} label=${RST_ITEM[n]}
    case "${RST_KIND[n]}" in
      package)
        _rst_pkg_fields "${RST_SRC[n]}"
        label="$RST_METHOD $RST_TARGET${RST_VERSION:+@$RST_VERSION}"
        dest='' ;;
      setting)
        _rst_field "${RST_SRC[n]}" tool tool
        _rst_field "${RST_SRC[n]}" name name
        label="$tool: $name" ;;
      file | dir | link | bashrc)
        label=$dest
        if [ "${RST_ACTION[n]}" = conflict ] && _rst_default "$dest" "${RST_OLD[n]}"; then label="$dest (Omarchy's default)"; fi ;;
      note)
        label=${RST_REASON[n]}
        _rst_field "${RST_SRC[n]}" dest dest ;;
    esac
    _rst_wire_row review "$item" "$RST_ROW_LAYER" "${RST_KIND[n]}" "$label" "$dest" "${RST_ACTION[n]}" "${RST_STATUS[n]}" >>"$RST_W/review" || return 1
    _rst_wire_row status "$item" "${RST_STATUS[n]}" "${RST_REASON[n]}" >>"$RST_W/status" || return 1
    if [ "${RST_ACTION[n]}" = conflict ]; then
      now=0 from=0
      case "${RST_KIND[n]}" in file | bashrc | dir | link)
        if _rst_size "$RST_HOME/$dest"; then now=$RST_SIZE; fi
        if [ "${RST_KIND[n]}" != link ]; then
          if _rst_size "${RST_SRC[n]}"; then from=$RST_SIZE; fi
        fi ;;
      esac
      kind=other
      if _rst_default "$dest" "${RST_OLD[n]}"; then kind="Omarchy's default"; fi
      _rst_wire_row conflicts "$dest" "$item" "$label" "$kind" "${now:-0}" "${from:-0}" >>"$RST_W/conflicts" || return 1
      case "${RST_KIND[n]}:${RST_OLD[n]}" in
        file:file:* | bashrc:file:*)
          diffout=$RST_W/diff.out
          LC_ALL=C diff -u -- "$RST_HOME/$dest" "${RST_SRC[n]}" 2>/dev/null |
            LC_ALL=C awk 'NR > 2 && NR <= 166 { print substr($0, 1, 1025) } NR == 166 { exit }' >"$diffout" || :
          k=0
          while IFS= read -r line && [ "$k" -lt 160 ]; do
            op=${line:0:1}; text=${line:1:1024}
            case "$op" in ' ' | + | -) ;; *) continue ;; esac
            k=$((k + 1))
            _rst_wire_row diff "$dest#$k" "$dest" "$op" "$text" >>"$RST_W/diff" || return 1
          done <"$diffout"
          if [ "$k" = 0 ]; then _rst_wire_row diff "$dest#0" "$dest" ' ' 'Binary files differ, or no text diff is available.' >>"$RST_W/diff" || return 1; fi
          ;;
      esac
    fi
    n=$((n + 1))
  done
}
_rst_dataset() {
  local f
  _rst_rows || return 1
  : >"$RST_W/dataset"
  printf '%s\n%s\n%s\n' "$RST_STATE" "${RST_RUN:-}" "${RST_WHY:-}" >>"$RST_W/dataset" || return 1
  for f in bundles review conflicts diff status; do cat "$RST_W/$f" >>"$RST_W/dataset" || return 1; done
  # Fingerprints bind every reviewed value, including a same-size edit.
  local n=0
  while [ "$n" -lt "${RST_N:-0}" ]; do
    rec_line node dest "${RST_DEST[n]}" before "${RST_OLD[n]}" after "${RST_NEW[n]}" >>"$RST_W/dataset" || return 1
    n=$((n + 1))
  done
  _bndl_sha "$RST_W/dataset" || return 1
  RST_GEN=$BNDL_SHA
}
_rst_respond() {
  local st
  core_read_prefix || return 1
  { cat "$OMB_TMP/journey.prefix" && cat "$2" && rec_line result status "$3" code "$4" text "${5:-}" next ''; } >"$RST_W/response" || return 1
  core_read_admit "$1" "$RST_W/response"; st=$?
  case "$st" in 0) core_read_publish ;; 2) core_result error representation 'The restore response cannot be represented.' ;; *) core_result error io 'The restore response could not be prepared.' ;; esac
}
rst_row() {
  CA_SCOPE=restore CA_INTENT=act CA_TERMINAL=handoff CA_CANCEL=0 CA_PLATFORM=linux CA_PHASE=restore CA_LIMIT=3 CA_EXPLAIN='Rechecked bundle bytes and home destinations; Keep is the default.'
  case "$1" in
    restore.apply)
      CA_FN=rst_apply CA_GATE=restore CA_LABEL='Restore the environment' CA_PARAMS='bundle review'
      local i=1
      while [ "$i" -le 14 ]; do CA_PARAMS="$CA_PARAMS replace.$i"; i=$((i + 1)); done ;;
    restore.undo) CA_FN=rst_undo CA_GATE=undo CA_LABEL='Undo unchanged restored files' CA_PARAMS='' ;;
    *) return 1 ;;
  esac
}
rst_apply_offer() {
  _rst_load || return 1
  CA_WHY=$RST_WHY
  [ "$RST_STATE" != blocked ]
}
rst_apply_facts() {
  rec_line fact scope restore key gate.restore.apply.bundle label Bundle value "${RST_RUN:-none}" state info
}
rst_apply_params() {
  local i=1
  rec_line param action restore.apply name bundle type bytes kind '' required 1
  rec_line param action restore.apply name review type bytes kind '' required 1
  while [ "$i" -le 14 ]; do
    rec_line param action restore.apply name "replace.$i" type bytes kind omb-replace required 0
    i=$((i + 1))
  done
}
rst_apply_basis() {
  local bundle review
  CORE_BASIS='' RST_INVALID='' RST_INVALID_CODE=invalid
  core_arg_into bundle bundle || return 1
  core_arg_into review review && _whole "$review" '^[0-9a-f]{64}$' || return 1
  _rst_load "$bundle" || return 1
  [ -n "${RST_BUNDLE:-}" ] && [ "${RST_BUNDLE##*/}" = "$bundle" ] || return 1
  _rst_dataset || return 1
  if [ "$review" != "$RST_GEN" ]; then RST_INVALID='The restore review changed.' RST_INVALID_CODE=changed; return 1; fi
  [ "$RST_STATE" != blocked ] && [ "$RST_N" -gt 0 ] || return 1
  _rst_replace_doc || return 1
  _bndl_sha "$RST_W/replace" || return 1
  CORE_BASIS=$(sha256_str "restore.apply:$RST_RUN:$RST_GEN:$BNDL_SHA")
}
rst_apply_validate() {
  local body
  omb_tmp_init || return 1
  RST_W=$OMB_TMP/restore
  mkdir -p "$RST_W" || return 1
  body=$RST_W/validate
  if rst_apply_basis; then
    { rec_line normal name bundle value "${RST_BUNDLE##*/}" && rec_line normal name review value "$RST_GEN" && rec_line review action restore.apply basis "$CORE_BASIS"; } >"$body" || return 1
    _rst_respond validate "$body" 'done' ok
  else
    rec_line invalid name review code "${RST_INVALID_CODE:-invalid}" text "${RST_INVALID:-No checked bundle or valid review is available.}" >"$body" || return 1
    _rst_respond validate "$body" refused "${RST_INVALID_CODE:-invalid}"
  fi
}
rst_apply_run() {
  local bundle
  RST_CORE=1
  core_arg_into bundle bundle || return 1
  core_arg_into review RST_REVIEW || return 1
  [ "$bundle" = "${RST_BUNDLE##*/}" ] || return 1
  _rst_apply
}
rst_apply_judge() {
  local bundle='' log_failed=${RST_LOG_FAILED:-0}
  core_arg_into bundle bundle || :
  _rst_load "$bundle" || return 1
  if [ "$log_failed" = 1 ]; then CORE_FINDING=unexpected CORE_JUDGE_TEXT='The restore log could not be flushed.'; return; fi
  CORE_FINDING=unexpected CORE_JUDGE_TEXT="Restore is $RST_STATE: ${RST_WHY:-$RST_COUNTS}."
  [ "$RST_STATE" != complete ] || CORE_FINDING=completed
}
rst_undo_offer() {
  CA_WHY='No readable restore run is available.'
  (_rst_undo_load && [ "$RST_STATE" != blocked ] && [ "$RST_N" -gt 0 ] && [ -f "$RST_LOG" ])
}
rst_undo_facts() (
  _rst_undo_load || return 1
  rec_line fact scope restore key gate.restore.undo.bundle label Bundle value "${RST_RUN:-none}" state info
  _rst_dataset || return 1
  rec_line fact scope restore key gate.restore.undo.review label 'Current destinations' value "$RST_GEN" state info
)
rst_undo_params() { :; }
# Undo follows the most recently written run, even after another bundle was
# exported. A missing bundle for that run blocks undo instead of choosing one.
_rst_undo_load() {
  local log latest='' wanted
  _rst_load || return 1
  [ -n "$RST_HOME" ] || return 0
  _rst_parents "${OMB_STATE_DIR#"$RST_HOME"/}/restore/runs/x" 0 || { RST_STATE=blocked RST_N=0; return 0; }
  for log in "$OMB_STATE_DIR/restore/runs/"*.log; do
    [ -f "$log" ] && [ ! -L "$log" ] && [ -O "$log" ] || continue
    wanted=${log##*/}; wanted=${wanted%.log}
    _whole "$wanted" '^[0-9a-f]{64}$' || continue
    if [ -z "$latest" ] || [ "$log" -nt "$latest" ]; then latest=$log; fi
  done
  if [ -z "$latest" ]; then RST_STATE=blocked RST_N=0 RST_WHY='No restore run is available to undo.'; return 0; fi
  wanted=${latest##*/}; wanted=${wanted%.log}
  _rst_load "$wanted"
}
rst_undo_run() { RST_CORE=1; _rst_undo_load && [ "$RST_STATE" != blocked ] && [ "$RST_N" -gt 0 ] && _rst_undo; }
rst_undo_judge() {
  local n=0 path bad=0
  CORE_FINDING=unexpected CORE_JUDGE_TEXT='The restore run could not be read for undo.'
  _rst_undo_load || return 1
  [ "$RST_STATE" != blocked ] && [ "$RST_N" -gt 0 ] || return 1
  while [ "$n" -lt "${RST_N:-0}" ]; do
    case "${RST_KIND[n]}" in
      file | dir | link | bashrc | setting)
        _rst_history "${RST_DEST[n]}"
        case "$RST_H_STEP" in kept | undone) ;; *) [ -z "$RST_H_AFTER" ] || bad=1 ;; esac ;;
    esac
    n=$((n + 1))
  done
  CORE_FINDING=unexpected CORE_JUDGE_TEXT='Some restored destinations could not be undone.'
  [ "$bad" != 0 ] || { CORE_FINDING=completed CORE_JUDGE_TEXT='The unchanged restored files were undone.'; }
}
rst_core_op() {
  local body rows st kind
  RST_CORE=1 RST_DEFER=0
  if ! _rst_load || ! _rst_dataset; then core_result error io 'Restore could not be read.'; return; fi
  body=$RST_W/body
  core_read_prefix || return 1
  for kind in bundles review conflicts diff status; do
    core_read_rows "$RST_W/$kind" "$RST_GEN"; st=$?
    [ "$st" = 0 ] || { core_read_failure "$st"; return; }
  done
  case "$1" in
    snapshot)
      core_rows_snapshot "$RST_IDS" >/dev/null || return 1
      {
        rec_line generation id "$RST_GEN" total 0
        rec_line fact scope restore key restore.state label Restore value "$RST_STATE" state info
        rec_line fact scope restore key restore.bundle label Bundle value "${RST_BUNDLE##*/} ${RST_ORIGIN:-} ${RST_AT:-}" state info
        rec_line fact scope restore key restore.counts label Items value "${RST_COUNTS:-0 items}" state info
        rows=0
        if [ -n "${RST_HOME:-}" ] && [ -d "$OMB_STATE_DIR/restore/backups" ] && [ ! -L "$OMB_STATE_DIR/restore/backups" ]; then rows=$(du -sk "$OMB_STATE_DIR/restore/backups" | awk '{print $1 * 1024}'); fi
        rec_line fact scope restore key restore.backups label 'Backup bytes' value "$rows" state info
        if [ "$RST_STATE" = blocked ]; then
          kind=restore.none
          if [ "$EUID" = 0 ] || [ "${OMB_UID:-}" = 0 ]; then kind=restore.root
          elif [ -z "${RST_HOME:-}" ]; then kind=restore.omarchy; fi
          rec_line blocker id "$kind" text "${RST_WHY:-Restore cannot continue.}" fix ''
        fi
        cat "$OMB_TMP/rows.facts" "$OMB_TMP/rows.blockers" "$OMB_TMP/rows.actions" "$OMB_TMP/rows.params"
      } >"$body" || return 1
      _rst_respond snapshot "$body" 'done' ok
      ;;
    detail)
      case "$CORE_REQ_KIND" in bundles | review | conflicts | diff | status) ;; *) core_result refused unavailable 'This restore detail is unavailable.'; return ;; esac
      # Admit the complete projection in bounded batches before exposing its
      # generation, then let the shared pager handle stale/offset checks.
      core_read_prefix || return 1
      core_read_rows "$RST_W/$CORE_REQ_KIND" "$RST_GEN"; st=$?
      [ "$st" = 0 ] || { core_read_failure "$st"; return; }
      rows=$(cat "$RST_W/$CORE_REQ_KIND") || return 1
      core_read_page "$RST_GEN" "$rows"
      ;;
    validate) rst_apply_validate ;;
    *) core_result refused unavailable 'Restore answers snapshot, detail and validate.' ;;
  esac
}
rst_cmd() {
  local what=${1:-} n=0 line folder origin at check
  case "$what" in status | undo | '') ;; *) OMB_RESTORE_DIR=$what ;; esac
  if [ "$what" = undo ]; then _rst_undo_load; else _rst_load; fi || { _rst_say fail 'The restore could not be read.'; return 1; }
  while IFS= read -r line; do
    _rst_field "$line" key folder
    # Repeated col fields are encoded fields; decode the selected positions.
    origin=$(printf '%s\n' "$line" | cut -f4); _rec_dec_into origin "${origin#col=}"
    at=$(printf '%s\n' "$line" | cut -f5); _rec_dec_into at "${at#col=}"
    check=$(printf '%s\n' "$line" | cut -f8); _rec_dec_into check "${check#col=}"
    _rst_say info "$folder: $origin; $at; $check"
  done <"$RST_W/bundles"
  if [ "$RST_STATE" = blocked ]; then _rst_say fail "$RST_WHY"; return 1; fi
  if [ "$what" = undo ]; then _rst_undo; return; fi
  _rst_say info "Bundle ${RST_BUNDLE##*/}: $RST_ORIGIN; $RST_AT. Restore: $RST_STATE."
  while [ "$n" -lt "$RST_N" ]; do
    _rst_say info "${RST_ITEM[n]} -> ${RST_DEST[n]}: ${RST_ACTION[n]} (${RST_STATUS[n]}) ${RST_REASON[n]}"
    if [ "${RST_ACTION[n]}" = command ]; then _rst_commands "$n"; fi
    n=$((n + 1))
  done
  [ "$what" != status ] || return 0
  RST_REPLACE=()
  _rst_dataset || return 1
  RST_REVIEW=$RST_GEN
  _rst_apply
}
