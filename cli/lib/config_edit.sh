#!/usr/bin/env bash
# cli/lib/config_edit.sh -- surgical, comment-preserving write engine for the
# host-side config verbs (ADR-021 D8, rip-cage-tsf2.10.4).
# NOTE: sourced by the rc shim; must NOT set -euo pipefail (shim owns strict mode once).
#
# The verbs (`rc config set/add/remove`, and `rc allowlist add` sugar) route
# through _config_edit_apply. The engine performs SURGICAL textual line edits:
# `yq` READS locate the key/anchor line and current shape; a minimal splice
# (single value token, one inserted `- item` line, one deleted line, or the
# single defined `[]`-to-block transform) rewrites the file INTO A NEW TEMP
# FILE (the original is never mutated in place); then the edit is verified in
# three gates -- (1) the result parses as clean YAML, (2) a targeted read-back
# confirms the intended change actually landed (and nothing else moved), (3)
# the FULL loader parse re-validates the whole layer -- and only on all-three
# pass is the temp file atomically renamed over the target (same directory,
# same filesystem, mode preserved). ANY gate failure discards the temp file
# and refuses with "edit the file"; the original is never touched, so there is
# nothing to restore.
#
# yq re-emit (yq expr > tmp; cp) is FORBIDDEN as a write path (ADR-021 D8):
# it drops blank lines, normalizes comment spacing, and relocates free-standing
# comments -- the live config files carry load-bearing comment prose. Every
# write below is a line-addressed awk splice of the ORIGINAL bytes.
#
# Deliberately narrow surface (D8): add/remove a scalar-list entry; set a
# scalar/enum. Anything structural (nested-map creation in an existing file,
# auth.credentials entries, tag placement, a non-empty flow-style list, a
# scalar whose current value can't be safely single-token-matched) refuses
# with "edit the file".


# _config_edit_structural_key -- returns 0 if the key is a list-of-maps / other
# structural field the verbs must not touch entry-wise (refuse "edit the file").
# Currently only auth.credentials (a list of {source_env, hosts, ...} maps).
_config_edit_structural_key() {
  case "$1" in
    auth.credentials) return 0 ;;
    *) return 1 ;;
  esac
}


# _config_edit_file_mode -- portable "read a file's permission bits" helper
# (macOS/BSD stat vs GNU stat have incompatible flag syntax). Echoes an octal
# mode string (e.g. "644") on success, empty string if neither stat variant
# works (caller treats empty as "don't bother chmod-ing, just take mktemp's
# default"). rip-cage-tsf2.10.4 review F5.
_config_edit_file_mode() {
  local f="$1" m
  if m=$(stat -f '%Lp' "$f" 2>/dev/null); then
    echo "$m"; return 0
  fi
  if m=$(stat -c '%a' "$f" 2>/dev/null); then
    echo "$m"; return 0
  fi
  echo ""
}


# _config_edit_create -- write a fresh minimal file (version: 2 + the nested key
# path) for a verb that targets an ABSENT file. No comments exist in a
# from-scratch file, so building it with printf is safe (never yq re-emit).
#   $1 dst  $2 verb (set|add)  $3 dotted key  $4 value/item
_config_edit_create() {
  local dst="$1" verb="$2" key="$3" value="$4"
  local -a parts
  IFS='.' read -ra parts <<< "$key"
  local out="version: 2"$'\n'
  local indent="" i last=$(( ${#parts[@]} - 1 ))
  for i in "${!parts[@]}"; do
    if [[ "$i" -lt "$last" ]]; then
      out+="${indent}${parts[i]}:"$'\n'
      indent+="  "
    else
      if [[ "$verb" == "set" ]]; then
        out+="${indent}${parts[i]}: ${value}"$'\n'
      else
        out+="${indent}${parts[i]}:"$'\n'
        out+="${indent}  - ${value}"$'\n'
      fi
    fi
  done
  printf '%s' "$out" > "$dst"
}


# _config_edit_set -- replace ONLY the value token on the key's line, preserving
# leading indentation and any trailing same-line `# comment`. Writes the spliced
# file to $2 (a temp path); return codes:
#   0  spliced
#   1  line not found / unexpected shape (generic "edit the file")
#   2  the CURRENT value contains a space or quote char -- a simple
#      single-token regex replace can't safely locate where the value ends
#      (rip-cage-tsf2.10.4 review F3: this used to silently truncate and
#      corrupt the line, e.g. `/has a space/path` -> `/new/clean a space/path`)
#   $1 src file  $2 dst temp  $3 dotted key  $4 new value
_config_edit_set() {
  local src="$1" dst="$2" key="$3" value="$4"
  local ln oldline
  ln=$(yq ".${key} | line" "$src" 2>/dev/null)
  [[ "$ln" =~ ^[0-9]+$ && "$ln" -gt 0 ]] || return 1

  local cur
  cur=$(yq -r ".${key}" "$src" 2>/dev/null)
  if [[ "$cur" == *' '* || "$cur" == *'"'* || "$cur" == *"'"* ]]; then
    return 2
  fi

  oldline=$(awk -v n="$ln" 'NR==n{print; exit}' "$src")
  if [[ ! "$oldline" =~ ^([[:space:]]*[^:]*:[[:space:]]*)([^[:space:]#]+)(.*)$ ]]; then
    return 1
  fi
  local newline="${BASH_REMATCH[1]}${value}${BASH_REMATCH[3]}"
  RC_EDIT_L="$newline" awk -v n="$ln" 'NR==n{print ENVIRON["RC_EDIT_L"]; next}{print}' "$src" > "$dst"
}


# _config_edit_add -- append one `- item` line to a list, preserving the tag on
# a `!replace`-tagged key and all comments. Shapes handled:
#   * inline empty `key: []`   -> the ONE defined transform: rewrite the line
#     to block form (strip ` []`, keep the trailing comment on the key line),
#     then add the item as a `- item` line at indent+2.
#   * bare `key:` (null)       -> same block-form append, no rewrite needed.
#   * existing BLOCK list      -> insert `- item` after the LAST item, at that
#     item's own indentation (the tag key line, if any, is never touched).
# Return codes:
#   0  spliced
#   1  line/shape not found (generic "edit the file")
#   2  the list is NON-EMPTY and FLOW-style (`key: [a, b]` / `key: !tag [a, b]`
#      all on one line) -- the only defined flow transform is the EMPTY-list
#      case above; a non-empty flow list is a hand edit (rip-cage-tsf2.10.4
#      review F2: block-inserting under a flow list produced invalid YAML
#      that then silently committed).
#   $1 src  $2 dst temp  $3 dotted key  $4 item
_config_edit_add() {
  local src="$1" dst="$2" key="$3" item="$4"
  local keyln len
  keyln=$(yq ".${key} | line" "$src" 2>/dev/null)
  [[ "$keyln" =~ ^[0-9]+$ && "$keyln" -gt 0 ]] || return 1
  len=$(yq ".${key} | length" "$src" 2>/dev/null)
  [[ "$len" =~ ^[0-9]+$ ]] || return 1

  if [[ "$len" -eq 0 ]]; then
    # Empty list. keyln is the key line. Do the []-to-block transform.
    local oldline indent keypart suffix
    oldline=$(awk -v n="$keyln" 'NR==n{print; exit}' "$src")
    if [[ "$oldline" =~ ^([[:space:]]*)([^:]*:)([[:space:]]*)\[\](.*)$ ]]; then
      indent="${BASH_REMATCH[1]}"; keypart="${BASH_REMATCH[2]}"; suffix="${BASH_REMATCH[4]}"
      local newkeyline="${indent}${keypart}${suffix}"
      local itemline="${indent}  - ${item}"
      RC_EDIT_K="$newkeyline" RC_EDIT_I="$itemline" \
        awk -v n="$keyln" 'NR==n{print ENVIRON["RC_EDIT_K"]; print ENVIRON["RC_EDIT_I"]; next}{print}' \
        "$src" > "$dst"
      return 0
    fi
    # Bare `key:` null (no inline []): append item at key-indent + 2.
    if [[ "$oldline" =~ ^([[:space:]]*)([^:]*:)([[:space:]]*)(#.*)?$ ]]; then
      indent="${BASH_REMATCH[1]}"
      local itemline="${indent}  - ${item}"
      RC_EDIT_I="$itemline" awk -v n="$keyln" 'NR==n{print; print ENVIRON["RC_EDIT_I"]; next}{print}' "$src" > "$dst"
      return 0
    fi
    return 1
  fi

  # Non-empty list: only a BLOCK-style list is a defined insert target. A
  # block sequence's own YAML node starts at its first item's line (there is
  # no separate node for the bare `key:` text) -- so item[0]'s line, when
  # trimmed, starts with `- ` for a genuine block list. A non-empty FLOW list
  # (`key: [a, b]` / `key: !tag [a, b]`) has item[0] on the SAME line as the
  # key/tag/brackets, so the trimmed line does NOT start with `- `.
  local item0ln item0line
  item0ln=$(yq ".${key}[0] | line" "$src" 2>/dev/null)
  [[ "$item0ln" =~ ^[0-9]+$ && "$item0ln" -gt 0 ]] || return 1
  item0line=$(awk -v n="$item0ln" 'NR==n{print; exit}' "$src")
  if [[ ! "$item0line" =~ ^[[:space:]]*-[[:space:]] ]]; then
    return 2
  fi

  # Non-empty block list: insert after the last item at its own indentation.
  local lastln lastline indent
  lastln=$(yq ".${key}[$(( len - 1 ))] | line" "$src" 2>/dev/null)
  [[ "$lastln" =~ ^[0-9]+$ && "$lastln" -gt 0 ]] || return 1
  lastline=$(awk -v n="$lastln" 'NR==n{print; exit}' "$src")
  if [[ "$lastline" =~ ^([[:space:]]*)- ]]; then
    indent="${BASH_REMATCH[1]}"
  else
    indent="    "
  fi
  local itemline="${indent}- ${item}"
  RC_EDIT_I="$itemline" awk -v n="$lastln" 'NR==n{print; print ENVIRON["RC_EDIT_I"]; next}{print}' "$src" > "$dst"
}


# _config_edit_remove -- delete exactly the `- item` line matching $4 from the
# list at key $3. Returns non-zero (⇒ caller refuses / reports not-present) if
# the item is not in that list. Matches via yq value equality (env-quoted, so
# an item with special chars can't inject into the expression), deleting the
# FIRST matching line.
#   $1 src  $2 dst temp  $3 dotted key  $4 item
_config_edit_remove() {
  local src="$1" dst="$2" key="$3" item="$4"
  local lines first
  lines=$(RC_EDIT_IT="$item" yq ".${key}[] | select(. == strenv(RC_EDIT_IT)) | line" "$src" 2>/dev/null)
  first="${lines%%$'\n'*}"
  [[ "$first" =~ ^[0-9]+$ && "$first" -gt 0 ]] || return 1
  awk -v n="$first" 'NR==n{next}{print}' "$src" > "$dst"
}


# _config_edit_verify -- the F-GATE (rip-cage-tsf2.10.4 review): a structural
# post-splice safety net that runs regardless of WHICH splicer produced $1, so
# any future splice bug fails closed instead of silently committing corrupt or
# wrong YAML. Three checks, all against the CANDIDATE file (never the real
# target -- the target is untouched until this whole function returns 0):
#   (1) the candidate parses as clean YAML (`yq '.'` exits 0)
#   (2) a targeted read-back proves the intended change landed and NOTHING
#       ELSE moved: set -> the key's value equals $value exactly; add -> the
#       list contains $value AND grew by exactly one; remove -> the list does
#       NOT contain $value AND shrank by exactly one
#   (3) the full loader parse re-validates the whole layer (existing D8 gate)
# Returns 0 iff all three pass.
#   $1 candidate file  $2 verb (set|add|remove)  $3 dotted key  $4 value/item
#   $5 pre-edit list length (ignored for set; required for add/remove)
_config_edit_verify() {
  local candidate="$1" verb="$2" key="$3" value="$4" pre_len="${5:-0}"

  # (1) clean parse.
  yq '.' "$candidate" >/dev/null 2>&1 || return 1

  # (2) targeted read-back.
  case "$verb" in
    set)
      local rv
      rv=$(yq -r ".${key}" "$candidate" 2>/dev/null)
      [[ "$rv" == "$value" ]] || return 1
      ;;
    add)
      local contains post_len
      contains=$(RC_EDIT_RV="$value" yq ".${key} // [] | contains([strenv(RC_EDIT_RV)])" "$candidate" 2>/dev/null)
      post_len=$(yq ".${key} // [] | length" "$candidate" 2>/dev/null)
      [[ "$contains" == "true" ]] || return 1
      [[ "$post_len" =~ ^[0-9]+$ ]] || return 1
      [[ "$post_len" -eq $(( pre_len + 1 )) ]] || return 1
      ;;
    remove)
      local contains post_len
      contains=$(RC_EDIT_RV="$value" yq ".${key} // [] | contains([strenv(RC_EDIT_RV)])" "$candidate" 2>/dev/null)
      post_len=$(yq ".${key} // [] | length" "$candidate" 2>/dev/null)
      [[ "$contains" == "false" ]] || return 1
      [[ "$post_len" =~ ^[0-9]+$ ]] || return 1
      [[ "$post_len" -eq $(( pre_len - 1 )) ]] || return 1
      ;;
  esac

  # (3) full loader validation.
  _config_load_layer "$candidate" >/dev/null 2>/dev/null
}


# _config_edit_apply -- the single write-path entrypoint (public; called by the
# cmd_config_* verbs AND by rc allowlist add's delegation). Enforces the D8
# verb/tag/type rules, dispatches to the shape-specific splicer, runs the
# F-GATE verification, and only then atomically commits.
#   $1 verb (set|add|remove)  $2 dotted key  $3 value/item  $4 target file
# Return codes:
#   0  success (a mutation happened and was committed)
#   1  refusal / failure (an stderr message was printed; file untouched)
#   2  idempotent no-op for `add` -- the item was already present; no stderr
#      message (the caller decides how to phrase the "no-op" success)
# Never partially applies: the target file is only ever touched by a single
# atomic rename of a fully-verified candidate built in the SAME directory
# (same filesystem) as the target, with the original file's mode preserved.
_config_edit_apply() {
  local verb="$1" key="$2" value="$3" file="$4"

  _config_check_yq

  # F1 (rip-cage-tsf2.10.4 review, CRITICAL): a value/item carrying an
  # embedded newline or carriage return could splice in fake YAML structure
  # (e.g. `add network.allowed_hosts $'z.com\nmounts:\n  config_mode: rw'`)
  # and inject an arbitrary top-level key. Refuse before ANY dispatch,
  # mutation, or file creation -- this guard covers every verb and BOTH
  # callers (rc config set/add/remove AND rc allowlist add's delegation,
  # since both route through this one function).
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "Error: value/item contains a newline or carriage return character -- refusing (this could inject arbitrary YAML structure). Please edit the file by hand: ${file}" >&2
    return 1
  fi

  # Tag placement is a hand edit — verbs never add/remove a !replace tag (D8).
  if [[ "$value" == '!'* ]]; then
    echo "Error: '${value}' looks like a YAML tag. rc config verbs never place or remove a tag (e.g. !replace) — that is a hand edit. Please edit the file: ${file}" >&2
    return 1
  fi

  # Only declared schema keys are editable.
  local type
  type=$(_config_schema_field_type "$key")
  if [[ -z "$type" ]]; then
    echo "Error: '${key}' is not a declared, leaf config key. rc config verbs only edit declared scalar/enum/list fields; anything structural is a hand edit. Please edit the file: ${file}" >&2
    return 1
  fi

  # Structural list-of-maps (auth.credentials) — entry edits are a hand edit.
  if _config_edit_structural_key "$key"; then
    echo "Error: '${key}' holds structured entries (nested maps). rc config verbs do not edit these — please edit the file: ${file}" >&2
    return 1
  fi

  case "$verb" in
    set)
      if [[ "$type" != "scalar" && "$type" != "enum" ]]; then
        echo "Error: 'set' only edits scalar/enum fields; '${key}' is a ${type}. To change a list use 'add'/'remove', or edit the file: ${file}" >&2
        return 1
      fi
      # Enum pre-validation against the static allowed set (helpful message;
      # the post-edit loader is the backstop for dynamically-derived enums).
      if [[ "$type" == "enum" ]]; then
        local allowed
        allowed=$(_config_schema_lines | awk -F'|' -v k="$key" '$1==k{print $4; exit}')
        if [[ -n "$allowed" ]]; then
          local ok=0 a
          local IFS_SAVE="$IFS"; IFS=','
          for a in $allowed; do [[ "$value" == "$a" ]] && ok=1; done
          IFS="$IFS_SAVE"
          if [[ "$ok" -eq 0 ]]; then
            echo "Error: '${value}' is not a valid value for '${key}'. Allowed: ${allowed}." >&2
            return 1
          fi
        fi
      fi
      ;;
    add|remove)
      if [[ "$type" != "list" ]]; then
        echo "Error: '${verb}' only edits list fields; '${key}' is a ${type}. Use 'set' for a scalar/enum, or edit the file: ${file}" >&2
        return 1
      fi
      # ADR-023 D2: mounts.denylist is additive-only. add is allowed (union
      # direction); remove is forbidden — never contract the secret-path
      # denylist via tooling.
      if [[ "$key" == "mounts.denylist" && "$verb" == "remove" ]]; then
        echo "Error: refusing to remove '${value}' from mounts.denylist. The secret-path denylist is additive-only (ADR-023 D2): a project may expand it but never contract or clear it via tooling. Edit the file by hand if this is truly intended: ${file}" >&2
        return 1
      fi
      ;;
    *)
      echo "Internal error: unknown config edit verb '${verb}'" >&2
      return 1
      ;;
  esac

  # F6 (rip-cage-tsf2.10.4 review, minor): `add` is idempotent, mirroring
  # rc allowlist add's pre-existing contract -- an already-present item is a
  # no-op success (return 2), never a duplicate line. Only meaningful when
  # the file already exists (an absent file trivially has nothing present).
  if [[ "$verb" == "add" && -f "$file" ]]; then
    local already
    already=$(RC_EDIT_AV="$value" yq ".${key} // [] | contains([strenv(RC_EDIT_AV)])" "$file" 2>/dev/null)
    if [[ "$already" == "true" ]]; then
      return 2
    fi
  fi

  if [[ "$verb" == "remove" && ! -f "$file" ]]; then
    echo "Error: cannot remove '${value}' from ${key} — no config file at ${file}." >&2
    return 1
  fi

  # Build the candidate in a NEW temp file, in the SAME DIRECTORY the target
  # lives (or will live) in — same filesystem, so the final commit below is a
  # true atomic rename (F5). The real target is NEVER opened for writing
  # until that single rename; there is nothing to "restore" on any failure
  # path above this point because nothing has been touched yet.
  local dir candidate created=0 pre_len=0
  dir=$(dirname "$file")
  if [[ ! -f "$file" ]]; then
    mkdir -p "$dir" 2>/dev/null || { echo "Error: cannot create config directory ${dir}." >&2; return 1; }
    candidate=$(mktemp "${dir}/.rc-edit.XXXXXX") || { echo "Error: cannot create a temp file in ${dir}." >&2; return 1; }
    _config_edit_create "$candidate" "$verb" "$key" "$value"
    created=1
  else
    candidate=$(mktemp "${dir}/.rc-edit.XXXXXX") || { echo "Error: cannot create a temp file in ${dir}." >&2; return 1; }
    if [[ "$verb" == "add" || "$verb" == "remove" ]]; then
      pre_len=$(yq ".${key} // [] | length" "$file" 2>/dev/null)
      [[ "$pre_len" =~ ^[0-9]+$ ]] || pre_len=0
    fi
    local splice_rc=0
    case "$verb" in
      set)    _config_edit_set    "$file" "$candidate" "$key" "$value" || splice_rc=$? ;;
      add)    _config_edit_add    "$file" "$candidate" "$key" "$value" || splice_rc=$? ;;
      remove) _config_edit_remove "$file" "$candidate" "$key" "$value" || splice_rc=$? ;;
    esac
    if [[ "$splice_rc" -ne 0 ]]; then
      rm -f "$candidate"
      case "$splice_rc" in
        2)
          if [[ "$verb" == "add" ]]; then
            echo "Error: '${key}' is a non-empty, flow-style list ('[...]' on one line). The only defined flow transform is an EMPTY flow list ('[]') to block form; a non-empty flow list is a hand edit. Please edit the file: ${file}" >&2
          else
            echo "Error: the current value of '${key}' contains a space or quote character — a surgical single-token replace can't safely locate where it ends. Please edit the file: ${file}" >&2
          fi
          ;;
        *)
          if [[ "$verb" == "remove" ]]; then
            echo "Error: '${value}' is not present in ${key} (nothing removed). File unchanged: ${file}" >&2
          else
            echo "Error: cannot surgically edit ${key} in ${file} (unexpected shape or absent key). Please edit the file by hand." >&2
          fi
          ;;
      esac
      return 1
    fi
  fi

  # F-GATE: parse + read-back + full-loader verification, all against the
  # CANDIDATE — the real target is still untouched.
  if ! _config_edit_verify "$candidate" "$verb" "$key" "$value" "$pre_len"; then
    rm -f "$candidate"
    echo "Error: the resulting config failed verification — nothing was changed. Please edit the file by hand: ${file}" >&2
    return 1
  fi

  # Commit: atomic same-filesystem rename, preserving the original file's
  # mode when editing an existing file (F5).
  if [[ "$created" -eq 0 ]]; then
    local mode
    mode=$(_config_edit_file_mode "$file")
    [[ -n "$mode" ]] && chmod "$mode" "$candidate" 2>/dev/null
  else
    chmod 644 "$candidate" 2>/dev/null
  fi
  mv -f "$candidate" "$file"

  return 0
}
