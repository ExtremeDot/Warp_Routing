# Linux Domain & IP Policy Router (`routing-mgr`)

A lightweight, zero-dependency Bash script for Linux that enables **OS-level domain and IP-based policy routing**. It automatically intercepts and routes specified domains (and all their subdomains), explicit IPs, or entire CIDR subnets through a specific network interface (like Cloudflare `warp`, WireGuard, or any other VPN interface) without needing application-level proxies like Xray or Sing-box.

It safely manages `dnsmasq`, bypasses `systemd-resolved` port 53 conflicts, creates efficient kernel-level `ipset` tables, and configures `iptables` rules natively.

---

## Features

* **Subdomain Wildcard Support:** Routing `example.com` automatically routes `*.example.com` (e.g., `api.example.com`, `test.example.com`).
* **IP & Subnet Support:** Handles individual IPs (`1.1.1.1`) or networks (`185.0.0.0/8`) out of the box.
* **Auto-Dependency Installer:** Automatically checks, updates, and installs missing packages (`ipset`, `dnsmasq`).
* **Kernel-Level Speed:** Uses Netfilter (`ipset` + `iptables`) for fast packet processing inside the Linux kernel.
* **Persistent DNS Setup:** Disables `systemd-resolved` to clear port 53 conflicts and locks `/etc/resolv.conf` securely.

---

## Prerequisites

* Linux OS (Ubuntu / Debian recommended)
* A secondary network interface up and running (e.g., `warp`, `wg0`, `tun0`)
* Root privileges

---

## Installation

1. Download or copy the script to your server:
   
```
   sudo nano /usr/local/bin/routing-mgr
```

Paste the script content into the file, save, and exit.

Make it executable:


```
sudo chmod +x /usr/local/bin/routing-mgr
```

Configuration Note: Inside the script, the default exit interface is set to INTERFACE="warp". If your interface has a different name (like wg0 or tun0), open the script and modify the configuration variables at the top.



----

### Usage & Examples

#### Update Version 2

```
nano /root/targets.txt
```

```
# تنظیم ترافیک برای خروجی وارپ
interface=warp
[
  myip.wtf
  speedtest.com
  129.140.0.0/24
  14.15.26.32
  core.digikala.com
]

# تنظیم ترافیک برای خروجی تور یا هر تانل دیگر
interface=tor
[
  fifa.com
  119.140.0.0/24
  16.15.26.32
]
```

### ۱. وارد کردن لیست از فایل (Import)

برای خواندن فایل دیتای آدرس‌ها و اعمال فورا‌یِ قوانین فایروال و مسیرها:


```
routing-mgr import /root/targets.txt
```


The script provides a simple Command Line Interface (CLI):

```
routing-mgr {add|del|list|flush}
```

### 1. Route a Domain and its Subdomains

To route myip.wtf and any subdomain under it (e.g., sub.myip.wtf) through the warp interface:

```
sudo routing-mgr add myip.wtf
```

### 2. Route an Explicit IP or CIDR Subnet

```
sudo routing-mgr add 1.1.1.1
sudo routing-mgr add 185.200.12.0/24

```

### 3. Remove a Rule

To stop routing a domain or IP through the interface:

```
sudo routing-mgr del myip.wtf
sudo routing-mgr del 1.1.1.1

```


### 4. View Active Routing Rules

To see which domains are being listened to and what IPs are currently cached or permanently hardcoded into the kernel memory:

```
sudo routing-mgr list
```

نمونه خروجی  دستور

```
================ Active Routing Lists ================

--> Interface: warp
  Configured Domains:
    - myip.wtf
    - speedtest.com
    - core.digikala.com
  Active/Cached IPs in Kernel (ipset):
    - 129.140.0.0/24
    - 14.15.26.32
    - 104.21.19.201  <-- (آی‌پی داینامیک کش شده از دامنه)

--> Interface: tor
  Configured Domains:
    - zara.com
  Active/Cached IPs in Kernel (ipset):
    - 119.140.0.0/24
    - 16.15.26.32

======================================================

```

### 5. Clear Everything (Flush)

To revert all changes, clear the tables, and wipe out custom rules:


```
sudo routing-mgr flush
```




