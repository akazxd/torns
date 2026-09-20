#!/bin/bash
set -e

# Ensure this script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

# Enable routing on the host for the veth interface (Crucial for host-side filtering)
sysctl -w net.ipv4.conf.all.forwarding=1 > /dev/null

# Create Network Namespace
ip netns add torns 2>/dev/null || true

# Create Veth Pair
ip link add veth-tor type veth peer name veth-ns 2>/dev/null || true
ip link set veth-ns netns torns 2>/dev/null || true

# Configure Host Side
ip addr add 10.200.1.1/24 dev veth-tor 2>/dev/null || true
ip link set veth-tor up

# Configure Namespace Side
ip netns exec torns ip addr add 10.200.1.2/24 dev veth-ns 2>/dev/null || true
ip netns exec torns ip link set veth-ns up
ip netns exec torns ip link set lo up
ip netns exec torns ip route replace default via 10.200.1.1

# DNS Isolated Config
# mkdir -p /etc/netns/torns
# echo "nameserver 10.200.1.1" > /etc/netns/torns/resolv.conf

sudo mkdir -p /etc/netns/torns
echo "nameserver 1.1.1.1" | sudo tee /etc/netns/torns/resolv.conf
echo "hosts: files dns" | sudo tee /etc/netns/torns/nsswitch.conf


# Note: Modern Linux automatically loads /etc/netns/<ns_name>/resolv.conf
# when running inside that namespace, removing the need for a bind mount!
# sudo ip netns exec torns mount --bind /tmp/resolv.conf.torns /etc/resolv.conf

# Host-Side Interception (Fixed Rules using DNAT instead of REDIRECT)
# Assumes Tor is listening on 127.0.0.1:9040 and 127.0.0.1:5353 on the host
sysctl -w net.ipv4.conf.veth-tor.route_localnet=1 > /dev/null

# Idempotent NAT Rules on Host

# Clean up any lingering rules
iptables -t nat -F PREROUTING 2>/dev/null || true

# 1. Clean & Apply DNS Interception (UDP Port 53 -> Tor Port 15353)
iptables -t nat -C PREROUTING -i veth-tor -p udp --dport 53 -j DNAT --to-destination 10.200.1.1:15353 2>/dev/null || \
  iptables -t nat -A PREROUTING -i veth-tor -p udp --dport 53 -j DNAT --to-destination 10.200.1.1:15353

# 2. Clean & Apply Virtual Tor-IP Map Interception (10.192.0.0/10 -> Tor TransPort)
# Fixed: Swapped fragile REDIRECT for clean DNAT to 10.200.1.1
iptables -t nat -C PREROUTING -i veth-tor -d 10.192.0.0/10 -p tcp -j DNAT --to-destination 10.200.1.1:9040 2>/dev/null || \
  iptables -t nat -A PREROUTING -i veth-tor -d 10.192.0.0/10 -p tcp -j DNAT --to-destination 10.200.1.1:9040

# 3. Clean & Apply General Catch-all Web Interception (All other TCP -> Tor TransPort)
iptables -t nat -C PREROUTING -i veth-tor -p tcp -j DNAT --to-destination 10.200.1.1:9040 2>/dev/null || \
  iptables -t nat -A PREROUTING -i veth-tor -p tcp -j DNAT --to-destination 10.200.1.1:9040

  # Disable Reverse Path Filtering on the host-side veth so it doesn't reject your custom subnet packets
sysctl -w net.ipv4.conf.veth-tor.rp_filter=0 > /dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 > /dev/null


# Explicit Interception Rules using the INPUT/PREROUTING matrix
# iptables -t nat -A PREROUTING -i veth-tor -p udp --dport 53 -j DNAT --to-destination 10.200.1.1:15353
# iptables -t nat -A PREROUTING -i veth-tor -p tcp -j DNAT --to-destination 10.200.1.1:9040


echo "Tor network namespace 'torns' is ready!"
