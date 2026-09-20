GGG - Gemini Generated Guidebook

---

Virtual Ethernet (veth) pairs and network namespaces (netns) are Linux kernel features used to build isolated network environments and connect them together like a virtual cable. [1][2] 
## What is a Network Namespace (netns)?

* A network namespace is an isolated copy of the network stack.
* It has its own network interfaces, routing tables, and firewall rules. [3] 
* Processes inside a namespace cannot see or talk to networks outside it by default.

## What is a veth Pair?

* A veth pair consists of two virtual network interfaces.
* They act like a physical Ethernet cable plugged between two places.
* Anything sent into one end instantly comes out the other. [4][5] 

## How to Connect Namespaces Using veth
You can link an isolated namespace to the host or another namespace using basic iproute2 commands: [4, 5] 
```bash
   #1. Create a network namespace:
   
   sudo ip netns add ns1
   
   #2. Create a veth pair:
   
   sudo ip link add veth0 type veth peer name veth1
   
   #3. Move one end into the namespace:
   
   sudo ip link set veth1 netns ns1
   
   #4. Assign IP addresses and bring interfaces up:
   
   sudo ip addr add 192.168.1.1/24 dev veth0
   sudo ip link set veth0 up
   sudo ip netns exec ns1 ip addr add 192.168.1.2/24 dev veth1
   sudo ip netns exec ns1 ip link set veth1 up
```
   
Containers like Docker and Kubernetes use this exact combination of netns and veth pairs to give each container its own private network while letting it communicate with the host or other containers. [6] 
Would you like to learn how to configure NAT and IP forwarding so your network namespace can access the internet?

---

To give your network namespace internet access, you need to enable IP forwarding on the host, configure Network Address Translation (NAT) using iptables (or nftables), and set up a default gateway inside the namespace.
Here is the step-by-step configuration assuming you are continuing from the previous setup:
## 1. Enable IP Forwarding on the Host
By default, Linux drops packets meant for other destinations. You must tell the host kernel to act as a router:

```sudo sysctl -w net.ipv4.ip_forward=1```

(To make this permanent, edit ```/etc/sysctl.conf``` and uncomment ```net.ipv4.ip_forward=1```).
## 2. Configure NAT (Masquerading) on the Host
You need to translate the private namespace IP (192.168.1.2) into the host's public/external IP when traffic leaves the host.
Run this command, replacing eth0 with your host's actual internet-connected interface (like wlan0 or enp3s0):

```sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE```

## 3. Set the Default Routing Gateway inside the Namespace
Inside the namespace ns1, tell the network stack to route all external traffic through the host's end of the veth pair (192.168.1.1):

```sudo ip netns exec ns1 ip route add default via 192.168.1.1```

## 4. Configure DNS inside the Namespace
To resolve domain names (like google.com), the namespace needs a DNS server. Create a network-specific directory and add a nameserver:

```bash
sudo mkdir -p /etc/netns/ns1
echo "nameserver 8.8.8.8" | sudo tee /etc/netns/ns1/resolv.conf
```


Note: Linux automatically swaps the namespace's ```/etc/resolv.conf``` with this file when running commands inside ns1.
## 5. Test the Connection
Verify that everything is working by pinging an external IP and a domain name from inside the namespace:

# Test routing
```sudo ip netns exec ns1 ping -c 2 8.8.8.8```
# Test DNS resolution
```bashsudo ip netns exec ns1 ping -c 2 google.com```

Would you like to see how to automate this setup with a bridge interface so you can easily connect multiple namespaces to the internet at once?



[1] [https://medium.com](https://medium.com/@amazingandyyy/introduction-to-network-namespaces-and-virtual-ethernet-veth-devices-304e0c02d084)
[2] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-20-veth-pair-between-namespaces/view)
[3] [https://medium.com](https://medium.com/@mishajib/connect-network-namespaces-through-veth-virtual-ethernet-cable-fb1d3a2a40f7)
[4] [https://man7.org](https://man7.org/linux/man-pages/man4/veth.4.html)
[5] [https://medium.com](https://medium.com/@mishu667/creating-two-network-namespaces-and-connect-them-with-virtual-ethernet-veth-devices-565f83af4c37)
[6] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-03-20-connect-namespaces-veth-pairs-linux/view)
