#!/usr/bin/env bash

clear
DROPBEAR_VERSION="2019.78"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases/dropbear-$DROPBEAR_VERSION.tar.bz2"

DROPBEAR_BIN="/usr/sbin/dropbear"
DROPBEAR_CONFIG="/etc/dropbear"

echo "===================================="
echo " INSTALL DROPBEAR $DROPBEAR_VERSION "
echo "===================================="
echo ""

# stop service jika ada
systemctl stop dropbear 2>/dev/null
service dropbear stop 2>/dev/null

# backup binary jika ada
if [ -f "$DROPBEAR_BIN" ]; then
    echo "Backup dropbear lama..."
    cp $DROPBEAR_BIN /usr/sbin/dropbear.bak
fi

# hapus install lama
rm -rf /usr/sbin/dropbear
rm -rf /usr/bin/dropbear*
rm -rf /usr/local/sbin/dropbear*
rm -rf /usr/local/bin/dropbear*

mkdir -p $DROPBEAR_CONFIG

echo ""
echo "Install dependency..."

if command -v apt-get >/dev/null; then
    apt-get update -y
    apt-get install -y build-essential zlib1g-dev wget
elif command -v yum >/dev/null; then
    yum groupinstall "Development Tools" -y
    yum install -y zlib-devel wget
fi

echo ""
echo "Download Dropbear $DROPBEAR_VERSION..."

cd /usr/src || exit
rm -rf dropbear*

wget --no-check-certificate $DROPBEAR_URL

if [ ! -f "dropbear-$DROPBEAR_VERSION.tar.bz2" ]; then
    echo "Download gagal"
    exit 1
fi

echo ""
echo "Extract source..."

tar -xjf dropbear-$DROPBEAR_VERSION.tar.bz2
cd dropbear-$DROPBEAR_VERSION || exit

echo ""
echo "Compile dropbear..."

./configure --prefix=/usr
make
make install

# pindahkan binary ke sbin
if [ -f "/usr/bin/dropbear" ]; then
    mv /usr/bin/dropbear /usr/sbin/dropbear
fi

chmod +x /usr/sbin/dropbear

echo ""
echo "Generate host key..."

rm -f $DROPBEAR_CONFIG/*

dropbearkey -t rsa -f $DROPBEAR_CONFIG/dropbear_rsa_host_key
dropbearkey -t dss -f $DROPBEAR_CONFIG/dropbear_dss_host_key
dropbearkey -t ecdsa -f $DROPBEAR_CONFIG/dropbear_ecdsa_host_key

chmod 600 $DROPBEAR_CONFIG/*

echo ""
echo "Start service..."

if command -v systemctl >/dev/null; then
    systemctl restart dropbear 2>/dev/null
else
    service dropbear restart 2>/dev/null
fi

echo ""
echo "Installed version:"
dropbear -V

echo ""
echo "===================================="
echo " DROPBEAR $DROPBEAR_VERSION INSTALLED "
echo "===================================="