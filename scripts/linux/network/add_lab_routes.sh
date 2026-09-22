#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the Ubuntu node whose routes are being changed. Route data comes from
# a separate YAML file; this script owns only its generated Netplan fragment.

script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
config="$repo_root/specs/linux/network/lab_routes.yaml"
mode=dry-run
output=yaml
temp_dir=""

usage() {
    cat <<'HELP'
Usage: add_lab_routes.sh [--config FILE] [--dry-run | --apply] [--yaml | --json] [--help]

Audience: human and agent. Run this script on the target Ubuntu node.
Routes, gateway, interface, expected node address, and managed Netplan path
come from FILE (default: specs/linux/network/lab_routes.yaml in Chain).

--dry-run  Default. Validate the YAML and render the exact Netplan fragment;
           change no live network state.
--apply    Require root, check node identity and next hop, install the managed
           fragment, apply Netplan, and verify routes and the default gateway.
--yaml     Emit the rendered Netplan YAML on a dry run (default).
--json     Emit one JSON result object. Requires jq.
--help     Show this help.

Run --apply from a console/IPMI session: Netplan may briefly interrupt SSH.
The script does not change DNS, the default route, or reboot the node.
Re-running with the same YAML is a no-op when the live routes still match.
HELP
}

die() {
    printf 'BLOCKER: %s\nSAFE_NEXT_STEP: %s\n' "$1" "$2" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command '$1' is unavailable" "Install $1 on the target, then retry the dry run."
}

valid_ipv4() {
    local address="$1" octet
    local -a octets
    [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a octets <<<"$address"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

valid_network() {
    local route="$1" address prefix octet value=0 mask
    local -a octets
    [[ "$route" == */* ]] || return 1
    address="${route%/*}"
    prefix="${route#*/}"
    valid_ipv4 "$address" || return 1
    [[ "$prefix" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 1
    IFS=. read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        value=$(( (value << 8) | 10#$octet ))
    done
    mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    (( (value & mask) == value ))
}

parse_config() {
    local line route existing line_number=0 in_routes=false
    local version=""
    interface=""
    expected_address=""
    gateway=""
    netplan_file=""
    routes=()

    [[ -f "$config" ]] || die "route YAML not found: $config" \
        "Pass --config FILE or place the route spec under specs/linux/network/."
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        case "$line" in
            'version: '*)
                [[ -z "$version" && "$in_routes" == false ]] || die "duplicate or misplaced version at line $line_number" "Keep one version field before routes:."
                version="${line#version: }"
                ;;
            'interface: '*)
                [[ -z "$interface" && "$in_routes" == false ]] || die "duplicate or misplaced interface at line $line_number" "Keep one interface field before routes:."
                interface="${line#interface: }"
                ;;
            'expected_address: '*)
                [[ -z "$expected_address" && "$in_routes" == false ]] || die "duplicate or misplaced expected_address at line $line_number" "Keep one expected_address field before routes:."
                expected_address="${line#expected_address: }"
                ;;
            'gateway: '*)
                [[ -z "$gateway" && "$in_routes" == false ]] || die "duplicate or misplaced gateway at line $line_number" "Keep one gateway field before routes:."
                gateway="${line#gateway: }"
                ;;
            'netplan_file: '*)
                [[ -z "$netplan_file" && "$in_routes" == false ]] || die "duplicate or misplaced netplan_file at line $line_number" "Keep one netplan_file field before routes:."
                netplan_file="${line#netplan_file: }"
                ;;
            'routes:')
                [[ "$in_routes" == false ]] || die "duplicate routes field at line $line_number" "Keep one routes: list."
                in_routes=true
                ;;
            '  - '*)
                [[ "$in_routes" == true ]] || die "route before routes: at line $line_number" "Move route entries below routes:."
                route="${line#  - }"
                valid_network "$route" || die "invalid network '$route' at line $line_number" "Use a canonical IPv4 CIDR such as 10.12.2.0/24."
                for existing in "${routes[@]}"; do
                    if [[ "$existing" == "$route" ]]; then
                        continue 2
                    fi
                done
                routes+=("$route")
                ;;
            *)
                die "unsupported YAML at line $line_number" \
                    "Use the layout shown in specs/linux/network/lab_routes.example.yaml."
                ;;
        esac
    done <"$config"

    [[ "$version" == 1 ]] || die "route YAML version must be 1" "Set 'version: 1'."
    [[ "$interface" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid interface '$interface'" "Set interface to the target's actual NIC name."
    valid_ipv4 "$expected_address" || die "invalid expected_address '$expected_address'" "Set it to the target node's IPv4 address."
    valid_ipv4 "$gateway" || die "invalid gateway '$gateway'" "Set it to the VPN router's IPv4 address."
    [[ "$gateway" != "$expected_address" ]] || die "gateway equals target address" "Use the VPN router, not the node itself."
    [[ "$netplan_file" =~ ^/etc/netplan/[A-Za-z0-9_.-]+\.yaml$ ]] ||
        die "invalid managed Netplan path '$netplan_file'" "Choose a .yaml file directly under /etc/netplan."
    (( ${#routes[@]} > 0 )) || die "route list is empty" "Add at least one IPv4 CIDR under routes:."
}

render_fragment() {
    local route
    printf '# Managed by add_lab_routes.sh; edit lab_routes.yaml and re-run.\n'
    printf 'network:\n  version: 2\n  ethernets:\n    %s:\n      routes:\n' "$interface"
    for route in "${routes[@]}"; do
        printf '        - to: %s\n          via: %s\n' "$route" "$gateway"
    done
}

verify_routes() {
    local route found
    for route in "${routes[@]}"; do
        found="$(ip -4 route show exact "$route")"
        [[ " $found " == *" via $gateway dev $interface "* ]] || return 1
    done
}

emit_json() {
    local state="$1" routes_json
    need jq
    routes_json="$(printf '%s\n' "${routes[@]}" | jq -R . | jq -s .)"
    jq -n \
        --arg state "$state" \
        --arg interface "$interface" \
        --arg expectedAddress "$expected_address" \
        --arg gateway "$gateway" \
        --arg netplanFile "$netplan_file" \
        --argjson routes "$routes_json" \
        '{schemaVersion: 1, state: $state, interface: $interface,
          expectedAddress: $expectedAddress, gateway: $gateway,
          netplanFile: $netplanFile, routes: $routes}'
}

restore_previous() {
    local previous="$1" had_previous="$2"
    if [[ "$had_previous" == true ]]; then
        install -m 0600 "$previous" "$netplan_file"
    else
        rm -f -- "$netplan_file"
    fi
    netplan generate >&2 || true
    netplan apply >&2 || true
}

apply_routes() {
    local current_address gateway_route old_default new_default had_previous=false
    [[ "$(id -u)" -eq 0 ]] || die "--apply requires root" "Run sudo -v interactively, then sudo ./add_lab_routes.sh --apply from the console."
    ip link show dev "$interface" >/dev/null 2>&1 ||
        die "interface '$interface' is absent" "Check the NIC name with 'ip -br link' and update the YAML."
    current_address="$(ip -4 -o address show dev "$interface")"
    [[ " $current_address " == *" $expected_address/"* ]] ||
        die "target address $expected_address is not on $interface" "Run this script on the intended node or update expected_address."
    gateway_route="$(ip -4 route get "$gateway")"
    [[ " $gateway_route " == *" dev $interface "* && " $gateway_route " != *" via "* ]] ||
        die "gateway $gateway is not directly reachable on $interface" "Inspect 'ip -4 route get $gateway' before applying."
    if [[ -L "$netplan_file" ]]; then
        die "managed Netplan path is a symlink" "Choose a regular, dedicated file under /etc/netplan."
    fi
    if [[ -e "$netplan_file" ]] && ! grep -Fxq '# Managed by add_lab_routes.sh; edit lab_routes.yaml and re-run.' "$netplan_file"; then
        die "Netplan path already contains unmanaged content" "Choose another netplan_file; this script will not overwrite it."
    fi

    old_default="$(ip -4 route show default)"
    [[ -n "$old_default" ]] || die "no current IPv4 default route" "Restore or inspect the default gateway before applying VPN routes."
    if [[ -e "$netplan_file" ]] && cmp -s "$fragment" "$netplan_file" && verify_routes; then
        if [[ "$output" == json ]]; then emit_json no-op; else printf 'NO-OP: routes already match YAML.\n'; fi
        return 0
    fi

    if [[ -e "$netplan_file" ]]; then
        cp -p "$netplan_file" "$temp_dir/previous.yaml"
        had_previous=true
    fi
    install -m 0600 "$fragment" "$netplan_file"
    if ! netplan generate >&2; then
        restore_previous "$temp_dir/previous.yaml" "$had_previous"
        die "netplan generate rejected the installed fragment; previous state restored" "Inspect the Netplan diagnostics and YAML before retrying."
    fi
    if ! netplan apply >&2; then
        restore_previous "$temp_dir/previous.yaml" "$had_previous"
        die "netplan apply failed; previous state restored" "Use the console to inspect networkd and Netplan before retrying."
    fi
    new_default="$(ip -4 route show default)"
    if [[ "$new_default" != "$old_default" ]] || ! verify_routes; then
        restore_previous "$temp_dir/previous.yaml" "$had_previous"
        die "route or default-gateway read-back failed; previous state restored" "Check 'ip -4 route' and the VPN gateway from the console."
    fi
    if [[ "$output" == json ]]; then emit_json applied; else printf 'APPLIED: %s routes via %s; default route unchanged.\n' "${#routes[@]}" "$gateway"; fi
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --config)
                (( $# >= 2 )) || die "--config needs a path" "Pass --config FILE."
                config="$2"
                shift 2
                ;;
            --dry-run) mode=dry-run; shift ;;
            --apply) mode=apply; shift ;;
            --yaml) output=yaml; shift ;;
            --json) output=json; shift ;;
            --help|-h) usage; return 0 ;;
            *) die "unknown option '$1'" "Run --help for supported options." ;;
        esac
    done
    need bash
    need netplan
    need ip
    parse_config

    temp_dir="$(mktemp -d)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    mkdir -p "$temp_dir/etc/netplan"
    fragment="$temp_dir/etc/netplan/$(basename "$netplan_file")"
    render_fragment >"$fragment"
    chmod 0600 "$fragment"
    if ! netplan generate --root-dir "$temp_dir" >"$temp_dir/netplan-check.log" 2>&1; then
        sed -n '1,60p' "$temp_dir/netplan-check.log" >&2
        die "Netplan rejected the rendered route fragment" \
            "Correct the route spec and rerun --dry-run."
    fi

    if [[ "$mode" == dry-run ]]; then
        printf 'DRY-RUN: no network or DNS changes made.\n' >&2
        if [[ "$output" == json ]]; then emit_json planned; else cat "$fragment"; fi
        return 0
    fi
    apply_routes
}

main "$@"
