#!/usr/bin/env bash
set -Eeuo pipefail

# Host-only split DNS for Ubuntu with Netplan and systemd-resolved.
# The private server and domain values live in a separate YAML spec.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="$script_dir/lab_dns.yaml"
mode=dry-run
format=text
temp_dir=""
installed=false
had_netplan=false
had_resolved=false
old_domains=""

usage() {
    cat <<'HELP'
Usage: add_labdns.sh [--config FILE] [--dry-run | --apply] [--json] [--help]

Audience: human and agent. Run on the target Ubuntu host. FILE is a private
YAML spec (default: lab_dns.yaml beside this script). The rule affects only
this host's systemd-resolved; it does not modify BIND or client-facing DNS.

--dry-run  Default. Validate the spec and render both managed fragments.
--apply    Install the fragments, validate Netplan, activate the DNS domains,
           restart only systemd-resolved, and verify the probe. No netplan apply.
--json     Emit one JSON result object on success; diagnostics go to stderr.
--help     Show this help.

The normal DNS link keeps its current server. A more-specific route-only
domain goes to the lab DNS server. systemd-resolved has no per-domain timeout
setting equivalent to macOS /etc/resolver's "timeout 5".
HELP
}

blocker() {
    printf 'BLOCKER: %s\nSAFE_NEXT_STEP: %s\n' "$1" "$2" >&2
    exit 3
}

need() {
    command -v "$1" >/dev/null 2>&1 ||
        blocker "required command '$1' is unavailable" "Install $1, then retry --dry-run."
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

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]
}

parse_config() {
    local line line_number=0 domain existing in_domains=false
    version=""
    interface=""
    expected_address=""
    normal_dns=""
    normal_search=""
    lab_dns=""
    lab_gateway=""
    netplan_file=""
    resolved_file=""
    probe_name=""
    domains=()

    [[ -r "$config" ]] || blocker "spec is unreadable: $config" \
        "Pass --config FILE or put lab_dns.yaml beside this script."
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        case "$line" in
            'version: '*)
                [[ -z "$version" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced version at line $line_number" "Keep one version before domains:."
                version="${line#version: }"
                ;;
            'interface: '*)
                [[ -z "$interface" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced interface at line $line_number" "Keep one interface before domains:."
                interface="${line#interface: }"
                ;;
            'expected_address: '*)
                [[ -z "$expected_address" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced expected_address at line $line_number" "Keep one address before domains:."
                expected_address="${line#expected_address: }"
                ;;
            'normal_dns: '*)
                [[ -z "$normal_dns" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced normal_dns at line $line_number" "Keep one normal DNS before domains:."
                normal_dns="${line#normal_dns: }"
                ;;
            'normal_search: '*)
                [[ -z "$normal_search" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced normal_search at line $line_number" "Keep one search domain before domains:."
                normal_search="${line#normal_search: }"
                ;;
            'lab_dns: '*)
                [[ -z "$lab_dns" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced lab_dns at line $line_number" "Keep one lab DNS before domains:."
                lab_dns="${line#lab_dns: }"
                ;;
            'lab_gateway: '*)
                [[ -z "$lab_gateway" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced lab_gateway at line $line_number" "Keep one gateway before domains:."
                lab_gateway="${line#lab_gateway: }"
                ;;
            'netplan_file: '*)
                [[ -z "$netplan_file" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced netplan_file at line $line_number" "Keep one path before domains:."
                netplan_file="${line#netplan_file: }"
                ;;
            'resolved_file: '*)
                [[ -z "$resolved_file" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced resolved_file at line $line_number" "Keep one path before domains:."
                resolved_file="${line#resolved_file: }"
                ;;
            'probe_name: '*)
                [[ -z "$probe_name" && "$in_domains" == false ]] || blocker \
                    "duplicate or misplaced probe_name at line $line_number" "Keep one probe before domains:."
                probe_name="${line#probe_name: }"
                ;;
            'domains:')
                [[ "$in_domains" == false ]] || blocker "duplicate domains at line $line_number" \
                    "Keep one domains: list."
                in_domains=true
                ;;
            '  - '*)
                [[ "$in_domains" == true ]] || blocker "domain before domains: at line $line_number" \
                    "Move it below domains:."
                domain="${line#  - }"
                valid_domain "$domain" || blocker "invalid domain at line $line_number" \
                    "Use a full DNS suffix such as example.test."
                for existing in "${domains[@]}"; do
                    [[ "$existing" != "$domain" ]] || blocker "duplicate domain '$domain'" \
                        "List each domain once."
                done
                domains+=("$domain")
                ;;
            *)
                blocker "unsupported YAML at line $line_number" \
                    "Use the simple key/value and two-space domain-list layout in lab_dns.example.yaml."
                ;;
        esac
    done <"$config"

    [[ "$version" == 1 ]] || blocker "spec version must be 1" "Set 'version: 1'."
    [[ "$interface" =~ ^[A-Za-z0-9_.-]+$ ]] || blocker "invalid interface" \
        "Use the target's actual NIC name."
    valid_ipv4 "$expected_address" || blocker "invalid expected_address" "Use a full IPv4 address."
    valid_ipv4 "$normal_dns" || blocker "invalid normal_dns" "Use a full IPv4 address."
    valid_ipv4 "$lab_dns" || blocker "invalid lab_dns" "Use a full IPv4 address."
    valid_ipv4 "$lab_gateway" || blocker "invalid lab_gateway" "Use a full IPv4 address."
    valid_domain "$normal_search" || blocker "invalid normal_search" "Use a full DNS suffix."
    valid_domain "$probe_name" || blocker "invalid probe_name" "Use a full hostname under one listed domain."
    [[ "$netplan_file" =~ ^/etc/netplan/[A-Za-z0-9_.-]+\.yaml$ ]] || blocker \
        "invalid netplan_file" "Choose a dedicated .yaml file directly under /etc/netplan."
    [[ "$resolved_file" =~ ^/etc/systemd/resolved\.conf\.d/[A-Za-z0-9_.-]+\.conf$ ]] || blocker \
        "invalid resolved_file" "Choose a .conf file under /etc/systemd/resolved.conf.d."
    (( ${#domains[@]} > 0 )) || blocker "domains list is empty" "Add at least one route-only suffix."
    local matched=false
    for domain in "${domains[@]}"; do
        if [[ "$probe_name" == *".$domain" ]]; then matched=true; fi
    done
    [[ "$matched" == true ]] || blocker "probe_name is not under a listed domain" \
        "Pick a known hostname beneath one of the domains."
}

render_netplan() {
    printf '# Managed by add_labdns.sh; edit the private YAML spec and rerun.\n'
    printf 'network:\n  version: 2\n  ethernets:\n    %s:\n' "$interface"
    printf '      nameservers:\n        search:\n          - "~."\n'
}

render_resolved() {
    local domain separator=""
    printf '# Managed by add_labdns.sh; edit the private YAML spec and rerun.\n'
    printf '[Resolve]\nDNS=%s\nDomains=' "$lab_dns"
    for domain in "${domains[@]}"; do
        printf '%s~%s' "$separator" "$domain"
        separator=" "
    done
    printf '\n'
}

emit() {
    local state="$1" domains_json
    if [[ "$format" == json ]]; then
        need jq
        domains_json="$(printf '%s\n' "${domains[@]}" | jq -R . | jq -s .)"
        jq -n \
            --arg state "$state" \
            --arg interface "$interface" \
            --arg labDns "$lab_dns" \
            --arg netplanFile "$netplan_file" \
            --arg resolvedFile "$resolved_file" \
            --argjson domains "$domains_json" \
            '{schemaVersion: 1, state: $state, interface: $interface,
              labDns: $labDns, netplanFile: $netplanFile,
              resolvedFile: $resolvedFile, domains: $domains}'
    else
        printf 'STATE: %s\n' "$state"
        if [[ "$state" == planned ]]; then
            printf '\nNETPLAN: %s\n' "$netplan_file"
            cat "$netplan_fragment"
            printf '\nRESOLVED: %s\n' "$resolved_file"
            cat "$resolved_fragment"
        fi
    fi
}

restore_previous() {
    if [[ "$had_netplan" == true ]]; then
        install -m 0600 "$temp_dir/previous-netplan" "$netplan_file" || true
    else
        rm -f -- "$netplan_file" || true
    fi
    if [[ "$had_resolved" == true ]]; then
        install -m 0644 "$temp_dir/previous-resolved" "$resolved_file" || true
    else
        rm -f -- "$resolved_file" || true
    fi
    netplan generate >/dev/null 2>&1 || true
    systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
    local -a previous_domains
    read -r -a previous_domains <<<"$old_domains"
    resolvectl domain "$interface" "${previous_domains[@]}" >/dev/null 2>&1 || true
}

on_error() {
    local line="$1"
    trap - ERR
    if [[ "$installed" == true ]]; then restore_previous; fi
    blocker "apply failed near line $line; previous managed files restored" \
        "Inspect resolver and Netplan status, then rerun --dry-run."
}

validate_host() {
    local address route current_domains
    ip link show dev "$interface" >/dev/null 2>&1 || blocker "interface is absent" \
        "Check 'ip -br link' and correct the spec."
    address="$(ip -4 -o address show dev "$interface")"
    [[ " $address " == *" $expected_address/"* ]] || blocker "unexpected node address" \
        "Run on the intended node or correct expected_address."
    route="$(ip -4 route get "$lab_dns")"
    [[ " $route " == *" via $lab_gateway dev $interface "* ]] || blocker \
        "lab DNS route does not use the expected VPN gateway" \
        "Restore the lab route first; do not change DNS yet."
    resolvectl dns "$interface" | grep -Fq "$normal_dns" || blocker \
        "normal DNS differs from spec" "Check 'resolvectl dns $interface' and update the spec."
    current_domains="$(resolvectl domain "$interface")"
    current_domains="${current_domains#*: }"
    [[ "$current_domains" == "$normal_search" || "$current_domains" == "$normal_search ~." ]] || blocker \
        "existing search domains differ from spec" "Check 'resolvectl domain $interface' and update the spec."
    old_domains="$current_domains"
    [[ ! -L "$netplan_file" && ! -L "$resolved_file" ]] || blocker \
        "a managed target is a symlink" "Inspect both target paths before applying."
    local marker='# Managed by add_labdns.sh; edit the private YAML spec and rerun.'
    if [[ -e "$netplan_file" ]] && ! grep -Fxq "$marker" "$netplan_file"; then
        blocker "Netplan target contains unmanaged content" "Choose a dedicated netplan_file."
    fi
    if [[ -e "$resolved_file" ]] && ! grep -Fxq "$marker" "$resolved_file"; then
        blocker "resolved target contains unmanaged content" "Choose a dedicated resolved_file."
    fi
}

validate_netplan_merge() {
    local source generated
    mkdir -p "$temp_dir/fixture/etc/netplan"
    for source in /etc/netplan/*.yaml; do
        [[ -f "$source" ]] || continue
        cp -p "$source" "$temp_dir/fixture/etc/netplan/"
    done
    install -m 0600 "$netplan_fragment" \
        "$temp_dir/fixture/etc/netplan/$(basename "$netplan_file")"
    netplan generate --root-dir "$temp_dir/fixture" >"$temp_dir/netplan.log" 2>&1 || {
        sed -n '1,40p' "$temp_dir/netplan.log" >&2
        blocker "Netplan rejected the merged DNS fragment" "Correct the spec before applying."
    }
    generated="$temp_dir/fixture/run/systemd/network/10-netplan-$interface.network"
    [[ -f "$generated" ]] || blocker "Netplan generated no target NIC file" \
        "Inspect the fixture under $temp_dir/fixture."
    grep -Fxq "DNS=$normal_dns" "$generated" || blocker \
        "Netplan merge changed normal DNS" "Inspect the generated .network file."
    grep -Fxq "Domains=$normal_search ~." "$generated" || blocker \
        "Netplan merge lost route-only fallback" "Inspect the generated .network file."
}

live_matches() {
    local global domain
    global="$(resolvectl status --no-pager | sed -n '/^Global$/,/^Link [0-9]/p')"
    [[ "$global" == *"DNS Servers: $lab_dns"* ]] || return 1
    for domain in "${domains[@]}"; do
        [[ "$global" == *"~$domain"* ]] || return 1
    done
    [[ "$(resolvectl domain "$interface")" == *"$normal_search ~."* ]] || return 1
    resolvectl dns "$interface" | grep -Fq "$normal_dns"
}

apply_dns() {
    [[ "$(id -u)" -eq 0 ]] || blocker "--apply requires root" \
        "Run sudo add_labdns.sh --config FILE --apply."
    need ip
    need netplan
    need resolvectl
    need systemctl
    need timeout
    need getent
    validate_host
    validate_netplan_merge

    if [[ -f "$netplan_file" && -f "$resolved_file" ]] &&
       cmp -s "$netplan_fragment" "$netplan_file" &&
       cmp -s "$resolved_fragment" "$resolved_file" &&
       live_matches &&
       timeout 5s getent ahostsv4 "$probe_name" >/dev/null; then
        emit no-op
        return 0
    fi

    if [[ -f "$netplan_file" ]]; then
        cp -p "$netplan_file" "$temp_dir/previous-netplan"
        had_netplan=true
    fi
    if [[ -f "$resolved_file" ]]; then
        cp -p "$resolved_file" "$temp_dir/previous-resolved"
        had_resolved=true
    fi
    mkdir -p "$(dirname "$resolved_file")"
    installed=true
    trap 'on_error "$LINENO"' ERR
    install -o root -g root -m 0600 "$netplan_fragment" "$netplan_file"
    install -o root -g root -m 0644 "$resolved_fragment" "$resolved_file"
    netplan generate >"$temp_dir/netplan-live.log" 2>&1
    systemctl restart systemd-resolved.service
    resolvectl domain "$interface" "$normal_search" '~.'
    live_matches
    timeout 5s getent ahostsv4 "$probe_name" >/dev/null
    trap - ERR
    installed=false
    emit applied
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --config)
                (( $# >= 2 )) || blocker "--config needs a path" "Pass --config FILE."
                config="$2"
                shift 2
                ;;
            --dry-run) mode=dry-run; shift ;;
            --apply) mode=apply; shift ;;
            --json) format=json; shift ;;
            --help|-h) usage; return 0 ;;
            *) blocker "unknown option '$1'" "Run --help for supported options." ;;
        esac
    done
    parse_config
    temp_dir="$(mktemp -d)"
    trap 'rm -rf -- "$temp_dir"' EXIT
    netplan_fragment="$temp_dir/netplan.yaml"
    resolved_fragment="$temp_dir/resolved.conf"
    render_netplan >"$netplan_fragment"
    render_resolved >"$resolved_fragment"
    chmod 0600 "$netplan_fragment"
    if [[ "$mode" == dry-run ]]; then
        emit planned
    else
        apply_dns
    fi
}

main "$@"
