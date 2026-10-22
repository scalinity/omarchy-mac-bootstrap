# shellcheck shell=bash
# Resolution (docs/RESOLVER.md): what each inventoried item becomes on
# Omarchy, as a pure function of data/migration-map.omb and the person's
# decisions. Nothing is fetched and nothing is sorted: resolutions come out
# in the items' order, byte for byte the same under Bash 3.2 and Bash 5.
#
# An item's kind names its source; a software item's kind is one of the
# map's sources, and the map entry with that source and the item's name
# says what it becomes. Every other item is configuration: files, or the
# settings Git, the MCP servers and the plugins take through their owners'
# commands. Needs lib/records.sh (the record format) and lib/common.sh.

RES_SOURCES="brew-formula|brew-cask|app|cargo|npm|pnpm|bun|nvm|mise|asdf|uv|pipx|go|ai"
RES_DISPOSITIONS="EXACT|OMARCHY_PROVIDED|NATIVE_EQUIVALENT|RUNTIME|ECOSYSTEM|ALTERNATIVE|MACOS_ONLY|UNSUPPORTED_ARCH"
RES_METHODS="pacman|mise|mise-backend|flatpak|uv|cargo-binstall|go|npm|agent"

# _recx_map WHAT [TYPE] — the stored family `map` (lib/records.sh → _recx):
# general notes, then one `map` record per source and name, then the
# choices of the ALTERNATIVE entries.
_recx_map() {
  case "$1" in
    family) REC_HDR="omb-migration-map 1" REC_MAX_BYTES=1048576 REC_MAX_RECS=0 REC_SEALED=1 REC_ORDER="note map choice" ;;
    spec)
      case "$2" in
        note) REC_SPEC="text:text" ;;
        map) REC_SPEC="id:id source:enum($RES_SOURCES) name:bytes disposition:enum($RES_DISPOSITIONS) method:enum($RES_METHODS)? target:bytes? keep:enum(major|minor|exact)? check:bytes? note:text?" ;;
        choice) REC_SPEC="map:id id:id label:text method:enum($RES_METHODS)? target:bytes?" ;;
        *) return 1 ;;
      esac
      ;;
    card)
      REC_CARD='*'
      [ "$2" = map ] && REC_CARD=+
      return 0
      ;;
    unique)
      case "$2" in
        map) REC_UKEYS="id" ;;
        choice) REC_UKEYS="map id" ;;
        *) REC_UKEYS="" ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# res_target_ok METHOD TARGET — TARGET passes METHOD's own grammar: package
# names are data, passed as one argument each, never placed in a command.
res_target_ok() {
  case "$1" in
    pacman) _whole "$2" '^([a-z0-9][a-z0-9-]*/)?[a-z0-9@_+][a-z0-9@._+-]*$' ;;
    mise) _whole "$2" '^[a-z0-9][a-z0-9-]*$' ;;
    mise-backend) _whole "$2" '^(aqua|github|ubi):[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' ;;
    flatpak) _whole "$2" '^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$' ;;
    uv) _whole "$2" '^[A-Za-z0-9][A-Za-z0-9._-]*$' ;;
    cargo-binstall) _whole "$2" '^[A-Za-z0-9][A-Za-z0-9_-]*$' ;;
    go) _whole "$2" '^[a-z0-9][a-z0-9.-]*\.[a-z]+(/[A-Za-z0-9._~-]+)+$' ;;
    npm) _whole "$2" '^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$' ;;
    agent) case "$2" in claude | codex | opencode) return 0 ;; esac; return 1 ;;
    provided) [ -z "$2" ] || _whole "$2" '^((pkg|cmd):[a-z0-9@_+][a-z0-9@._+-]*|file:/[A-Za-z0-9._/-]+)$' ;;
    *) return 1 ;;
  esac
}

# res_map_load — admit the migration map (data/migration-map.omb) and hold it: RES_M_* per
# entry (source and name as written, the rest decoded), RES_C_* per choice,
# RES_M_IDX the lookup "|source/name=index|". 1 (RES_WHY) when the map does
# not admit, or an entry breaks a rule admission cannot state: a source and
# name twice, a target outside its method's grammar, a disposition without
# what it needs, a choice of anything but an ALTERNATIVE.
res_map_load() {
  local f=$OMB_HOME/data/migration-map.omb i=0 n=0 c=0 j m d t
  RES_WHY="" RES_M_N=0 RES_C_N=0 RES_M_IDX="|"
  RES_M_ID=() RES_M_SRC=() RES_M_NAME=() RES_M_DISP=() RES_M_METHOD=() RES_M_TARGET=() RES_M_KEEP=() RES_M_CHECK=()
  RES_C_MAP=() RES_C_ID=() RES_C_LABEL=() RES_C_METHOD=() RES_C_TARGET=()
  if ! rec_admit_file map - "$f"; then
    RES_WHY="the migration map does not admit (${REC_REASON:-io} at line ${REC_AT:-0})"
    return 1
  fi
  while [ "$i" -lt "$REC_N" ]; do
    case "${REC_T[i]}" in
      map)
        rec_get_into RES_V "$i" id
        RES_M_ID[n]=$RES_V
        _rec_field_raw "${REC_L[i]}" source
        RES_M_SRC[n]=$REC_RAW
        _rec_field_raw "${REC_L[i]}" name
        RES_M_NAME[n]=$REC_RAW
        rec_get_into RES_V "$i" disposition
        RES_M_DISP[n]=$RES_V
        rec_get_into RES_V "$i" method
        RES_M_METHOD[n]=$RES_V
        rec_get_into RES_V "$i" target
        RES_M_TARGET[n]=$RES_V
        rec_get_into RES_V "$i" keep
        RES_M_KEEP[n]=$RES_V
        rec_get_into RES_V "$i" check
        RES_M_CHECK[n]=$RES_V
        n=$((n + 1))
        ;;
      choice)
        rec_get_into RES_V "$i" map
        RES_C_MAP[c]=$RES_V
        rec_get_into RES_V "$i" id
        RES_C_ID[c]=$RES_V
        rec_get_into RES_V "$i" label
        RES_C_LABEL[c]=$RES_V
        rec_get_into RES_V "$i" method
        RES_C_METHOD[c]=$RES_V
        rec_get_into RES_V "$i" target
        RES_C_TARGET[c]=$RES_V
        c=$((c + 1))
        ;;
    esac
    i=$((i + 1))
  done
  RES_M_N=$n RES_C_N=$c
  i=0
  while [ "$i" -lt "$n" ]; do
    case "$RES_M_IDX" in
      *"|${RES_M_SRC[i]}/${RES_M_NAME[i]}="*)
        RES_WHY="map entry ${RES_M_ID[i]}: its source and name are another entry's"
        return 1
        ;;
    esac
    RES_M_IDX="$RES_M_IDX${RES_M_SRC[i]}/${RES_M_NAME[i]}=$i|"
    m=${RES_M_METHOD[i]} t=${RES_M_TARGET[i]} d=${RES_M_DISP[i]}
    case "$d" in
      EXACT | NATIVE_EQUIVALENT | ECOSYSTEM | RUNTIME)
        if [ -z "$m" ] || ! res_target_ok "$m" "$t"; then
          RES_WHY="map entry ${RES_M_ID[i]}: no method, or a target outside its grammar"
          return 1
        fi
        if [ "$d" = RUNTIME ] && { [ "$m" != mise ] || [ -z "${RES_M_KEEP[i]}" ]; }; then
          RES_WHY="map entry ${RES_M_ID[i]}: a runtime is installed by mise and keeps part of its version"
          return 1
        fi
        ;;
      *)
        if [ -n "$m" ] || [ -n "$t" ]; then
          RES_WHY="map entry ${RES_M_ID[i]}: $d installs nothing, so it names no method or target"
          return 1
        fi
        ;;
    esac
    if ! res_target_ok provided "${RES_M_CHECK[i]}" || { [ "$d" = OMARCHY_PROVIDED ] && [ -z "${RES_M_CHECK[i]}" ]; }; then
      RES_WHY="map entry ${RES_M_ID[i]}: its check is not pkg:, cmd: or file:"
      return 1
    fi
    i=$((i + 1))
  done
  j=0
  while [ "$j" -lt "$c" ]; do
    i=0
    while [ "$i" -lt "$n" ] && [ "${RES_M_ID[i]}" != "${RES_C_MAP[j]}" ]; do i=$((i + 1)); done
    if [ "$i" = "$n" ] || [ "${RES_M_DISP[i]}" != ALTERNATIVE ]; then
      RES_WHY="choice ${RES_C_ID[j]}: ${RES_C_MAP[j]} is not an ALTERNATIVE entry"
      return 1
    fi
    m=${RES_C_METHOD[j]}
    if [ "${RES_C_ID[j]}" = keep-default ]; then
      if [ -n "$m" ] || [ -n "${RES_C_TARGET[j]}" ]; then
        RES_WHY="choice keep-default of ${RES_C_MAP[j]} keeps Omarchy's own and installs nothing"
        return 1
      fi
    elif [ -z "$m" ] || ! res_target_ok "$m" "${RES_C_TARGET[j]}"; then
      RES_WHY="choice ${RES_C_ID[j]} of ${RES_C_MAP[j]}: no method, or a target outside its grammar"
      return 1
    fi
    case "${RES_C_ID[j]}" in skip | pacman | version | version:*)
      RES_WHY="choice ${RES_C_ID[j]} of ${RES_C_MAP[j]}: that id is a decision of its own"
      return 1
      ;;
    esac
    j=$((j + 1))
  done
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${RES_M_DISP[i]}" = ALTERNATIVE ]; then
      j=0
      while [ "$j" -lt "$c" ] && [ "${RES_C_MAP[j]}" != "${RES_M_ID[i]}" ]; do j=$((j + 1)); done
      if [ "$j" = "$c" ]; then
        RES_WHY="map entry ${RES_M_ID[i]}: an ALTERNATIVE offers at least one choice"
        return 1
      fi
    fi
    i=$((i + 1))
  done
}

# res_layer METHOD — RES_LAYER: the fixed layer a method's work runs in
# (docs/DECISIONS.md → D27).
res_layer() {
  case "$1" in
    pacman | provided) RES_LAYER=packages ;;
    mise) RES_LAYER=runtimes ;;
    mise-backend | flatpak | uv | cargo-binstall | go | npm) RES_LAYER=tools ;;
    agent) RES_LAYER=ai ;;
    carry) RES_LAYER=files ;;
    git | mcp | plugin) RES_LAYER=settings ;;
    *) RES_LAYER=none ;;
  esac
}

# _res_keep KEEP VERSION — RES_KEPT: the part of VERSION a runtime keeps
# (a leading v and Homebrew's _N revision dropped); empty for a version that
# does not start with a number.
_res_keep() {
  local v=${2#v} rest
  v=${v%%_*}
  RES_KEPT=""
  _whole "$v" '^[0-9]+(\.[0-9]+)*' || return 0
  case "$1" in
    major) RES_KEPT=${v%%.*} ;;
    minor)
      rest=${v#*.}
      if [ "$rest" = "$v" ]; then RES_KEPT=$v; else RES_KEPT=${v%%.*}.${rest%%.*}; fi
      ;;
    *) RES_KEPT=$v ;;
  esac
}

# _res_items ITEMS — RES_I_* per item line of ITEMS (id, kind, name and
# class as written; version decoded) and RES_I_N.
_res_items() {
  local line n=0
  RES_I_ID=() RES_I_KIND=() RES_I_NAME=() RES_I_VER=() RES_I_CLASS=()
  while IFS= read -r line; do
    case "$line" in item"	"*) ;; *) continue ;; esac
    _rec_field_raw "$line" id
    RES_I_ID[n]=$REC_RAW
    _rec_field_raw "$line" kind
    RES_I_KIND[n]=$REC_RAW
    _rec_field_raw "$line" name
    RES_I_NAME[n]=$REC_RAW
    _rec_field_raw "$line" version
    _rec_dec_into RES_V "$REC_RAW"
    RES_I_VER[n]=$RES_V
    _rec_field_raw "$line" class
    RES_I_CLASS[n]=$REC_RAW
    n=$((n + 1))
  done <"$1"
  RES_I_N=$n
}

# _res_decisions FILE — RES_D_IDX "|item id=index|" (the first decision for
# an item counts) with RES_D_CHOICE and RES_D_VALUE (decoded).
_res_decisions() {
  local line n=0 id
  RES_D_IDX="|" RES_D_CHOICE=() RES_D_VALUE=()
  [ -n "$1" ] && [ -f "$1" ] || return 0
  while IFS= read -r line; do
    case "$line" in decision"	"*) ;; *) continue ;; esac
    _rec_field_raw "$line" id
    id=$REC_RAW
    case "$RES_D_IDX" in *"|$id="*) continue ;; esac
    _rec_field_raw "$line" choice
    RES_D_CHOICE[n]=$REC_RAW
    _rec_field_raw "$line" value
    _rec_dec_into RES_V "$REC_RAW"
    RES_D_VALUE[n]=$RES_V
    RES_D_IDX="$RES_D_IDX$id=$n|"
    n=$((n + 1))
  done <"$1"
}

# _res_lookup INDEX KEY — RES_AT: the number INDEX holds for KEY, or 1.
_res_lookup() {
  local rest
  case "$1" in *"|$2="*) ;; *) RES_AT="" && return 1 ;; esac
  rest=${1#*"|$2="}
  RES_AT=${rest%%|*}
}

# _res_runtimes — one version per runtime (D27): RES_RT "|target=v1 v2|"
# holds the distinct kept versions of each runtime's items, in item order,
# with "unknown" for an item whose version is not known; RES_RV
# "|target=V|" the version a decision chose (the first item's decision that
# names one).
_res_runtimes() {
  local i=0 m t vers v pre post
  RES_RT="|" RES_RV="|"
  while [ "$i" -lt "$RES_I_N" ]; do
    if _res_lookup "$RES_M_IDX" "${RES_I_KIND[i]}/${RES_I_NAME[i]}" && [ "${RES_M_DISP[RES_AT]}" = RUNTIME ]; then
      m=$RES_AT t=${RES_M_TARGET[m]}
      _res_keep "${RES_M_KEEP[m]}" "${RES_I_VER[i]}"
      v=${RES_KEPT:-unknown}
      if _res_lookup "$RES_RT" "$t"; then
        vers=$RES_AT
        case " $vers " in
          *" $v "*) ;;
          *)
            pre=${RES_RT%%"|$t="*} post=${RES_RT#*"|$t=$vers|"}
            RES_RT="$pre|$t=$vers $v|$post"
            ;;
        esac
      else
        RES_RT="$RES_RT$t=$v|"
      fi
      if _res_lookup "$RES_D_IDX" "${RES_I_ID[i]}"; then
        case "${RES_D_CHOICE[RES_AT]}" in
          version:*)
            v=${RES_D_CHOICE[RES_AT]#version:}
            _res_lookup "$RES_RV" "$t" || RES_RV="$RES_RV$t=$v|"
            ;;
        esac
      fi
    fi
    i=$((i + 1))
  done
}

# _res_one I — the resolution of item I: RES_LAYER RES_METHOD RES_TARGET
# RES_VERSION RES_GUESS RES_STATE RES_NOTE. The note names the map entry or
# the decision that produced it.
_res_one() {
  local i=$1 m dc="" dv="" j vers v
  RES_METHOD=none RES_TARGET="" RES_VERSION="" RES_GUESS=0 RES_STATE=unresolved RES_NOTE=""
  if _res_lookup "$RES_D_IDX" "${RES_I_ID[i]}"; then
    dc=${RES_D_CHOICE[RES_AT]} dv=${RES_D_VALUE[RES_AT]}
  fi
  if [ "$dc" = skip ]; then
    RES_STATE=skipped RES_NOTE="decision skip"
    res_layer none
    return 0
  fi
  case "${RES_I_KIND[i]}" in
    tap)
      # Homebrew stays on macOS (D25: Linuxbrew never by default).
      RES_STATE=mac-only RES_NOTE="a Homebrew tap: Homebrew stays on macOS"
      res_layer none
      return 0
      ;;
    extension)
      RES_STATE=unsupported RES_NOTE="an editor extension: install it from the editor on Linux"
      res_layer none
      return 0
      ;;
  esac
  case "|$RES_SOURCES|" in
    *"|${RES_I_KIND[i]}|"*) ;;
    *)
      # Configuration: what export carries, files or settings.
      if [ "${RES_I_CLASS[i]}" = mac-only ]; then
        RES_STATE=mac-only RES_NOTE="only means something on this Mac"
      else
        RES_METHOD=carry RES_STATE=resolved RES_NOTE="carried by export"
        case "${RES_I_KIND[i]}" in git | mcp | plugin) RES_METHOD=${RES_I_KIND[i]} ;; esac
      fi
      res_layer "$RES_METHOD"
      return 0
      ;;
  esac
  if ! _res_lookup "$RES_M_IDX" "${RES_I_KIND[i]}/${RES_I_NAME[i]}"; then
    if [ "$dc" = pacman ] && res_target_ok pacman "$dv"; then
      RES_METHOD=pacman RES_TARGET=$dv RES_GUESS=1 RES_STATE=resolved RES_NOTE="decision pacman: a guess, checked on Linux"
    else
      RES_NOTE="not in the migration map: skip it, or try a pacman package"
    fi
    res_layer "$RES_METHOD"
    return 0
  fi
  m=$RES_AT
  RES_NOTE="map ${RES_M_ID[m]}"
  case "${RES_M_DISP[m]}" in
    EXACT | NATIVE_EQUIVALENT | ECOSYSTEM)
      RES_METHOD=${RES_M_METHOD[m]} RES_TARGET=${RES_M_TARGET[m]} RES_STATE=resolved
      if [ -n "${RES_M_KEEP[m]}" ]; then
        _res_keep "${RES_M_KEEP[m]}" "${RES_I_VER[i]}"
        RES_VERSION=$RES_KEPT
      fi
      ;;
    RUNTIME)
      RES_METHOD=mise RES_TARGET=${RES_M_TARGET[m]}
      _res_lookup "$RES_RT" "$RES_TARGET"
      vers=$RES_AT
      if _res_lookup "$RES_RV" "$RES_TARGET"; then
        v=$RES_AT
        # A chosen version is one the Mac has, or any when none is known.
        case " $vers " in
          *" $v "*) ;;
          *) [ "$vers" = unknown ] || v="" ;;
        esac
        _whole "$v" '^[0-9]+(\.[0-9]+){0,2}$' || v=""
      else
        v=""
      fi
      if [ -n "$v" ]; then
        RES_VERSION=$v RES_STATE=resolved RES_NOTE="map ${RES_M_ID[m]}, decision version:$v"
      else
        case "$vers" in
          *" "* | unknown)
            RES_STATE=needs-decision RES_NOTE="map ${RES_M_ID[m]}: Linux gets one version of $RES_TARGET; this Mac has $vers"
            ;;
          *) RES_VERSION=$vers RES_STATE=resolved ;;
        esac
      fi
      ;;
    OMARCHY_PROVIDED)
      RES_METHOD=provided RES_TARGET=${RES_M_CHECK[m]} RES_STATE=resolved
      ;;
    ALTERNATIVE)
      j=0
      while [ "$j" -lt "$RES_C_N" ]; do
        if [ "${RES_C_MAP[j]}" = "${RES_M_ID[m]}" ] && [ "${RES_C_ID[j]}" = "$dc" ]; then
          RES_STATE=resolved RES_NOTE="map ${RES_M_ID[m]}, decision $dc"
          if [ "$dc" = keep-default ]; then
            RES_METHOD=provided RES_TARGET=${RES_M_CHECK[m]}
          else
            RES_METHOD=${RES_C_METHOD[j]} RES_TARGET=${RES_C_TARGET[j]}
          fi
          break
        fi
        j=$((j + 1))
      done
      [ "$RES_STATE" = resolved ] || { RES_STATE=needs-decision RES_NOTE="map ${RES_M_ID[m]}: choose one"; }
      ;;
    MACOS_ONLY) RES_STATE=mac-only ;;
    UNSUPPORTED_ARCH) RES_STATE=unsupported ;;
  esac
  res_layer "$RES_METHOD"
  [ "$RES_STATE" = resolved ] || { RES_METHOD=none RES_TARGET="" RES_VERSION=""; res_layer none; }
  return 0
}

# _res_prepare ITEMS DECISIONS — load the map, the items and the decisions.
_res_prepare() {
  res_map_load || return 1
  _res_items "$1"
  _res_decisions "${2:-}"
  _res_runtimes
}

# res_resolve ITEMS DECISIONS OUT — one profile `resolution` line per item
# line of ITEMS, in ITEMS' order, into OUT. 0; 1 when the map cannot be
# admitted (RES_WHY), and then nothing resolves and OUT is left untouched.
res_resolve() {
  local i=0 out=$3
  _res_prepare "$1" "${2:-}" || return 1
  {
    while [ "$i" -lt "$RES_I_N" ]; do
      _res_one "$i"
      rec_line_v resolution id "" layer "$RES_LAYER" method "$RES_METHOD" target "$RES_TARGET" version "$RES_VERSION" \
        guess "$RES_GUESS" state "$RES_STATE" note "$RES_NOTE"
      # The id is kept exactly as the item wrote it.
      printf '%s\n' "resolution	id=${RES_I_ID[i]}	${REC_LINE#resolution	id=	}" || return 1
      i=$((i + 1))
    done
  } >"$out"
}

# res_choices ITEMS OUT — the decisions each item offers when nothing has
# been decided, for the profile's `choices` detail: `row kind=choice
# key=<item id> col=<choice id> col=<label> col=<guess 0|1>`.
res_choices() {
  local i=0 j v m
  _res_prepare "$1" "" || return 1
  {
    while [ "$i" -lt "$RES_I_N" ]; do
      _res_one "$i"
      case "$RES_STATE" in
        unresolved)
          _res_choice_row "$i" skip "Leave it out" 0
          _res_choice_row "$i" pacman "Try a pacman package of that name, checked on Linux" 1
          ;;
        needs-decision)
          _res_lookup "$RES_M_IDX" "${RES_I_KIND[i]}/${RES_I_NAME[i]}"
          m=$RES_AT
          if [ "${RES_M_DISP[m]}" = ALTERNATIVE ]; then
            j=0
            while [ "$j" -lt "$RES_C_N" ]; do
              [ "${RES_C_MAP[j]}" = "${RES_M_ID[m]}" ] && _res_choice_row "$i" "${RES_C_ID[j]}" "${RES_C_LABEL[j]}" 0
              j=$((j + 1))
            done
          else
            _res_lookup "$RES_RT" "${RES_M_TARGET[m]}"
            for v in $RES_AT; do
              [ "$v" = unknown ] || _res_choice_row "$i" "version:$v" "${RES_M_TARGET[m]} $v" 0
            done
          fi
          _res_choice_row "$i" skip "Leave it out" 0
          ;;
      esac
      i=$((i + 1))
    done
  } >"$2"
}

# _res_choice_row I CHOICE LABEL GUESS — one row, the key as the item wrote it.
_res_choice_row() {
  rec_line_v row kind choice key "" col "$2" col "$3" col "$4"
  printf '%s\n' "row	kind=choice	key=${RES_I_ID[$1]}	${REC_LINE#row	kind=choice	key=	}"
}
