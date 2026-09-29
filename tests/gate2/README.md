# Journey read producer evidence

`linux-alarm-fresh.snapshot` pins the snapshot body (without transport hello,
generation or final result). `test-gate2-journey.sh` compares the semantic
status surface to the independently extracted accepted baseline `2edb76a`.

`lib/read.sh` calls `cmd_status` with structured sinks in a subshell. It
collects the same label/value/note arguments that the text interface renders;
it does not parse bootstrap output. `status_token` retains `mac_status`'s
condition and `token_encode`; `lx_upstream_status_text` supplies the existing
sanitized upstream payload before indentation. No Doctor producer is called.

The settled identity vocabulary is:

| Key | Label | Owner/value |
| --- | --- | --- |
| `machine.platform` | Platform | `platform_init`: `OMB_PLATFORM` |
| `machine.arch` | Architecture | `mac_detect`: `MAC_ARCH`; `lx_detect`: `LX_ARCH` |
| `machine.model` | Model | `MAC_MODEL_ID`; `LX_DT_MODEL` |
| `machine.chip` | Chip | `MAC_CHIP`; Linux device table's `DEV_CHIP` |
| `machine.memory` | Memory | macOS `MAC_MEM_BYTES`, bytes; no Linux memory probe |
| `machine.os` | macOS / System | `MAC_OS_VERSION`; `LX_OS_NAME` |
| `machine.kernel` | Kernel | Linux `LX_KERNEL` |

Identity facts are `info`, or `unknown` for an empty, `unknown`, or `?` value.
An absent identity value is displayed as `unknown` with state `unknown`:
Protocol 1 requires a nonempty fact value. Status rows retain the original
empty value, while their snapshot fact uses the same explicit unknown marker.
They make no health claim. Each machine detail row uses its fact key and the
same label and value. Status facts use `status.N`, or `recorded.N` under a
Recorded section, where N is the corresponding status-row position. Their
state follows the same conservative rule; note text stays in status rows.

Status rows retain section, label, value and note in the owner's order.
Section headers have empty label/value and retain the section annotation in
note, including the identity of a recorded state file. Prose has an empty
label; it is a snapshot message rather than a fact with an invalid empty
label. Next is the snapshot guide, and the resume token is the snapshot code;
neither is duplicated as a status row.

The canonical dataset starts with `scope name=journey`, then the snapshot
body in schema order, then all status rows followed by all machine rows in
producer order. SHA-256 covers these canonical record bytes joined by LF,
with no trailing LF. It includes both projections, section annotations, notes,
and the conditional token. Snapshot total is zero. Frontend-check uses none
of this producer or generation logic.
