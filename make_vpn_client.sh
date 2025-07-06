#!/bin/bash

# make_client_config.sh client_id ...
# Arguments: Client identifier

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
        chmod 600 "hessegg.$1.ovpn"
}

for client in "$@"; do
        if make_client_config "$client"; then
                echo "Created config for $client"
        else
                echo "Failed to create config for $client" > /dev/stderr
        fi
done
