#!/usr/bin/env bash
#
# omarchy-vpn-nm-sync.sh
#
# Keep the atomicangel.vpn bar widget's WireGuard list in sync with
# NetworkManager. The plugin's `wireguard` list in
# ~/.config/omarchy/shell.json is static -- it is read once at load time and
# never re-scanned -- so this script rebuilds it from the WireGuard profiles
# NM knows about (`nmcli -t -f NAME,TYPE connection show`: defined profiles,
# active or not).
#
# Merge rules (the script is idempotent; run it as often as you like):
#   * an existing entry whose `connectionName` still exists in NM is kept
#     verbatim -- hand-tuned fields (color, reachabilityHost, custom
#     connectCommand/disconnectCommand) survive re-runs;
#   * an existing entry whose `connectionName` no longer exists in NM is
#     dropped;
#   * existing entries without a `connectionName` (plain wg-quick or custom
#     setups) are always left untouched;
#   * each NM WireGuard profile not yet listed gets a default entry appended:
#       { "enabled": true, "label": <name>, "interface": <name>,
#         "connectionName": <name> }
#
# Usage:
#   omarchy-vpn-nm-sync.sh              update shell.json, restart the shell
#   omarchy-vpn-nm-sync.sh --dry-run    print what would change, touch nothing
#   omarchy-vpn-nm-sync.sh --help       this text
#
# Environment:
#   OMARCHY_SHELL_JSON  override the shell.json path (defaults to
#                       ~/.config/omarchy/shell.json; handy for testing)
#
#
set -euo pipefail

SHELL_JSON="${OMARCHY_SHELL_JSON:-$HOME/.config/omarchy/shell.json}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

if [ ! -f "$SHELL_JSON" ]; then
  echo "error: $SHELL_JSON not found" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

rc=0
python3 - "$SHELL_JSON" "$TMP" "$DRY_RUN" <<'PY' || rc=$?
import json, subprocess, sys

in_path, out_path = sys.argv[1], sys.argv[2]
dry_run = sys.argv[3] == "1"

data = json.load(open(in_path))

# WireGuard profiles NM knows about (defined, active or not).
out = subprocess.check_output(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"])
conns = []
for line in out.decode().splitlines():
    if ":" not in line:
        continue
    name, typ = line.split(":", 1)
    if typ == "wireguard":
        conns.append(name)

def find_entry(obj):
    if isinstance(obj, dict):
        if obj.get("id") == "atomicangel.vpn":
            return obj
        for v in obj.values():
            r = find_entry(v)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for i in obj:
            r = find_entry(i)
            if r is not None:
                return r
    return None

entry = find_entry(data)
if entry is None:
    sys.exit("atomicangel.vpn bar entry not found in " + in_path)

wg = entry.get("wireguard")
if isinstance(wg, dict):
    wg = [wg]          # the widget also accepts a single object
elif not isinstance(wg, list):
    wg = []
wg = [e for e in wg if isinstance(e, dict)]

kept, added, dropped, custom = [], [], [], []
listed = set()
for e in wg:
    cn = e.get("connectionName")
    if not cn:
        kept.append(e); custom.append(e)   # plain wg-quick / custom: keep
    elif cn in conns:
        kept.append(e); listed.add(cn)     # still a profile: keep verbatim
    else:
        dropped.append(cn)                 # profile gone
for name in conns:
    if name not in listed:
        kept.append({"enabled": True, "label": name,
                     "interface": name, "connectionName": name})
        added.append(name)

if dry_run:
    if not added and not dropped:
        print("No changes: the wireguard list already matches NM.")
    else:
        for n in added:
            print("  + add   " + n)
        for n in dropped:
            print("  - drop  " + n + "  (no longer an NM WireGuard profile)")
        note = " ({0} without connectionName, untouched)".format(len(custom)) if custom else ""
        print("  = keep  {0} existing entries{1}".format(len(kept) - len(added), note))
    print("Dry run: " + in_path + " untouched, shell not restarted.")
    sys.exit(0)

if not added and not dropped:
    print("No changes: the wireguard list already matches NM. Shell not restarted.")
    sys.exit(3)

entry["wireguard"] = kept
json.dump(data, open(out_path, "w"), indent=2)
print("wireguard list updated: {0} entries ({1} added, {2} dropped).".format(
    len(kept), len(added), len(dropped)))
PY

if [ "$rc" -eq 3 ]; then
  exit 0
fi
[ "$rc" -eq 0 ] || exit "$rc"

# Dry run reports only; it never writes the file or restarts the shell.
if [ "$DRY_RUN" -eq 1 ]; then
  exit 0
fi

chmod --reference="$SHELL_JSON" "$TMP"
mv -f "$TMP" "$SHELL_JSON"
trap - EXIT
echo "Updated $SHELL_JSON"
omarchy restart shell
