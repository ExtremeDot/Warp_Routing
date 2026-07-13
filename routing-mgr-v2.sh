#!/bin/bash

# Base Settings
MAIN_DNSMASQ_CONF="/etc/dnsmasq.conf"
DNSMASQ_DIR="/etc/dnsmasq.d"

# Ensure root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

check_dependencies() {
    local missing_pkgs=()
    ! command -v ipset &> /dev/null && missing_pkgs+=("ipset")
    ! command -v dnsmasq &> /dev/null && missing_pkgs+=("dnsmasq")
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        echo "Installing missing dependencies: ${missing_pkgs[*]}..."
        apt update -qq && apt install -y "${missing_pkgs[@]}"
    fi
}

init_global_system() {
    check_dependencies
    mkdir -p $DNSMASQ_DIR

    # Fix dnsmasq Upstream Loop
    if ! grep -q "no-resolv" $MAIN_DNSMASQ_CONF; then
        echo -e "\n# Added by routing-mgr\nno-resolv\nserver=1.1.1.1\nserver=8.8.8.8\nlisten-address=127.0.0.1" >> $MAIN_DNSMASQ_CONF
        systemctl restart dnsmasq
    fi

    # Handle systemd-resolved conflict
    if systemctl is-active --quiet systemd-resolved; then
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
    fi

    # Lock resolv.conf to localhost
    if ! grep -q "nameserver 127.0.0.1" /etc/resolv.conf; then
        chattr -i /etc/resolv.conf 2>/dev/null
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null
        systemctl restart dnsmasq
    fi
}

# Dynamic creation of routing rules per interface
init_interface_routing() {
    local iface=$1
    local ipset_name="set_${iface}"
    local table_id=""
    local fwmark=""

    # Dynamically generate Table ID and FWMark based on Interface string CRC
    fwmark=$(echo "$iface" | cksum | awk '{print $1 % 1000 + 100}')
    table_id=$fwmark

    # Create ipset if not exists
    ipset list $ipset_name >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        ipset create $ipset_name hash:net
    fi

    # Add routing table alias if not exists
    if ! grep -q "$table_id table_${iface}" /etc/iproute2/rt_tables; then
        echo "$table_id table_${iface}" >> /etc/iproute2/rt_tables
    fi

    # Apply iptables Mangle & NAT
    if ! iptables -t mangle -C OUTPUT -m set --match-set $ipset_name dst -j MARK --set-mark $fwmark 2>/dev/null; then
        iptables -t mangle -A OUTPUT -m set --match-set $ipset_name dst -j MARK --set-mark $fwmark
    fi

    if ! iptables -t nat -C POSTROUTING -o $iface -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE
    fi

    # Policy Routing Rules
    if ! ip rule show | grep -q "fwmark $(printf '0x%x' $fwmark)"; then
        ip rule add fwmark $fwmark table $table_id
    fi

    if ! ip route show table $table_id | grep -q "dev $iface"; then
        ip route add default dev $iface table $table_id
    fi
}

add_target() {
    local iface=$1
    local target=$2
    local ipset_name="set_${iface}"
    local conf_file="${DNSMASQ_DIR}/routing_${iface}.conf"

    touch $conf_file
    init_interface_routing $iface

    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        # IP or CIDR Subnet
        ipset add $ipset_name $target 2>/dev/null
        echo "  [IP] Added $target to $iface"
    else
        # Domain / Subdomain
        if ! grep -q "/$target/" "$conf_file"; then
            echo "ipset=/$target/$ipset_name" >> "$conf_file"
            echo "  [Domain] Added $target to $iface"
            return 0
        fi
    fi
    return 1
}

import_from_file() {
    local file_path=$1
    if [ ! -f "$file_path" ]; then
        echo "Error: File $file_path not found."
        exit 1
    fi

    echo "Processing file: $file_path"
    local current_iface=""
    local dns_needs_restart=false

    while IFS= read -r line || [ -n "$line" ]; do
        # Clean up line (remove spaces, tabs, brackets)
        line=$(echo "$line" | tr -d ' \t\r[]')
        
        # Skip empty lines or comments
        [[ -z "$line" || "$line" =~ ^# ]] && continue

        # Check if interface switched
        if [[ "$line" =~ ^interface= ]]; then
            current_iface=$(echo "$line" | cut -d'=' -f2)
            echo "Switching Target Interface to: $current_iface"
            continue
        fi

        # Add target if interface is defined
        if [ -n "$current_iface" ]; then
            add_target "$current_iface" "$line"
            [ $? -eq 0 ] && dns_needs_restart=true
        else
            echo "Warning: Skipped '$line' because no interface was specified yet."
        fi
    done < "$file_path"

    if [ "$dns_needs_restart" = true ]; then
        echo "Restarting dnsmasq to apply new domain rules..."
        systemctl restart dnsmasq
    fi
    echo "Import completed successfully."
}

flush_all() {
    rm -f ${DNSMASQ_DIR}/routing_*.conf
    systemctl restart dnsmasq
    
    # Clear ipsets starting with set_
    for set in $(ipset list -n | grep "^set_"); do
        ipset destroy $set
    done
    
    echo "All multi-interface routing rules flushed successfully."
}

show_lists() {
    echo -e "\n================ Active Routing Lists ================"
    for conf in ${DNSMASQ_DIR}/routing_*.conf; do
        [ -e "$conf" ] || continue
        local iface=$(basename "$conf" | sed 's/routing_//;s/.conf//')
        echo -e "\n--> Interface: \e[1;32m$iface\e[0m"
        echo "  Configured Domains:"
        cat "$conf" | awk -F'/' '{print "    - " $2}'
        
        echo "  Active/Cached IPs in Kernel (ipset):"
        local ipset_entries=$(ipset list "set_${iface}" | sed -n '/Members:/,$p' | tail -n +2)
        if [ -z "$ipset_entries" ]; then
            echo "    (No static/cached IPs yet)"
        else
            echo "$ipset_entries" | sed 's/^/    - /'
        fi
    done
    echo -e "\n======================================================"
}

# Main Logic
init_global_system

case "$1" in
    import)
        if [ -z "$2" ]; then
            echo "Usage: $0 import [/path/to/file.txt]"
            exit 1
        fi
        import_from_file "$2"
        ;;
    flush)
        read -p "Are you sure you want to wipe ALL rules for ALL interfaces? (y/n): " confirm
        [[ $confirm == [yY] ]] && flush_all
        ;;
    list)
        show_lists
        ;;
    *)
        echo "=== Multi-Interface Routing Manager ==="
        echo "Usage: routing-mgr {import|list|flush}"
        echo "-------------------------------------"
        echo "Examples:"
        echo "  routing-mgr import /root/targets.txt"
        echo "  routing-mgr list"
        echo "  routing-mgr flush"
        exit 1
        ;;
esac
