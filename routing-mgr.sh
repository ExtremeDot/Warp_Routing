#!/bin/bash

# Configuration
LETTER_SET="myip_wtf_list"
DNSMASQ_CONF="/etc/dnsmasq.d/custom_routing.conf"
MAIN_DNSMASQ_CONF="/etc/dnsmasq.conf"
TABLE_ID="100"
TABLE_NAME="warp_table"
FWMARK="42"
INTERFACE="warp"

# Ensure root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Function to check and install missing packages
check_dependencies() {
    local missing_pkgs=()

    if ! command -v ipset &> /dev/null; then
        missing_pkgs+=("ipset")
    fi

    if ! command -v dnsmasq &> /dev/null; then
        missing_pkgs+=("dnsmasq")
    fi

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        echo "Missing dependencies found: ${missing_pkgs[*]}. Installing..."
        apt update -qq
        apt install -y "${missing_pkgs[@]}"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install dependencies."
            exit 1
        fi
        echo "Dependencies installed successfully."
    fi
}

# Ensure basic system and routing setup exists
init_system() {
    # 1. Check and install dependencies
    check_dependencies

    # 2. Ensure the routing table 100 is defined
    if ! grep -q "$TABLE_ID $TABLE_NAME" /etc/iproute2/rt_tables; then
        echo "$TABLE_ID $TABLE_NAME" >> /etc/iproute2/rt_tables
    fi

    # 3. Create ipset if not exists
    ipset list $LETTER_SET >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        ipset create $LETTER_SET hash:net
    fi

    # 4. Ensure dnsmasq directory and custom conf exist
    mkdir -p /etc/dnsmasq.d
    touch $DNSMASQ_CONF

    # 5. Fix dnsmasq Upstream DNS & Loop configuration
    if ! grep -q "no-resolv" $MAIN_DNSMASQ_CONF; then
        echo -e "\n# Added by routing-mgr\nno-resolv\nserver=1.1.1.1\nserver=8.8.8.8\nlisten-address=127.0.0.1" >> $MAIN_DNSMASQ_CONF
        systemctl restart dnsmasq
    fi

    # 6. Handle systemd-resolved conflict if present
    if systemctl is-active --quiet systemd-resolved; then
        echo "Stopping systemd-resolved to free port 53..."
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
    fi

    # 7. Secure and Lock /etc/resolv.conf to localhost
    if ! grep -q "nameserver 127.0.0.1" /etc/resolv.conf; then
        echo "Fixing and locking /etc/resolv.conf..."
        chattr -i /etc/resolv.conf 2>/dev/null
        echo "nameserver 127.0.0.1" > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null
        systemctl restart dnsmasq
    fi

    # 8. Apply iptables rules if not already present
    if ! iptables -t mangle -C OUTPUT -m set --match-set $LETTER_SET dst -j MARK --set-mark $FWMARK 2>/dev/null; then
        iptables -t mangle -A OUTPUT -m set --match-set $LETTER_SET dst -j MARK --set-mark $FWMARK
    fi

    if ! iptables -t nat -C POSTROUTING -o $INTERFACE -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
    fi

    # 9. Apply routing rules
    if ! ip rule show | grep -q "fwmark $(printf '0x%x' $FWMARK)"; then
        ip rule add fwmark $FWMARK table $TABLE_ID
    fi

    if ! ip route show table $TABLE_ID | grep -q "dev $INTERFACE"; then
        ip route add default dev $INTERFACE table $TABLE_ID
    fi
}

show_list() {
    echo -e "\n=== Currently Routed Domains (dnsmasq) ==="
    if [ -s "$DNSMASQ_CONF" ]; then
        cat "$DNSMASQ_CONF" | awk -F'/' '{print $2}'
    else
        echo "(No domains configured)"
    fi

    echo -e "\n=== Currently Routed IPs/Subnets (ipset) ==="
    local member_list=$(ipset list $LETTER_SET | sed -n '/Members:/,$p' | tail -n +2)
    if [ -z "$member_list" ]; then
        echo "(No permanent IPs configured)"
    else
        echo "$member_list"
    fi
    echo ""
}

add_target() {
    local target=$1
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        # It's an IP or CIDR Subnet
        ipset add $LETTER_SET $target 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "Successfully added IP/Subnet: $target"
        else
            echo "Failed to add or already exists: $target"
        fi
    else
        # It's a domain/subdomain
        if grep -q "/$target/" "$DNSMASQ_CONF"; then
            echo "Domain $target already exists in routing rules."
        else
            echo "ipset=/$target/$LETTER_SET" >> "$DNSMASQ_CONF"
            systemctl restart dnsmasq
            echo "Successfully added Domain: $target (and all its subdomains)"
        fi
    fi
}

remove_target() {
    local target=$1
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        # Remove from ipset
        ipset del $LETTER_SET $target 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "Successfully removed IP/Subnet: $target"
        else
            echo "IP/Subnet not found in the list: $target"
        fi
    else
        # Remove from dnsmasq
        if grep -q "/$target/" "$DNSMASQ_CONF"; then
            local escaped_target=$(echo "$target" | sed 's/\./\\./g')
            sed -i "/\/$escaped_target\//d" "$DNSMASQ_CONF"
            systemctl restart dnsmasq
            echo "Successfully removed Domain: $target"
            echo "Note: Dynamic IPs currently cached for this domain will expire naturally or after 'flush'."
        else
            echo "Domain $target not found in configuration."
        fi
    fi
}

flush_all() {
    ipset flush $LETTER_SET
    > "$DNSMASQ_CONF"
    systemctl restart dnsmasq
    echo "All custom routing rules flushed successfully."
}

# Main Logic
init_system

case "$1" in
    add)
        if [ -z "$2" ]; then
            echo "Usage: $0 add [domain.com / sub.domain.com / 1.2.3.4 / 192.168.1.0/24]"
            exit 1
        fi
        add_target "$2"
        ;;
    del)
        if [ -z "$2" ]; then
            echo "Usage: $0 del [domain.com / sub.domain.com / 1.2.3.4 / 192.168.1.0/24]"
            exit 1
        fi
        remove_target "$2"
        ;;
    list)
        show_list
        ;;
    flush)
        read -p "Are you sure you want to clear ALL rules? (y/n): " confirm
        if [[ $confirm == [yY] ]]; then
            flush_all
        fi
        ;;
    *)
        echo "=== Routing Manager CLI ==="
        echo "Usage: routing-mgr {add|del|list|flush}"
        echo "-------------------------------------"
        echo "Examples:"
        echo "  routing-mgr add myip.wtf        <- Routes myip.wtf and *.myip.wtf"
        echo "  routing-mgr add google.com      <- Routes specific domain"
        echo "  routing-mgr add 1.1.1.1         <- Routes specific IP"
        echo "  routing-mgr add 185.0.0.0/8     <- Routes entire IP range"
        echo "  routing-mgr del myip.wtf        <- Removes domain from routing"
        echo "  routing-mgr list                <- Shows current active lists"
        echo "  routing-mgr flush               <- Clears everything"
        exit 1
        ;;
esac
