# openvpn
How to create openvpn server

## Setup SSH

On the desktop:
```bash
ssh-keygen -t ecdsa -C root@server -f .ssh/server-root
```

```bash
# paste contents of .ssh/server-root.pub
vim /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys 
```

```bash
ufw allow ssh
ufw enable
```

## Setup OpenVPN

```bash
apt-get update
apt install openvpn easy-rsa -y
cp -r /usr/share/easy-rsa /etc/
cd /etc/easy-rsa/
./easyrsa init-pki
./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa build-server-full server nopass
openvpn --genkey secret /etc/easy-rsa/pki/ta.key
./easyrsa gen-crl
cp -rp /etc/easy-rsa/pki/{ca.crt,dh.pem,ta.key,crl.pem,issued,private} /etc/openvpn/server/
cp /usr/share/doc/openvpn/examples/sample-config-files/server.conf /etc/openvpn/server/
vim /etc/openvpn/server/server.conf 
```

```conf
port 12321
proto tcp
dev tun
ca ca.crt
cert issued/server.crt
key private/server.key # This file should be kept secret
dh dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/log/openvpn/ipp.txt
push "redirect-gateway def1 bypass-dhcp"
# Block DNS requests for ad services
# local pi-hole pi-hole
# push "dhcp-option DNS 10.8.0.1" 
push "dhcp-option 8.8.8.8"  # Google DNS
push "dhcp-option DNS 1.1.1.1"
client-to-client
keepalive 10 120
# tls-auth ta.key 0 # This file is secret
cipher AES-128-GCM
auth SHA1
data-ciphers CHACHA20-POLY1305:AES-128-GCM
data-ciphers-fallback AES-128-GCM

persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log
log /var/log/openvpn/openvpn.log
verb 3
explicit-exit-notify 1
```

### Enable forwarding

```bash
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl --system
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw reload

IF_MAIN=eth0
IF_TUNNEL=tun0
YOUR_OPENVPN_SUBNET=10.8.0.0/24
#YOUR_OPENVPN_SUBNET=10.8.0.0/16 # if using server.conf from sample-server-config
iptables -A FORWARD -i $IF_MAIN -o $IF_TUNNEL -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -s $YOUR_OPENVPN_SUBNET -o $IF_MAIN -j ACCEPT
iptables -t nat -A POSTROUTING -s $YOUR_OPENVPN_SUBNET -o $IF_MAIN -j MASQUERADE
```

### Start service

```bash
# start the server
systemctl enable --now openvpn-server@server
```

### Script to create clients

```bash
vim /etc/openvpn/client/client.conf
```

```conf
client
;dev tap
dev tun
;dev-node MyTap
proto tcp
;proto udp
remote  server.ip.address 12321
;remote my-server-2 1194
;remote-random
resolv-retry infinite
nobind
;user openvpn
;group openvpn
persist-key
persist-tun
;http-proxy-retry 
;http-proxy [proxy server] [proxy port 
;mute-replay-warnings
;ca ca.crt
;cert client.crt
;key client.key
remote-cert-tls server
data-ciphers CHACHA20-POLY1305:AES-128-GCM
auth SHA1
;tls-auth ta.key 1
verb 3
;mute 20
```

Script `make_vpn_client.sh`:

```bash
#!/bin/bash

# make_client_config.sh client_id ...
# Arguments: Client identifier

PREFIX=server

function die {
        if [ -n "$1" ]; then echo "$@" > /dev/stderr; fi
        exit 1
}


[ -n "${1}" ] || die "$0 client_name ..."

[ "$EUID" -eq 0 ] || die "This script must be run as root (use sudo)"

assert() {
        [ -z "$1" ] && die "assert: no args"
        test -f "$1" || die "no such file: $1"
}

create_vpn_user () {
    assert /etc/easy-rsa/easyrsa
    pushd /etc/easy-rsa > /dev/null
    echo yes | ./easyrsa build-client-full "$1" nopass
    if [ $? -ne 0 ]; then
        echo "Failed to create VPN user: $1" > /dev/stderr
        popd
        return 1
    fi
    echo "Created VPN user: $1"
    popd > /dev/null
    return 0
}

make_client_config() {
        assert /etc/openvpn/client/client.conf
        assert /etc/openvpn/server/ca.crt
        assert /etc/openvpn/server/ta.key

        KEY=/etc/easy-rsa/pki/private/${1}.key
        CRT=/etc/easy-rsa/pki/issued/${1}.crt

        [ -f "$KEY" ] || create_vpn_user "$1" || die "Failed to create VPN user: $1"

        assert "$KEY"
        assert "$CRT"

        {
                cat /etc/openvpn/client/client.conf
                echo -e '<ca>'
                cat /etc/openvpn/server/ca.crt
                echo -e '</ca>\n<cert>'
                cat /etc/easy-rsa/pki/issued/${1}.crt
                echo -e '</cert>\n<key>'
                cat /etc/easy-rsa/pki/private/${1}.key
                echo -e '</key>'
        #       echo '<tls-crypt>'
        #       cat /etc/openvpn/server/ta.key
        #       echo -e '</tls-crypt>'
        } > "hessegg.$1.ovpn"
        if [ -n "$SUDO_USER" ]; then
            chown $SUDO_UID:$SUDO_GID "hessegg.$1.ovpn"
        fi
        chmod 600 "${PREFIX}.${1}.ovpn"
}

for client in "$@"; do
        if make_client_config "$client"; then
                echo "Created config for $client"
        else
                echo "Failed to create config for $client" > /dev/stderr
        fi
done
```

## Setup Pihole

```bash
# allow DNS for pihole
ufw allow in on tun0 to any port 53 proto udp
# allow HTTP for pihole on 8080
ufw allow in on tun0 to any port 8080 proto http
# install pihole
curl -sSL https://install.pi-hole.net | bash
systemctl stop dnsmasq
systemctl disable dnsmasq
```

Set pihole admin password:

```bash
pihole setpassword
```

Add pihole to dns in openvpn:

```bash
vim /etc/openvpn/server/server.conf
```

```conf
push "dhcp-option DNS 10.8.0.1"
```

```bash
systemctl restart openvpn-server@server
```

check pihole:

```bash
dig @10.8.0.1 example.com
ss -ulnp | grep 53
```

Setup crontab:

```bash
nano /etc/cron.daily/pihole-update
```

```bash
#!/bin/bash
/usr/local/bin/pihole updateGravity > /var/log/pihole/update.log 2>&1
```

```
chmod +x /etc/cron.daily/pihole-update
run-parts --test /etc/cron.daily
```

Test crontab

```bash
/etc/cron.daily/pihole-update 
less /var/log/pihole/update.log 
```

## Generate users

```bash
sudo ./make_client_config.sh user1 user2 user3
```
