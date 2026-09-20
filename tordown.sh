#!/bin/bash
set -e

# Ensure this script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

echo "Beginning clean teardown of Tor network namespace environment..."

# 1. Flush and clean Host-Side iptables rules
# This clears out the DNAT rules we appended to the PREROUTING chain
if iptables -t nat -S PREROUTING | grep -q "veth-tor"; then
  echo "Flushing NAT PREROUTING rules associated with veth-tor..."
  iptables -t nat -F PREROUTING 2>/dev/null || true
fi

# 2. Delete the network namespace
# Deleting the namespace automatically destroys the internal veth-ns plug,
# drops its routing tables, turns off its loopback interface, and clears memory.
if ip netns list | grep -q "torns"; then
  ip netns delete torns
  echo "Removed network namespace: torns"
fi

# 3. Explicitly clean up the host-side veth device
# (Usually drops automatically when the namespace dies, but this ensures no dangling interfaces)
if ip link show veth-tor >/dev/null 2>&1; then
  ip link delete veth-tor
  echo "Removed host interface cable: veth-tor"
fi

# 4. Clean up the custom namespace configuration path
# This removes the isolated nsswitch.conf and resolv.conf files we created for Arch Linux
if [ -d "/etc/netns/torns" ]; then
  rm -rf /etc/netns/torns
  echo "Cleaned up configuration path: /etc/netns/torns"
fi

# 5. Reset Host Kernel Parameters to safe defaults
echo "Restoring host sysctl network parameters to defaults..."
sysctl -w net.ipv4.conf.all.forwarding=0 > /dev/null

echo "-------------------------------------------------------"
echo "Environment successfully wiped clean!"
echo "Note: You can now safely restart or run your setup script again."
echo "-------------------------------------------------------"
