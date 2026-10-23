# shellcheck shell=bash
# The installer's rows of the core's action table (docs/PROTOCOL.md → *The
# action table*). ACT_IDS lists them in the text flow's order; act_row ID
# sets a row's CA_* values and names its functions, act_<row>_offer, _facts,
# _params, _basis, _run and _judge, and where a row has them, _records (the
# region, answer and guide records the journey snapshot carries for it) and
# _validate (`validate select action=<row>` for a row with parameters).
#
# Each row is a stretch of the text flow: its _run calls the text flow's
# own functions in the text flow's order (mac_start, mac_save_plan,
# mac_backup_gate, mac_handoff, shared_create, shared_take_receipt,
# lx_begin, lx_connect, lx_install, lx_in_progress, shared_activate,
# shared_test, dev_main), so the same code runs in fixture and real mode and
# every check the text flow makes still runs. _offer answers what that flow
# would offer now, on a fresh read that writes nothing; _judge decides the
# outcome on a fresh read with the scope's own classifier, after the run or,
# with `reconcile`, after a new boot.
#
# Needs the libraries the entrypoint loads, lib/records.sh and lib/core.sh.

# plan.save's evaluator: the same judgement validate answers with.
# shellcheck source=lib/validate.sh
. "$OMB_HOME/lib/validate.sh" || _omb_unloaded validate

ACT_IDS="plan.save asahi.launch shared.code shared.create network.connect omarchy.start omarchy.resume shared.activate shared.test dev"

# `dev` runs in the omarchy scope: there is no dev scope among the scopes
# both admissions hold (docs/PROTOCOL.md → *Scopes*).
ACT_DEV_SCOPE=omarchy

# The read an offer is made on, once per request (mac or linux); a judge
# always reads again. The rest carry what a run saw to its judge.
ACT_READ="" ACT_ONLINE="" ACT_PLAN_OK=0 ACT_BEFORE="" ACT_PRE="" ACT_SEEN="" ACT_TOOK=1 ACT_RC=0
ACT_CODE="" ACT_ARG=""

# act_row ID — the row's CA_* values (docs/PROTOCOL.md → *The action table*);
# 1 for an id this table does not hold.
act_row() {
  CA_INTENT=act CA_TERMINAL=handoff CA_CANCEL=0 CA_GATE="" CA_PARAMS="" CA_LIMIT=3
  case "$1" in
    plan.save)
      CA_SCOPE=plan CA_INTENT=plan CA_TERMINAL=managed CA_PLATFORM=macos CA_PHASE=macos CA_FN=act_plan
      CA_PARAMS="shared_size linux_size $PLAN_CHOICES"
      CA_LABEL="Save the plan"
      CA_EXPLAIN="Saves the storage plan and the Linux choices; with Shared storage, the plan record its creation is later checked against. Nothing on the disk changes."
      ;;
    asahi.launch)
      CA_SCOPE=asahi CA_GATE=yes CA_PLATFORM=macos CA_PHASE=macos CA_FN=act_asahi
      CA_LABEL="Run the Asahi Alarm installer"
      CA_EXPLAIN="Downloads the official installer, shows where it came from and the exact answers to type, then runs it on this terminal: it resizes macOS as planned, creates the Linux partitions and shuts the Mac down."
      ;;
    shared.code)
      CA_SCOPE=shared CA_TERMINAL=managed CA_PARAMS=code CA_FN=act_code
      case "$OMB_PLATFORM" in
        macos)
          CA_PLATFORM=macos CA_PHASE=macos CA_LABEL="Enter Linux's completion code"
          CA_EXPLAIN="Records the code Linux showed when it finished, once it names this plan and this disk's Linux root. Nothing on the disk changes."
          ;;
        linux)
          CA_PLATFORM=linux CA_PHASE=linux CA_LABEL="Enter the Shared code"
          CA_EXPLAIN="Records the code macOS showed when it created Shared, once it names the partition right after the Linux root. Nothing is mounted yet."
          ;;
        *) return 1 ;;
      esac
      ;;
    shared.create)
      CA_SCOPE=shared CA_GATE=yes CA_PLATFORM=macos CA_PHASE=macos CA_FN=act_create
      CA_LABEL="Create Shared storage"
      CA_EXPLAIN="Adds the one planned exFAT partition right after the Linux root. The whole disk is read again first; create and your sudo password are asked on this terminal."
      ;;
    network.connect)
      CA_SCOPE=network CA_PLATFORM=linux CA_PHASE=linux CA_FN=act_network
      CA_LABEL="Connect to the network"
      CA_EXPLAIN="Opens nmtui on this terminal to join a network; a Wi-Fi password is typed into nmtui, never seen by this tool."
      ;;
    omarchy.start)
      CA_SCOPE=omarchy CA_GATE=start CA_PLATFORM=linux CA_PHASE=linux CA_FN=act_start
      CA_LABEL="Run omarchy-mac-setup"
      CA_EXPLAIN="Downloads Omarchy Mac's setup, checks it, then runs it on this terminal with the saved choices; it reboots on its own and asks for the user's password and the disk passphrase itself."
      ;;
    omarchy.resume)
      CA_SCOPE=omarchy CA_GATE=resume CA_PLATFORM=linux CA_PHASE=linux CA_FN=act_resume
      CA_LABEL="Continue omarchy-mac-setup"
      CA_EXPLAIN="Runs omarchy-mac-setup --resume on this terminal; it continues from where this machine is."
      ;;
    shared.activate)
      CA_SCOPE=shared CA_GATE=mount CA_PLATFORM=linux CA_PHASE=linux CA_FN=act_activate
      CA_LABEL="Mount Shared on every boot"
      CA_EXPLAIN="Adds one managed line to /etc/fstab, keeping every other line, and starts the automount; sudo asks for your password on this terminal."
      ;;
    shared.test)
      CA_SCOPE=shared CA_GATE=test CA_PLATFORM=linux CA_PHASE=linux CA_FN=act_test
      CA_LABEL="Test writing to Shared"
      CA_EXPLAIN="Writes one temporary file to Shared, flushes it, reads it back, compares it and removes it."
      ;;
    dev)
      CA_SCOPE=$ACT_DEV_SCOPE CA_PLATFORM=linux CA_PHASE=dev CA_FN=act_dev
      CA_LABEL="Developer setup"
      CA_EXPLAIN="Asks on this terminal which parts to set up, then sets up each one, using sudo and Omarchy's own helpers where they are needed."
      ;;
    *) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# act_fact ACTION KEY LABEL VALUE [STATE] — one gate fact, as a gate shows it.
act_fact() {
  rec_line fact scope "$CA_SCOPE" key "gate.$1.$2" label "$3" value "$4" state "${5:-info}"
}

# act_param ACTION NAME TYPE REQUIRED [KIND] — one parameter record.
act_param() {
  rec_line param action "$1" name "$2" type "$3" kind "${5:-}" required "$4"
}

# act_cfg_fresh — the saved choices, and nothing left from an earlier read.
act_cfg_fresh() {
  local k
  for k in $CFG_KEYS; do unset "CFG_$k"; done
  cfg_load
}

# act_mac_read [again] — the read macOS rows are offered on: the survey's
# reads (mac_detect), the saved choices and the planner with no reservation.
# It writes nothing; mac_survey's records and its reachability probe belong
# to the run.
act_mac_read() {
  if [ "$ACT_READ" = mac ] && [ "${1:-}" != again ]; then
    mac_plan_compute 0
    return 0
  fi
  mac_detect
  act_cfg_fresh
  mac_plan_compute 0
  ACT_READ=mac
}

# act_lx_read [again] — the read Linux rows are offered on, as lx_begin's
# survey reads it, writing nothing.
act_lx_read() {
  [ "$ACT_READ" = linux ] && [ "${1:-}" != again ] && return 0
  lx_detect
  act_cfg_fresh
  if [ "$OMB_UID" != 0 ] && [ -f "$STATE_SYSTEM_FILE" ] && [ -z "${CFG_user:-}" ]; then
    cfg_load "$STATE_SYSTEM_FILE"
  fi
  ACT_READ=linux ACT_ONLINE=""
}

# act_lx_online — LX_ONLINE as lx_online reads it, once per read.
act_lx_online() {
  if [ -z "$ACT_ONLINE" ]; then
    ACT_ONLINE=0
    if sys_reachable github "https://github.com"; then ACT_ONLINE=1; fi
  fi
  LX_ONLINE=$ACT_ONLINE
}

# act_mac_plannable — 0 when the text flow would plan or launch on this Mac
# now: no blocker, and no install on the disk beyond a resize (mac_start).
act_mac_plannable() {
  local b
  b=$(mac_blockers)
  if [ -n "$b" ]; then
    CA_WHY="This Mac cannot continue: $b"
    return 1
  fi
  asahi_classify
  case "$ASAHI_STATE" in
    none | resized-only) return 0 ;;
  esac
  CA_WHY="An install is already on the disk ($ASAHI_STATE)."
  return 1
}

# act_layout_digest — the SHA-256 of the disk's layout on the last read:
# every partition's offset, size, GUID and type, in disk order.
act_layout_digest() {
  local l
  l=$(geo_canon)
  sha256_str "$l"
}

# act_resized_digest — the same digest with the macOS container's size left
# out: what a resize, and only a resize, leaves as it was (every other
# partition, and so the free space after the container).
act_resized_digest() {
  local l
  l=$(geo_canon | awk -F'|' -v u="$MAC_STORE_UUID" 'BEGIN { OFS = "|" } $3 == u { $2 = "" } { print }')
  sha256_str "$l"
}

# act_lx_seen — what the Omarchy classifier sees, on one line.
act_lx_seen() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' "$LX_OMARCHY_STATE" "$LX_ENC_STATE" "$LX_SETUP_CONF" "$LX_SETUP_BIN" \
    "$LX_ROOT_CRYPT" "$LX_ROOT_SRC" "$LX_ROOT_FS" "$LX_BOOT_SRC" "$LX_BOOT_FS" "$LX_OMARCHY_VERSION"
}

# act_took — ACT_TOOK: 1 when the step reached its typed-word prompt (the
# interface word was taken), 0 when it stopped before it.
act_took() {
  ACT_TOOK=1
  [ -z "${OMB_IFACE_WORD:-}" ] || ACT_TOOK=0
}

# act_judged FINDING TEXT — the classifier's finding, as core_execute_row and
# core_reconcile read it.
act_judged() { CORE_FINDING=$1 CORE_JUDGE_TEXT=$2; }

# act_answer N PROMPT ANSWER NOTE — one of the installer's answers, as an
# answer record; a MiB answer carries its exact bytes.
act_answer() {
  local bytes=''
  case "$3" in
    [1-9]*MiB) if _uint "${3%MiB}"; then bytes=$((${3%MiB} * MIB)); fi ;;
  esac
  rec_line answer n "$1" prompt "$2" value "$3" bytes "$bytes"
}

# act_guide STEP TEXT — one boot step, as a guide record.
act_guide() { rec_line guide id boot step "$1" text "$2"; }

# act_regions [shared] — the disk's regions on the fresh read, in disk order,
# as region records: every partition by its role and every free region. With
# "shared", the free region after the Linux root shows where the Shared
# partition would be created (shared_region).
act_regions() {
  local off size uuid content id role r label start gsize pred succ
  {
    while IFS='|' read -r off size uuid content id role; do
      [ -n "$off" ] || continue
      case "$role" in
        isc | recovery) r=apple ;;
        macos) r=macos ;;
        asahi-stub) r=stub ;;
        efi) r=efi ;;
        linux) r=linux ;;
        *)
          r=other
          if [ -n "$uuid" ] && [ "$uuid" = "${SHARED_UUID:-}" ]; then r=shared; fi
          ;;
      esac
      label=$(printf '%s' "$MAC_PARTS" | awk -F'|' -v u="$uuid" '$5 == u { print $6; exit }' | tr -d '|')
      printf '%s|%s|%s|%s\n' "$off" "$size" "$r" "$id${label:+ $label}"
    done <<EOF
$GEO_PARTS
EOF
    while IFS='|' read -r start gsize pred succ; do
      [ -n "$start" ] || continue
      if [ "${1:-}" = shared ] && [ "$start" = "$SHARED_GAP_START" ]; then
        if [ "$SH_START" -gt "$start" ]; then printf '%s|%s|free|free space\n' "$start" $((SH_START - start)); fi
        printf '%s|%s|shared|Shared, to be created\n' "$SH_START" "$SH_SIZE"
        if [ $((start + gsize)) -gt "$SH_END" ]; then printf '%s|%s|free|free space\n' "$SH_END" $((start + gsize - SH_END)); fi
      else
        printf '%s|%s|free|free space\n' "$start" "$gsize"
      fi
    done <<EOF
$GEO_ALLGAPS
EOF
  } | sort -t'|' -k1,1n | while IFS='|' read -r start size r label; do
    rec_line region start "$start" size "$size" role "$r" label "$label"
  done
}

# ---------------------------------------------------------------------------
# plan.save — managed, scope plan, no word (docs/PROTOCOL.md → *plan.save*)
# ---------------------------------------------------------------------------

# Offered where the text flow asks its storage questions; at execute, the
# request's inputs must also hold on this read, free space, the resize limit
# and the floor included (they are not in the basis).
act_plan_offer() {
  local st
  ACT_PLAN_OK=0
  if [ "${CORE_OP:-}" != execute ]; then
    act_mac_read
    act_mac_plannable
    return
  fi
  val_eval
  st=$?
  case "$st" in
    0)
      ACT_PLAN_OK=1
      return 0
      ;;
    2) CA_WHY="An input no longer holds on this Mac: $(printf '%s' "$VAL_INVALID" | head -1)" ;;
    3) CA_WHY="A trustworthy plan cannot be computed for this Mac now: $VAL_EXPLAIN" ;;
    *) CA_WHY="The plan could not be computed." ;;
  esac
  return 1
}

act_plan_facts() { :; }

# The disk as it is now: the storage screen draws the plan over it.
act_plan_records() { act_regions; }

act_plan_params() {
  local k t
  act_param plan.save shared_size text 1 || return 1
  act_param plan.save linux_size text 1 || return 1
  for k in $PLAN_CHOICES; do
    case "$k" in enc | ssh | dev) t=bool ;; *) t=text ;; esac
    act_param plan.save "$k" "$t" 0 || return 1
  done
}

# The basis is the review's: the normalised inputs, the partitions and the
# computed plan, rebuilt from this request's arguments.
act_plan_basis() {
  CORE_BASIS=""
  if [ "${ACT_PLAN_OK:-0}" != 1 ]; then
    val_eval || return 1
  fi
  CORE_BASIS=$VAL_BASIS
}

act_plan_run() {
  mac_survey
  # The inputs as validated replace the saved choices, as the text flow's
  # answers do, then the text flow saves them.
  CFG_shared=$VAL_SHARED_GB
  CFG_linux=$((VAL_LINUX_BYTES / GB))
  CFG_enc=$VAL_C_enc CFG_user=$VAL_C_user CFG_host=$VAL_C_host CFG_kmap=$VAL_C_kmap
  CFG_tz=$VAL_C_tz CFG_loc=$VAL_C_loc CFG_ssh=$VAL_C_ssh CFG_gh=$VAL_C_gh CFG_dev=$VAL_C_dev
  mac_save_plan
}

# A read-back: the saved choices, read again and judged as inputs on a fresh
# read, must bind the basis this operation was given (so cfg_load gives
# exactly the inputs, on this disk); with Shared, the plan record admits and
# its digest is CFG_plan; without, no record remains; planned_at is set.
act_plan_judge() {
  local want=${CORE_REQ_BASIS:-} k missing=""
  [ "$1" = reconcile ] && want=$CO_BASIS
  act_cfg_fresh
  for k in shared linux enc user host kmap tz loc ssh dev; do
    eval "[ -n \"\${CFG_$k:-}\" ]" || missing="$missing $k"
  done
  if [ -n "$missing" ]; then
    act_judged unexpected "The saved plan is incomplete: nothing is saved for$missing."
    return 0
  fi
  if ! act_plan_readback || [ "$VAL_BASIS" != "$want" ]; then
    act_judged unexpected "The saved choices, read back, are not the inputs this save was given."
    return 0
  fi
  if [ -z "$(state_get planned_at)" ]; then
    act_judged unexpected "The choices are saved, but the plan is not stamped as saved (planned_at)."
    return 0
  fi
  if [ "$CFG_shared" -gt 0 ]; then
    if ! shared_intent_load >/dev/null 2>&1 || [ "${INT_digest:0:8}" != "${CFG_plan:-}" ]; then
      act_judged unexpected "The Shared plan record does not admit, or is not the plan the choices name."
      return 0
    fi
  elif [ -e "$OMB_STATE_DIR/$SHARED_INTENT_FILE" ] || [ -L "$OMB_STATE_DIR/$SHARED_INTENT_FILE" ] || [ -n "${CFG_plan:-}" ]; then
    act_judged unexpected "No Shared storage is planned, but a Shared plan record remains."
    return 0
  fi
  act_judged completed "The plan is saved and read back: Linux $CFG_linux GB$([ "$CFG_shared" -gt 0 ] && printf ', Shared %s GB' "$CFG_shared")."
}

# act_plan_readback — val_eval over the saved choices as if they were the
# request's arguments; the request's own arguments are kept and put back.
act_plan_readback() {
  local st n=$CORE_REQ_ARGS
  local -a names=() values=()
  names=(${CORE_REQ_ARG_NAME[@]+"${CORE_REQ_ARG_NAME[@]}"})
  values=(${CORE_REQ_ARG_VALUE[@]+"${CORE_REQ_ARG_VALUE[@]}"})
  # shellcheck disable=SC2206 # the choices' names, split on purpose
  CORE_REQ_ARG_NAME=(shared_size linux_size $PLAN_CHOICES)
  CORE_REQ_ARG_VALUE=("${CFG_shared}GB" "${CFG_linux}GB" "$CFG_enc" "$CFG_user" "$CFG_host" "$CFG_kmap" "$CFG_tz" "$CFG_loc" "$CFG_ssh" "${CFG_gh:--}" "$CFG_dev")
  [ "$CFG_shared" != 0 ] || CORE_REQ_ARG_VALUE[0]=0
  CORE_REQ_ARGS=11
  val_eval
  st=$?
  CORE_REQ_ARG_NAME=(${names[@]+"${names[@]}"})
  CORE_REQ_ARG_VALUE=(${values[@]+"${values[@]}"})
  CORE_REQ_ARGS=$n
  return "$st"
}

# ---------------------------------------------------------------------------
# asahi.launch — handoff, scope asahi, word yes (experimental first)
# ---------------------------------------------------------------------------

# act_asahi_plan — the saved plan laid out on this read; 1 when there is none
# or it does not hold.
act_asahi_plan() {
  local k
  for k in linux enc user host kmap; do
    if eval "[ -z \"\${CFG_$k:-}\" ]"; then
      CA_WHY="No complete plan is saved: plan.save first."
      return 1
    fi
  done
  mac_plan_compute "${CFG_shared:-0}"
  plan_layout $((CFG_linux * GB))
  if [ "$PLAN_OK" != 1 ]; then
    CA_WHY="The saved plan no longer fits this disk: $PLAN_ERR."
    return 1
  fi
}

act_asahi_offer() {
  act_mac_read
  act_mac_plannable || return 1
  act_asahi_plan || return 1
  # The step's first typed word: on an experimental Mac, mac_start asks
  # "experimental" before the backup gate's "yes".
  if [ "$DEV_TIER" = experimental ]; then CA_GATE=experimental; fi
  return 0
}

act_asahi_facts() {
  local shared=0
  act_asahi_plan || return 0
  [ "${PLAN_SHARED:-0}" -gt 0 ] && shared=$(((PLAN_SHARED + MIB - 1) / MIB * MIB))
  act_fact asahi.launch disk "Disk" "$MAC_DISK, $(fmt_gb "$MAC_DISK_SIZE"), this Mac's internal disk${MAC_DISK_MEDIA:+ ($MAC_DISK_MEDIA)}" || return 1
  if [ "$PLAN_MODE" = resize ]; then
    act_fact asahi.launch macos "macOS" "its container ($MAC_STORE) shrinks to $(fmt_gb "$PLAN_MACOS_NEW"): the installer's New size is $PLAN_ANSWER_RESIZE" || return 1
  else
    act_fact asahi.launch macos "macOS" "not resized: Linux goes into the free space $(mac_gap_label_planned)" || return 1
  fi
  act_fact asahi.launch linux "Creates" "$(fmt_gb "$PLAN_LINUX_ACTUAL") for Linux: the Asahi stub, EFI and Linux root partitions (New OS size: $PLAN_ANSWER_OS)" || return 1
  if [ "$shared" -gt 0 ]; then
    act_fact asahi.launch shared "Shared" "$(fmt_gb "$shared") left free after Linux; created later, from macOS" || return 1
  else
    act_fact asahi.launch shared "Shared" "none planned" || return 1
  fi
  act_fact asahi.launch leaves "Leaves" "Apple's system and recovery partitions, and everything inside macOS" || return 1
  act_fact asahi.launch next "Next" "The installer asks for your macOS password and ends by shutting the Mac down; launch is typed on this terminal after the download" || return 1
  if [ "$DEV_TIER" = experimental ]; then
    act_fact asahi.launch chip "Chip" "$DEV_CHIP support is experimental: display and USB are work in progress upstream" warn || return 1
  fi
}

# The installer's answers as its card computes them (mac_answer_rows), and
# the boot steps after it (mac_boot_steps).
act_asahi_records() {
  act_asahi_plan || return 0
  mac_answer_rows act_answer || return 1
  mac_boot_steps act_guide
}

act_asahi_params() { :; }
act_asahi_basis() { return 1; }

# mac_main's install path from its gates: the survey and gates (mac_start),
# the plan saved as the review saves it, the backup gate, the handoff.
act_asahi_run() {
  local rc layout
  ACT_BEFORE=""
  mac_start
  rc=$?
  ACT_BEFORE=$(geo_canon)
  if [ "$rc" = 2 ]; then
    ui_fail "An install is already on the disk ($ASAHI_STATE); this tool will not start a second one."
    return 1
  fi
  [ "$rc" = 0 ] || return 1
  # The whole layout the launch begins from (mac_handoff holds the disk to
  # it before running the installer), recorded before anything changes, so
  # a reconciliation after a new boot can prove the disk is as it was, or
  # changed only by a resize.
  layout=$(act_layout_digest)
  state_must_set asahi_prelaunch_layout "$layout" || return 1
  layout=$(act_resized_digest)
  state_must_set asahi_prelaunch_resized "$layout" || return 1
  mac_save_plan || return 1
  mac_backup_gate || return 1
  mac_handoff
}

# Asahi's install classification on a fresh read: its partitions in place,
# or macOS resized with every other partition as the layout recorded before
# the launch had it and nothing installed yet (a state the next launch
# continues from), are completed; a disk proven untouched (the installer
# quit at its first question, or never ran) is no effect; anything else
# needs the person.
act_asahi_judge() {
  local before
  act_mac_read again
  asahi_classify
  case "$ASAHI_STATE" in
    installed | pending-first-boot | installed-unverified)
      act_judged completed "Asahi's partitions are in place ($ASAHI_STATE)."
      return 0
      ;;
    resized-only)
      # A state the text flow continues from (asahi_guidance, then planning):
      # the freed space stays free, and the next launch installs into it.
      # Only a resize: every other partition is as the layout recorded
      # before the launch had it.
      before=$(state_get asahi_prelaunch_resized)
      if [ -z "$before" ]; then
        act_judged unexpected "macOS is smaller than before the launch ($ASAHI_WHY), but the layout before the launch is not recorded, so a resize alone cannot be told."
      elif [ "$(act_resized_digest)" != "$before" ]; then
        act_judged unexpected "macOS is smaller than before the launch ($ASAHI_WHY), and another partition changed too: not what the Asahi installer leaves."
      else
        act_judged completed "The installer resized macOS and stopped before installing ($ASAHI_WHY). The next launch continues from there: it installs into the freed space, with no second resize."
      fi
      return 0
      ;;
    none)
      if [ "$1" != reconcile ]; then
        if [ "$GEO_OK" = 1 ] && [ -n "$ACT_BEFORE" ] && [ "$(geo_canon)" = "$ACT_BEFORE" ]; then
          act_judged no-effect "The disk is exactly as it was: the installer changed nothing (it was not launched, was quit, or stopped before resizing)."
          return 0
        fi
      else
        # After a new boot: every partition (its GUID, offset, size and
        # type) is where the layout recorded before the launch had it.
        before=$(state_get asahi_prelaunch_layout)
        if [ "$GEO_OK" = 1 ] && [ -n "$before" ] && [ "$(act_layout_digest)" = "$before" ]; then
          act_judged no-effect "Every partition is where it was before the launch: the installer changed nothing."
          return 0
        fi
      fi
      act_judged unexpected "The partition layout changed, but not in a way the Asahi installer leaves it."
      ;;
    *) act_judged unexpected "The Asahi install is $ASAHI_STATE: ${ASAHI_WHY:-its state could not be read}." ;;
  esac
}

# ---------------------------------------------------------------------------
# shared.code — managed, scope shared, no word: the code typed between the
# two systems (ombdone on macOS, ombshare on Linux)
# ---------------------------------------------------------------------------

act_code_offer() {
  case "$OMB_PLATFORM" in
    macos)
      act_mac_read
      SHARED_TYPED_RECEIPT=""
      shared_mac_state
      case "$SHARED_STATE" in
        awaiting-linux-completion) return 0 ;;
        blocked) [ "$SHARED_NEED_RECEIPT" = 1 ] && return 0 ;;
      esac
      CA_WHY="Shared storage does not wait for Linux's code here (${SHARED_STATE})."
      ;;
    linux)
      act_lx_read
      if shared_lx_begin >/dev/null 2>&1 && [ "$SHARED_STATE" = awaiting-linux-activation ] && [ "$SH_NEED_CODE" = 1 ]; then
        return 0
      fi
      CA_WHY="Shared storage does not wait for macOS's code here (${SHARED_STATE:-not read})."
      ;;
  esac
  return 1
}

act_code_facts() {
  case "$OMB_PLATFORM" in
    macos)
      act_fact shared.code plan "Plan" "$SHARED_DIGEST" || return 1
      geo_part "$ASAHI_ROOT_UUID"
      act_fact shared.code root "Linux root" "${GP_ID:-?}, partition GUID $(guid12 "$ASAHI_ROOT_UUID")..." || return 1
      act_fact shared.code records "Records" "the code, once it names this plan and this Linux root; nothing on the disk changes" || return 1
      ;;
    linux)
      act_fact shared.code plan "Plan" "${CFG_plan:-not known on this system}" || return 1
      act_fact shared.code partition "Partition" "the Basic Data partition right after the Linux root on /dev/${SH_DISK:-?}" || return 1
      act_fact shared.code records "Records" "which partition is Shared; nothing is mounted yet" || return 1
      ;;
  esac
}

act_code_params() {
  case "$OMB_PLATFORM" in
    macos) act_param shared.code code code 1 ombdone ;;
    linux) act_param shared.code code code 1 ombshare ;;
  esac
}

# act_code_check CODE — the text flow's own judgement of a typed code
# (shared_receipt_check, shared_share_code_check) after the offer's read:
# 0 with ACT_CODE, the code in its normal form; 1 with SHARED_CODE_ERR and
# SHARED_CODE_WHY.
act_code_check() {
  ACT_CODE=""
  case "$OMB_PLATFORM" in
    macos)
      shared_receipt_check "$1" || return 1
      ACT_CODE=$(code_make ombdone "$CODE_PLAN" "$CODE_ID12")
      ;;
    linux)
      shared_share_code_check "$1" || return 1
      ACT_CODE=$(code_make ombshare "$CODE_PLAN" "$CODE_ID12")
      ;;
    *) return 1 ;;
  esac
}

# The basis: the action, the normalised code and the gate facts.
act_code_basis() {
  local doc
  CORE_BASIS=""
  core_arg_into code ACT_ARG || return 1
  act_code_check "$ACT_ARG" || return 1
  doc=$(act_code_basis_doc)
  CORE_BASIS=$(sha256_str "omb-basis 1
$doc
")
}

act_code_basis_doc() {
  rec_line basis action shared.code proto "$REC_PROTO" actor_uid "$OMB_UID" home "$OMB_HOME" source "$CORE_SOURCE"
  rec_line input name code value "$ACT_CODE"
  act_code_facts
}

# The code as typed, through the text flow's own taking of it: on macOS
# shared create's first step (shared_take_receipt, and for a partition
# already there, shared_mac_reconcile); on Linux shared activate's
# (shared_lx_take_code). Nothing after it runs.
act_code_run() {
  local code
  core_arg_into code code
  case "$OMB_PLATFORM" in
    macos)
      mac_survey
      shared_mac_state
      shared_status_rows
      case "$SHARED_STATE" in
        awaiting-linux-completion) shared_take_receipt "$code" ;;
        blocked)
          [ "$SHARED_NEED_RECEIPT" = 1 ] || return 1
          shared_take_receipt "$code" || return 1
          shared_mac_state
          [ "$SHARED_STATE" = created ] || return 1
          shared_mac_reconcile
          ;;
        *) return 1 ;;
      esac
      ;;
    linux)
      lx_detect
      act_cfg_fresh
      if [ -z "${CFG_user:-}" ] && [ -f "$STATE_SYSTEM_FILE" ]; then cfg_load "$STATE_SYSTEM_FILE"; fi
      shared_lx_begin || return 1
      if [ "$SHARED_STATE" != awaiting-linux-activation ] || [ "$SH_NEED_CODE" != 1 ]; then return 1; fi
      shared_lx_take_code "$code"
      ;;
  esac
}

# The Shared state on a fresh read, with only what is recorded: a code that
# names this plan and disk recorded, or nothing recorded at all.
act_code_judge() {
  local rec
  SHARED_TYPED_RECEIPT=""
  case "$OMB_PLATFORM" in
    macos)
      act_mac_read again
      shared_mac_state
      rec=$(state_get shared_linux_done)
      if [ -z "$rec" ]; then
        act_judged no-effect "No completion code is recorded; nothing changed."
      elif shared_receipt_ok "$rec" && { [ "$SHARED_STATE" = awaiting-macos-creation ] || [ "$SHARED_STATE" = created ]; }; then
        act_judged completed "Linux's completion code is recorded; Shared storage is $SHARED_STATE."
      else
        act_judged unexpected "A completion code is recorded, but Shared storage is $SHARED_STATE: $SHARED_WHY."
      fi
      ;;
    linux)
      act_lx_read again
      shared_lx_begin >/dev/null 2>&1
      rec=$(state_get shared_id12)
      if [ -z "$rec" ]; then
        act_judged no-effect "No Shared code is recorded; nothing changed."
      elif { [ "$SHARED_STATE" = awaiting-linux-activation ] && [ "$SH_NEED_CODE" = 0 ]; } || [ "$SHARED_STATE" = ready ]; then
        act_judged completed "The Shared partition is identified: /dev/$SH_NAME."
      else
        act_judged unexpected "A Shared code is recorded, but Shared storage is $SHARED_STATE: $SHARED_WHY."
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# shared.create — handoff, scope shared, word yes (then create and sudo on
# the terminal). The Shared critical interval is shared_create_flow's own.
# ---------------------------------------------------------------------------

# Offered once Linux's code is accepted and the region holds the plan, on
# power the creation accepts; or, with no word, where the partition is on
# the disk and its record is still to be made (shared create reconciles it).
act_create_offer() {
  act_mac_read
  SHARED_TYPED_RECEIPT=""
  shared_mac_state
  case "$SHARED_STATE" in
    awaiting-macos-creation)
      shared_region
      if [ "$SH_END" -gt "$SH_ROOM" ]; then
        CA_WHY="The region has room for $(fmt_bytes $((SH_ROOM - SH_START))), less than the $(fmt_bytes "$SH_SIZE") planned."
        return 1
      fi
      if ! shared_power_ok >/dev/null 2>&1; then
        CA_WHY="The Mac is on battery below 50%: connect power before changing the partition table."
        return 1
      fi
      return 0
      ;;
    created)
      if [ "$(state_get shared_uuid)" != "$SHARED_UUID" ] || [ "$TXN_RESULT" = "done" ]; then
        CA_GATE=""
        return 0
      fi
      ;;
  esac
  CA_WHY="Shared storage is $SHARED_STATE here: nothing to create."
  return 1
}

act_create_facts() {
  if [ "$SHARED_STATE" = created ]; then
    act_fact shared.create partition "Shared" "$SHARED_ID, $(fmt_gb "$SHARED_SIZE") exFAT, is on the disk; it is recorded, and nothing is created" || return 1
    return 0
  fi
  shared_region
  act_fact shared.create disk "Disk" "$MAC_DISK, $(fmt_gb "$MAC_DISK_SIZE")${MAC_DISK_MEDIA:+ ($MAC_DISK_MEDIA)}" || return 1
  act_fact shared.create where "Where" "$(fmt_bytes "$SH_START") to $(fmt_bytes "$SH_END"), right after the Linux root" || return 1
  act_fact shared.create creates "Creates" "one exFAT partition named $SHARED_LABEL, $(fmt_gb "$SH_SIZE") ($(fmt_bytes "$SH_SIZE")), empty and not encrypted" || return 1
  act_fact shared.create before "After" "$SHARED_PRED_ID, the Linux root ($(guid12 "$SHARED_PRED_UUID"))" || return 1
  act_fact shared.create after "Before" "${SHARED_SUCC_ID:-the end of the disk}" || return 1
  act_fact shared.create command "Command" "sudo -n diskutil addPartition $SHARED_PRED_ID $SHARED_FS_MAC $SHARED_LABEL $SH_SIZE" || return 1
  act_fact shared.create leaves "Leaves" "every other partition as it is: nothing is resized, moved, erased or formatted" || return 1
  act_fact shared.create next "Next" "create, then your password for sudo, on this terminal; the whole disk is read again before it runs" || return 1
}

# The disk now, with where the Shared partition would be created.
act_create_records() {
  if [ "$SHARED_STATE" = awaiting-macos-creation ]; then
    shared_region
    act_regions shared
  else
    act_regions
  fi
}

act_create_params() { :; }
act_create_basis() { return 1; }

act_create_run() { shared_create ""; }

# The Shared state on a fresh read: the partition the creation was allowed
# to make (by its record or on the disk) and its result recorded (the saved
# shared_uuid is that partition's) is completed; the partition with its
# result unrecorded keeps the barrier, until a reconciliation after a new
# boot records what the creation record proves; the region still free with no
# creation record left (nothing was created) is no effect; anything else
# stops.
act_create_judge() {
  SHARED_TYPED_RECEIPT=""
  act_mac_read again
  shared_mac_state
  case "$SHARED_STATE" in
    created)
      # After a new boot, a creation record that holds the partition on this
      # fresh read: its result recorded now, as the text flow records a
      # partition already there (nothing is created again).
      if [ "$1" = reconcile ] && [ "$TXN_RESULT" = "done" ]; then
        shared_mac_reconcile
      fi
      if [ "$(state_get shared_uuid)" = "$SHARED_UUID" ]; then
        act_judged completed "Shared storage is on the disk and recorded: $SHARED_ID, $(fmt_gb "$SHARED_SIZE") exFAT."
      else
        act_judged unexpected "Shared storage is on the disk ($SHARED_ID, $(fmt_gb "$SHARED_SIZE") exFAT), but its result is not recorded; the creation record keeps what happened."
      fi
      ;;
    awaiting-macos-creation)
      if [ -e "$OMB_STATE_DIR/$SHARED_TXN_FILE" ] || [ -L "$OMB_STATE_DIR/$SHARED_TXN_FILE" ]; then
        act_judged unexpected "A creation record remains, and the disk does not show what it was allowed to produce."
      else
        act_judged no-effect "The reserved region is still free and every planned partition is unchanged: nothing was created."
      fi
      ;;
    *) act_judged unexpected "Shared storage is $SHARED_STATE: $SHARED_WHY." ;;
  esac
}

# ---------------------------------------------------------------------------
# network.connect — handoff, scope network, no word (its first prompt is a
# yes/no)
# ---------------------------------------------------------------------------

# lx_main reaches the network before Omarchy's setup, as root, when offline.
act_network_offer() {
  act_lx_read
  act_lx_online
  if [ -n "$(lx_blockers)" ]; then
    CA_WHY="This machine cannot continue."
    return 1
  fi
  case "$LX_OMARCHY_STATE" in
    absent | partial) ;;
    *)
      CA_WHY="Omarchy is $LX_OMARCHY_STATE: the network step comes before its setup."
      return 1
      ;;
  esac
  if [ "$OMB_UID" != 0 ] && [ "$OMB_DRY_RUN" != 1 ]; then
    CA_WHY="omarchy-mac-setup must run as root, and the network step comes before it."
    return 1
  fi
  if [ "$LX_ROUTE" = 1 ] && [ "$LX_ONLINE" = 1 ]; then
    CA_WHY="This machine is online."
    return 1
  fi
  return 0
}

act_network_facts() {
  if [ "$LX_ROUTE" = 1 ]; then
    act_fact network.connect now "Now" "a default route, but github.com cannot be reached" warn || return 1
  else
    act_fact network.connect now "Now" "no default route" warn || return 1
  fi
  if sys_has nmtui; then
    act_fact network.connect runs "Runs" "nmtui on this terminal: Activate a connection, your network, then Quit" || return 1
  else
    act_fact network.connect runs "Runs" "nothing: connect with nmcli device wifi connect <SSID> --ask on this terminal, then press Enter" || return 1
  fi
}

act_network_params() { :; }
act_network_basis() { return 1; }

act_network_run() {
  lx_begin "" || return 1
  lx_root_ok || return 1
  lx_connect
}

# Route and reachability, as lx_online reads them: online is the effect;
# still offline is the state the step began from, which it did not change.
act_network_judge() {
  ACT_READ=""
  lx_detect
  LX_ONLINE=0
  if sys_reachable github "https://github.com"; then LX_ONLINE=1; fi
  if [ "$LX_ROUTE" = 1 ] && [ "$LX_ONLINE" = 1 ]; then
    act_judged completed "Online: a default route, and github.com can be reached."
  else
    act_judged no-effect "Still offline, as before."
  fi
}

# ---------------------------------------------------------------------------
# omarchy.start — handoff, scope omarchy, word start
# ---------------------------------------------------------------------------

act_start_offer() {
  act_lx_read
  act_lx_online
  if [ -n "$(lx_blockers)" ]; then
    CA_WHY="This machine cannot continue."
    return 1
  fi
  case "$LX_OMARCHY_STATE" in
    absent | partial) ;;
    *)
      CA_WHY="Omarchy is $LX_OMARCHY_STATE here."
      return 1
      ;;
  esac
  if [ "$OMB_UID" != 0 ] && [ "$OMB_DRY_RUN" != 1 ]; then
    CA_WHY="omarchy-mac-setup must run as root."
    return 1
  fi
  if [ "$LX_ROUTE" != 1 ] || [ "$LX_ONLINE" != 1 ]; then
    CA_WHY="This machine is offline: connect first."
    return 1
  fi
  return 0
}

act_start_facts() {
  local enc=no
  act_fact omarchy.start runs "Runs" "omarchy-mac-setup from $OMARCHY_MAC_REPO ($OMARCHY_MAC_BRANCH), downloaded and checked first" || return 1
  if [ -n "${CFG_enc:-}" ] && [ -n "${CFG_user:-}" ] && [ -n "${CFG_host:-}" ] && [ -n "${CFG_kmap:-}" ]; then
    [ "$CFG_enc" = 1 ] && enc=yes
    act_fact omarchy.start choices "Choices" "encryption $enc, user $CFG_user, host $CFG_host, keymap $CFG_kmap; confirmed on this terminal" || return 1
  else
    act_fact omarchy.start choices "Choices" "asked on this terminal before anything runs" || return 1
  fi
  if [ "$LX_OMARCHY_STATE" = partial ]; then
    act_fact omarchy.start now "Now" "Omarchy's package is present but its install did not finish; the setup redoes only what is unfinished" warn || return 1
  fi
  act_fact omarchy.start does "Does" "sets the keymap, hostname and user, then (with encryption) moves /boot to EFI and encrypts the Linux root in place, then installs Omarchy, rebooting between steps" || return 1
  act_fact omarchy.start leaves "Leaves" "macOS, untouched" || return 1
  act_console_fact
}

# act_console_fact — the console Omarchy Mac's setup writes to, as a fact.
act_console_fact() {
  rec_line fact scope omarchy key omarchy.console label "Console" value "$OMARCHY_SETUP_TTY (Ctrl+Alt+F${OMARCHY_SETUP_TTY#tty})" state info
}

act_start_params() { :; }
act_start_basis() { return 1; }

act_start_run() {
  ACT_PRE=$(state_get omarchy_launched_at)
  ACT_SEEN=""
  lx_begin "" || return 1
  ACT_SEEN=$(act_lx_seen)
  case "$LX_OMARCHY_STATE" in
    absent | partial) ;;
    *)
      ui_fail "Omarchy is $LX_OMARCHY_STATE here; there is nothing to start."
      return 1
      ;;
  esac
  lx_install
}

# Omarchy's own classification on a fresh read: its setup under way or done
# is the effect; a setup never launched, or launched and leaving everything
# the classifier reads as it was (it was answered no at its first question),
# changed nothing.
act_start_judge() {
  ACT_READ=""
  lx_detect
  case "$LX_OMARCHY_STATE" in
    installed | in-progress)
      act_judged completed "omarchy-mac-setup is $LX_OMARCHY_STATE."
      return 0
      ;;
  esac
  if [ "$1" != reconcile ]; then
    if [ "$(state_get omarchy_launched_at)" = "${ACT_PRE:-}" ]; then
      act_judged no-effect "omarchy-mac-setup was not started; nothing changed."
      return 0
    fi
    if [ -n "$ACT_SEEN" ] && [ "$(act_lx_seen)" = "$ACT_SEEN" ]; then
      act_judged no-effect "omarchy-mac-setup ended, and this machine reads exactly as before it ran."
      return 0
    fi
  fi
  act_judged unexpected "Omarchy is $LX_OMARCHY_STATE after omarchy-mac-setup ran."
}

# ---------------------------------------------------------------------------
# omarchy.resume — handoff, scope omarchy, word resume
# ---------------------------------------------------------------------------

act_resume_offer() {
  act_lx_read
  if [ -n "$(lx_blockers)" ]; then
    CA_WHY="This machine cannot continue."
    return 1
  fi
  if [ "$LX_OMARCHY_STATE" != in-progress ]; then
    CA_WHY="omarchy-mac-setup is not part-way through ($LX_OMARCHY_STATE)."
    return 1
  fi
  case "$LX_UNIT_STATE" in
    active | activating)
      CA_WHY="omarchy-mac-setup is running now on $OMARCHY_SETUP_TTY."
      return 1
      ;;
  esac
  if [ "$OMB_UID" != 0 ] && [ "$OMB_DRY_RUN" != 1 ]; then
    CA_WHY="omarchy-mac-setup --resume must run as root."
    return 1
  fi
  return 0
}

act_resume_facts() {
  local line n=0 setup=absent
  act_fact omarchy.resume runs "Runs" "$OMS_SELF --resume, on this terminal" || return 1
  act_fact omarchy.resume now "Now" "omarchy-mac-setup is part-way through ($OMS_CONF is present) and not running" || return 1
  act_fact omarchy.resume does "Does" "continues from where this machine is; it may reboot, and resumes on its own after each boot" || return 1
  # Where the setup stands, as the classifier reads it (Omarchy's progress).
  [ "$LX_SETUP_CONF" = 1 ] && setup="part-way through ($OMS_CONF)"
  rec_line fact scope omarchy key omarchy.state label "Omarchy" value "$LX_OMARCHY_STATE" state info || return 1
  rec_line fact scope omarchy key omarchy.setup label "Setup" value "$setup" state info || return 1
  rec_line fact scope omarchy key omarchy.service label "Setup service" value "${LX_UNIT_STATE:-unknown}" state info || return 1
  rec_line fact scope omarchy key omarchy.encryption label "Encryption" value "$LX_ENC_STATE" state info || return 1
  rec_line fact scope omarchy key omarchy.boot label "/boot" value "${LX_BOOT_SRC:-on the root filesystem}${LX_BOOT_FS:+ ($LX_BOOT_FS)}" state info || return 1
  rec_line fact scope omarchy key omarchy.version label "Omarchy version" value "${LX_OMARCHY_VERSION:-not installed yet}" state info || return 1
  act_console_fact || return 1
  # Upstream's own status, which only root can read (lx_upstream_status).
  if [ "$LX_SETUP_BIN" = 1 ] && [ "$OMB_UID" = 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1))
      rec_line fact scope omarchy key "omarchy.upstream.$n" label "Upstream" value "$line" state info || return 1
    done <<EOF
$(lx_upstream_status_text)
EOF
  fi
}

act_resume_params() { :; }
act_resume_basis() { return 1; }

act_resume_run() {
  lx_begin "" || return 1
  if [ "$LX_OMARCHY_STATE" != in-progress ]; then
    ui_fail "omarchy-mac-setup is not part-way through ($LX_OMARCHY_STATE); there is nothing to resume."
    return 1
  fi
  lx_in_progress
}

# Only installed proves completion. Only this run's own failure to execute
# (status 126 or 127), with the executable cleanly absent or not an
# executable file on a fresh read, proves no effect. A reconcile after a new
# boot has no status of the run it can trust: there only installed settles.
act_resume_judge() {
  local rc=$1 f st
  ACT_READ=""
  lx_detect
  if [ "$LX_OMARCHY_STATE" = installed ]; then
    act_judged completed "omarchy-mac-setup has finished: Omarchy is installed."
    return 0
  fi
  case "$rc" in
    126 | 127)
      f=$(sys_path "$OMS_SELF")
      # One stat, following a link as exec does: 1 cleanly absent (ENOENT),
      # 2 there but not an executable regular file, 0 executable, 3 the
      # lookup itself failed. Only 1 and 2 show the command could not run.
      # shellcheck disable=SC2016 # Perl source: perl expands its own variables
      LC_ALL=C perl -e 'my @s = stat($ARGV[0]); exit($!{ENOENT} ? 1 : 3) unless @s; exit((-f _ && ($s[2] & 0111)) ? 0 : 2)' -- "$f"
      st=$?
      case "$st" in
        1 | 2)
          act_judged no-effect "omarchy-mac-setup could not be executed; $OMS_SELF is missing or not executable."
          return 0
          ;;
      esac
      ;;
  esac
  act_judged unexpected "The resume ended and Omarchy Mac setup is not yet installed. Setup resumes by itself on the console after a restart; this tool's resume is held until then. Upstream's own command is: sudo $OMS_SELF --resume"
}

# ---------------------------------------------------------------------------
# shared.activate — handoff, scope shared, word mount
# ---------------------------------------------------------------------------

act_activate_offer() {
  local f
  act_lx_read
  if ! shared_lx_begin >/dev/null 2>&1; then
    CA_WHY="Shared is set up as the everyday user, not as root."
    return 1
  fi
  if [ "$SHARED_STATE" != awaiting-linux-activation ] || [ "$SH_NEED_CODE" != 0 ]; then
    CA_WHY="Shared storage is not ready to mount here (${SHARED_STATE})."
    return 1
  fi
  f=$(sys_path "$SHARED_MNT")
  if [ -e "$f" ] && ! grep -q " $SHARED_MNT " "$(sys_path /proc/self/mounts)" 2>/dev/null && [ -n "$(ls -A "$f" 2>/dev/null)" ]; then
    CA_WHY="$SHARED_MNT already holds files; mounting over them would hide them."
    return 1
  fi
  return 0
}

act_activate_facts() {
  act_fact shared.activate partition "Partition" "/dev/$SH_NAME, $(fmt_gb "$SH_SIZE") exFAT${SH_LABEL:+, named $SH_LABEL}, PARTUUID=$SH_PARTUUID" || return 1
  act_fact shared.activate where "Mounts at" "$SHARED_MNT, on first use; boot does not wait for it" || return 1
  act_fact shared.activate owner "Owner" "${LX_USER:-you} (uid $SH_UID, gid $SH_GID); nodev, nosuid, noexec" || return 1
  act_fact shared.activate adds "Adds to /etc/fstab" "$(shared_fstab_line)" || return 1
  act_fact shared.activate keeps "Keeps" "every other line of /etc/fstab; the previous file is kept as /etc/fstab.omarchy-bootstrap.bak" || return 1
}

act_activate_params() { :; }
act_activate_basis() { return 1; }

act_activate_run() {
  LX_ARCH=""
  shared_activate ""
  ACT_RC=$?
  act_took
  return "$ACT_RC"
}

# The mount's configuration on a fresh read: ready is the effect; a step that
# stopped before its word changed nothing.
act_activate_judge() {
  act_lx_read again
  shared_lx_begin >/dev/null 2>&1
  if [ "$SHARED_STATE" = ready ]; then
    act_judged completed "Shared storage mounts at $SHARED_MNT on every boot."
  elif [ "$1" != reconcile ] && [ "${ACT_TOOK:-1}" = 0 ]; then
    act_judged no-effect "The step stopped before its word: nothing changed."
  elif [ "$SHARED_STATE" = awaiting-linux-activation ]; then
    act_judged absent "Shared is not set to mount at $SHARED_MNT."
  else
    act_judged unexpected "Shared storage is $SHARED_STATE: $SHARED_WHY."
  fi
}

# ---------------------------------------------------------------------------
# shared.test — handoff, scope shared, word test
# ---------------------------------------------------------------------------

act_test_offer() {
  act_lx_read
  shared_lx_state
  if [ "$SHARED_STATE" != ready ]; then
    CA_WHY="Shared storage is not ready on this system (${SHARED_STATE})."
    return 1
  fi
  return 0
}

act_test_facts() {
  act_fact shared.test where "Where" "$SHARED_MNT, /dev/$SH_NAME" || return 1
  act_fact shared.test does "Does" "writes one temporary file, flushes it, reads it back, compares it and removes that file only" || return 1
}

act_test_params() { :; }
act_test_basis() { return 1; }

act_test_run() {
  shared_test
  ACT_RC=$?
  act_took
  return "$ACT_RC"
}

# act_test_left — a test file left on Shared.
act_test_left() {
  local f
  for f in "$(sys_path "$SHARED_MNT")"/.omarchy-bootstrap-test-*; do
    if [ -e "$f" ] || [ -L "$f" ]; then return 0; fi
  done
  return 1
}

# The write test's own result, and nothing of it left on Shared.
act_test_judge() {
  if act_test_left; then
    act_judged unexpected "A test file is still on Shared, at $SHARED_MNT."
  elif [ "$1" = reconcile ]; then
    act_judged no-effect "Nothing of the write test is left on Shared."
  elif [ "$1" = 0 ]; then
    act_judged completed "Shared storage is writable: written, flushed, read back identical and removed."
  elif [ "${ACT_TOOK:-1}" = 0 ]; then
    act_judged no-effect "The test stopped before its word: nothing was written."
  else
    act_judged absent "The write test did not pass; nothing of it is left on Shared."
  fi
}

# ---------------------------------------------------------------------------
# dev — handoff, scope $ACT_DEV_SCOPE, no word (its first prompt is a choice)
# ---------------------------------------------------------------------------

act_dev_offer() {
  act_lx_read
  if [ "$LX_OMARCHY_STATE" != installed ]; then
    CA_WHY="Omarchy is not installed yet; the developer setup builds on its commands."
    return 1
  fi
  if [ "$OMB_UID" = 0 ] && [ "$OMB_DRY_RUN" != 1 ]; then
    CA_WHY="The developer setup runs as the everyday user."
    return 1
  fi
  return 0
}

act_dev_facts() {
  local m parts=""
  for m in $DEV_MODULES; do parts="$parts${parts:+, }$(dev_label "$m")"; done
  act_fact dev parts "Parts" "$parts" || return 1
  act_fact dev how "How" "chosen on this terminal; each part runs Omarchy's own helpers, and sudo where it is needed" || return 1
}

act_dev_params() { :; }
act_dev_basis() { return 1; }

act_dev_run() {
  ACT_PRE=$(state_get dev_last_run_at)
  LX_ARCH=""
  dev_main
}

# The developer outcomes, as dev_main records them: every chosen part
# succeeded; nothing chosen; or a failure recorded. After a new boot only a
# success recorded at or after the moment this operation began (CO_AT, the
# record's first write; both to the second) counts: an earlier run's
# success says nothing about the run that was interrupted.
act_dev_judge() {
  local LC_ALL=C last
  last=$(state_get dev_last_run_at)
  if [ -n "$(state_get dev_failed)" ]; then
    act_judged unexpected "Developer setup parts failed: $(state_get dev_failed)."
  elif [ "$1" != reconcile ] && [ "$last" = "${ACT_PRE:-}" ]; then
    act_judged no-effect "Nothing was chosen; nothing changed."
  elif [ "$1" = reconcile ] && { [ -z "${CO_AT:-}" ] || [ -z "$last" ] || [[ $last < $CO_AT ]]; }; then
    act_judged unexpected "No developer setup outcome is recorded since this run began${last:+ (the last success, at $last, belongs to an earlier run)}."
  elif [ -n "$last" ]; then
    act_judged completed "The developer setup finished: $(state_get dev_modules)."
  else
    act_judged unexpected "The developer setup recorded no outcome."
  fi
}

# ---------------------------------------------------------------------------
# validate select action=shared.code (the core's ${CA_FN}_validate hook)
# ---------------------------------------------------------------------------

# act_code_validate — the code judged as the text flow judges it, on the
# offer's fresh read: normal and review, or one invalid record. Nothing is
# saved.
act_code_validate() {
  local i=0 n
  VAL_ANSWERS='' VAL_WARNING='' VAL_LINUX='' VAL_SHARED='' VAL_CHOICES='' VAL_INVALID='' VAL_REVIEW='' VAL_MESSAGES=''
  if ! command -v core_read_prefix >/dev/null 2>&1; then
    # shellcheck source=lib/read.sh
    . "$OMB_HOME/lib/read.sh" || _omb_unloaded read
  fi
  omb_tmp_init || { core_validate_error io; return; }
  while [ "$i" -lt "$CORE_REQ_ARGS" ]; do
    n=${CORE_REQ_ARG_NAME[i]}
    if [ "$n" != code ]; then
      rec_line_v invalid name "$n" code unknown-parameter text 'This parameter is not accepted by this action.'
      VAL_INVALID="$REC_LINE
"
      core_validate_respond refused invalid
      return
    fi
    i=$((i + 1))
  done
  if ! act_row shared.code || ! core_in_scopes "$CA_SCOPE"; then
    core_result refused unavailable "Shared codes are entered on macOS and Linux."
    return
  fi
  if ! act_code_offer; then
    core_result refused unavailable "$CA_WHY"
    return
  fi
  if ! core_arg_into code ACT_ARG; then
    rec_line_v invalid name code code required text 'The code is required.'
    VAL_INVALID="$REC_LINE
"
    core_validate_respond refused invalid
    return
  fi
  if ! act_code_check "$ACT_ARG"; then
    rec_line_v invalid name code code "$SHARED_CODE_ERR" text "$SHARED_CODE_WHY"
    VAL_INVALID="$REC_LINE
"
    core_validate_respond refused invalid
    return
  fi
  act_code_basis || { core_validate_error io; return; }
  rec_line_v normal name code value "$ACT_CODE"
  VAL_CHOICES="$REC_LINE
"
  rec_line_v review action shared.code basis "$CORE_BASIS"
  VAL_REVIEW="$REC_LINE
"
  core_validate_respond "done" ok
}
