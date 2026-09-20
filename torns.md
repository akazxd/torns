Fantastic! Getting getent to output the mapped IP address means the system-wide hostname resolution engine inside your namespace is now completely fixed. Any application or script you run in this sandbox will now transparently resolve .onion links.
Here is the exact breakdown of why your change worked, why it was failing before, and how Linux handles name resolution behind the scenes.
------------------------------
## The Underlying Problem: The glibc Resolver Layer
When you type a URL into a web browser or run a command like ping or getent, the application does not talk to your DNS server or network interfaces directly. Instead, it calls a standard built-in Linux library function named getaddrinfo(), which is part of the GNU C Library (glibc).
To figure out how to answer that application, glibc reads a system-wide configuration file called /etc/nsswitch.conf (Name Service Switch).
------------------------------
## Why it was broken by default on Arch Linux
On a standard modern Arch Linux installation, the hosts: line inside /etc/nsswitch.conf looks something like this:

```bash
hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns
```

This tells the system to look up web addresses by trying these methods, from left to right:

   1. mymachines: Checks local container/systemd instance names.
   2. resolve: This is the culprit. It hands the lookup task over to the systemd-resolved background daemon via a local Unix socket (/run/systemd/resolve/io.systemd.Resolve).
   3. files: Checks your local /etc/hosts file.
   4. dns: Performs a standard, raw network DNS query using /etc/resolv.conf.

Because resolve comes before dns, glibc completely bypassed your veth network cable and went straight to the systemd-resolved service running on your host machine.
Because systemd-resolved lives on the host and doesn't know anything about your network namespace's specific Tor automapping rules, it looked at the .onion address, realized it was invalid on the public internet, and threw an error back to the namespace application before your iptables rules ever had a chance to intercept it.
------------------------------
## What your change actually did
By running:

```bash
echo "hosts: files dns" | sudo tee /etc/netns/torns/nsswitch.conf
```

You created an isolated, namespace-specific configuration override. The moment an app inside torns requests an address, glibc looks at this new file instead.

   1. It checks your local /etc/hosts file (files).
   2. When it doesn't find the entry there, it immediately moves to dns, completely bypassing systemd-resolved.
   3. The system reads your dummy namespace file (nameserver 1.1.1.1), packs the .onion address into a raw UDP packet, and sends it out toward the virtual ethernet cable (veth-ns).
   4. Your host-side iptables rules successfully catch that packet on veth-tor, rewrite it via DNAT over to Tor's real DNS listener on port 15353, and return the valid 10.228.52.52 virtual mapping back to your app.

Now that the core system loop is seamlessly closed, you can open Falkon or run any software inside this environment with standard out-of-the-box settings, and it will function perfectly!

Here is the comprehensive, line-by-line breakdown of your entire architecture.
------------------------------
## Part 1: The Network Namespace & Routing Script

```bash
#!/bin/bashset -e
```


* #!/bin/bash: Tells your system to execute this script using the Bash shell.
* set -e: The "fail-fast" flag. If any command in this script fails or returns an error, the script halts instantly instead of continuing with broken settings.

```bash
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi
```

* $EUID: Checks the Effective User ID of whoever ran the script. 0 belongs exclusively to root. If it is not 0, the script prints an error and quits because normal users cannot modify system routing or firewalls.

```bash
sysctl -w net.ipv4.conf.all.forwarding=1 > /dev/null
```


* sysctl -w ...: Modifies a Linux kernel parameter on the fly.
* net.ipv4.conf.all.forwarding=1: Globally enables IPv4 traffic forwarding. This turns your host machine into a mini-router, allowing it to pass network packets between your isolated namespace and other interfaces.
* > /dev/null: Silences the command's default text output to keep the terminal clean.

```bash
ip netns add torns 2>/dev/null || true
```


* ip netns add torns: Creates an isolated network sandbox (namespace) named torns. It has its own blank routing tables and network adapters.
* 2>/dev/null || true: If torns already exists, ip netns will throw an error. This catches that error, ignores it, and forces the script to continue smoothly.

```bash
ip link add veth-tor type veth peer name veth-ns 2>/dev/null || true
```


* ip link add ... type veth ...: Creates a Virtual Ethernet (veth) pair. Think of this as a virtual, invisible network cable. One end of this cable is named veth-tor, and the other end is named veth-ns.
* 2>/dev/null || true: Idempotency check. If the cable already exists from a previous run, ignore the error and keep going.

```bash
ip link set veth-ns netns torns 2>/dev/null || true
```


* ip link set veth-ns netns torns: Takes the veth-ns plug of your virtual cable and shoves it inside the isolated torns network sandbox. The host machine can no longer see or touch this interface directly.

```bash
ip addr add 10.200.1.1/24 dev veth-tor 2>/dev/null || true
ip link set veth-tor up
```


* ip addr add 10.200.1.1/24 ...: Assigns the IP address 10.200.1.1 to the host's end of the cable (veth-tor). The /24 creates a subnet mask (255.255.255.0), allowing for IPs between 10.200.1.1 and 10.200.1.254.
* ip link set veth-tor up: Powers on the host's network plug so it can actively send and receive data.

```bash
ip netns exec torns ip addr add 10.200.1.2/24 dev veth-ns 2>/dev/null || true
ip netns exec torns ip link set veth-ns up
```


* ip netns exec torns: Tells the system: "Execute the following command strictly inside the boundaries of the torns sandbox."
* ip addr add 10.200.1.2/24 dev veth-ns: Assigns the IP address 10.200.1.2 to the sandbox's end of the virtual cable. Now, the sandbox (.2) can ping the host (.1).
* ip link set veth-ns up: Powers on the namespace's network plug.

```bash
ip netns exec torns ip link set lo up
```


* ip link set lo up: Turns on the Loopback interface (localhost / 127.0.0.1) inside the sandbox. Applications need this interface active to handle internal process-to-process communication.

```bash
ip netns exec torns ip route replace default via 10.200.1.1
```


* ip route replace default via 10.200.1.1: Sets the default gateway for the sandbox. It tells all applications inside torns: "If you want to talk to the internet, you have no direct access. Send 100% of your outbound traffic down the virtual cable to the host at 10.200.1.1."

```bash
mkdir -p /etc/netns/torns
echo "nameserver 1.1.1.1" > /etc/netns/torns/resolv.conf
echo "hosts: files dns" > /etc/netns/torns/nsswitch.conf
```


* /etc/netns/torns/: This is a special, hardcoded path built into Linux. Whenever a command runs inside the torns namespace, Linux overrides its global configuration files with whatever is placed in this directory.
* nameserver 1.1.1.1: Configures a dummy DNS target. Applications inside the sandbox think they are querying Cloudflare, forcing them to emit a standard network DNS packet over the virtual cable.
* hosts: files dns: The Arch Linux Fix [1]. This overrides the default system behavior. It tells the GNU C Library (glibc) to resolve names using only local files or direct network DNS. This completely cuts off the host's systemd-resolved daemon, preventing it from blocking .onion strings before they leave the sandbox.

```bash
sysctl -w net.ipv4.conf.veth-tor.route_localnet=1 > /dev/null
```


* route_localnet=1: By default, Linux considers traffic coming from an external interface heading toward a loopback/local address (like 127.0.0.1 or host-bound processes) to be a security risk ("Martian packets") and drops them. Setting this to 1 explicitly forces the host to allow traffic coming out of the namespace cable to hit host-level listeners.

```bash
iptables -t nat -F PREROUTING 2>/dev/null || true
```


* -t nat -F PREROUTING: Flushes (wipes clean) the Network Address Translation (nat) table's PREROUTING chain. This clears out old rules from previous script executions so they don't stack up and conflict.

```bash
iptables -t nat -A PREROUTING -i veth-tor -p udp --dport 53 -j DNAT --to-destination 10.200.1.1:15353
iptables -t nat -A PREROUTING -i veth-tor -p tcp --dport 53 -j DNAT --to-destination 10.200.1.1:15353
```


* -A PREROUTING -i veth-tor: Appends a rule to look at packets arriving at the host on the veth-tor interface before any routing decisions are made.
* -p udp/tcp --dport 53: Targets any standard DNS requests (Port 53) generated by your application inside the sandbox.
* -j DNAT --to-destination 10.200.1.1:15353: The DNS Intercept. It hijacks those packets and rewrites their destination address on the fly, forcing them straight into Tor's custom DNS listening port (15353).

```bash
iptables -t nat -A PREROUTING -i veth-tor -d 10.192.0.0/10 -p tcp -j DNAT --to-destination 10.200.1.1:9040
```


* -d 10.192.0.0/10: Targets traffic heading specifically toward your virtual Tor IP address pool (which Tor uses to temporarily map .onion sites).
* -j DNAT --to-destination 10.200.1.1:9040: Intercepts that virtual IP traffic and maps it directly into Tor’s Transparent Proxy Port (9040).

```bash
iptables -t nat -A PREROUTING -i veth-tor -p tcp -j DNAT --to-destination 10.200.1.1:9040
```


* -p tcp -j DNAT ...: The catch-all net. Any other standard TCP web traffic (like regular HTTP/HTTPS browsing to google.com) coming out of the namespace is intercepted and forced through Tor's transparent gateway port.

------------------------------
## Part 2: The Host Tor Configuration (torrc)

```bash
SocksPort 9050
```


* Opens Tor's standard SOCKS5 proxy port on localhost for manually configured apps (like your command-line tools or proxy overrides).

```bash
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
AutomapHostsSuffixes .onion,.exit
```


* VirtualAddrNetworkIPv4: Allocates a pool of internal, unrouted IP addresses (10.192.0.0 to 10.255.255.255).
* AutomapHostsOnResolve 1: Tells Tor: "When an application asks you to resolve an unroutable address like a .onion site, don't fail. Pick a random, unassigned fake IP address from the virtual pool above, link it to that .onion site in your memory, and hand that IP back to the application."
* AutomapHostsSuffixes .onion: Restricts this fake IP assignment behavior strictly to .onion domains.

```bash
TransPort 10.200.1.1:9040 IsolateClientAddr IsolateClientProtocol IsolateDestAddr IsolateDestPort
```


* TransPort 10.200.1.1:9040: Tells Tor to run a Transparent Proxy engine listening directly on the host's virtual cable endpoint (10.200.1.1). It handles raw, un-proxied TCP packets forwarded by your iptables script.
* Isolate... flags: Instructs Tor to treat every unique destination IP, port, and client address inside the sandbox as a completely separate stream. This prevents different applications running inside the namespace from sharing the same underlying Tor circuit, ensuring identity isolation.

```bash
DNSPort 10.200.1.1:15353
```


* Binds Tor's internal DNS resolver to port 15353 on the virtual cable interface. This is the endpoint that processes your dig queries and performs the .onion-to-virtual-IP mapping.

```bash
HiddenServiceDir /var/lib/tor/tor_pub_service/
HiddenServicePort 12345 10.200.1.2:54321
```


* HiddenServiceDir: Defines the secure host folder where Tor generates and stores the cryptographic keys and unique .onion address for your hidden service.
* HiddenServicePort 12345 10.200.1.2:54321: The Inbound Port Forward. This tells Tor: "If anyone on the global Tor network tries to connect to our unique .onion address on port 12345, encrypt that traffic, tunnel it down through the Tor network, cross the namespace bridge, and hand it cleanly to the local application listening inside the sandbox at 10.200.1.2:54321."

Now that the entire architecture is transparently mapped and documented, would you like help writing an automated systemd service file so this entire infrastructure boots cleanly on system startup, or should we move on to configuring local's internal settings to match this layout?

