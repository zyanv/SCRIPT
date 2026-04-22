#!/bin/bash
set -euo pipefail

clear

if [ "$(id -u)" -ne 0 ]; then
  echo "Jalankan script ini sebagai root"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

log() {
  echo -e "\e[32m[OK]\e[0m $*"
}

warn() {
  echo -e "\e[33m[WARN]\e[0m $*"
}

fail() {
  echo -e "\e[31m[ERR]\e[0m $*"
  exit 1
}

# Update & install package
apt update -y
apt install -y \
  wget curl openssl binutils coreutils gnupg bc vnstat sudo \
  htop lsof jq python3 ruby lolcat unzip zip socat certbot cron \
  iptables iptables-persistent dante-server dos2unix

gem install lolcat || true

# Fix DNS
cat > /etc/resolv.conf <<EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF
log "DNS updated"

# Fix Port OpenSSH
if [ -f /etc/ssh/sshd_config ]; then
  sed -i 's/^[#[:space:]]*Port 22/Port 22/g' /etc/ssh/sshd_config
  grep -q '^Port 3303$' /etc/ssh/sshd_config || echo 'Port 3303' >> /etc/ssh/sshd_config
  systemctl restart ssh || true
  systemctl restart sshd || true
  log "SSH port configured"
fi

# Make directories
mkdir -p /etc/xray/limit/ip/ssh
mkdir -p /etc/xray/limit/ip/vless
mkdir -p /etc/xray/limit/quota/ssh
mkdir -p /etc/xray/limit/database/ssh
mkdir -p /etc/xray/limit/database/vless
mkdir -p /etc/xray/usage/quota/vless
mkdir -p /etc/xray/recovery/ssh
mkdir -p /etc/xray/recovery/vless
mkdir -p /usr/local/share/xray
mkdir -p /var/log/xray
mkdir -p /etc/xray
log "Directories created"

# Copy menu
cd /usr/local/sbin
wget -qO menu.zip "https://raw.githubusercontent.com/zyanv/SCRIPT/main/FILE/main.zip"
unzip -o menu.zip
rm -f menu.zip
chmod +x ./* || true
cd /root
log "Menu files installed"

# Setup firewall
systemctl stop ufw 2>/dev/null || true
systemctl disable ufw 2>/dev/null || true
apt purge -y ufw || true
apt autoremove -y

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -A INPUT -p tcp --dport 1:65535 -j ACCEPT
iptables -A INPUT -p udp --dport 1:65535 -j ACCEPT
netfilter-persistent save
iptables-save > /etc/iptables/rules.v4
log "Firewall configured"

# Setup Socks5 Proxy
touch /var/log/danted.log
chown root:root /var/log/danted.log
primary_interface=$(ip route | awk '/default/ {print $5; exit}')
[ -n "$primary_interface" ] || fail "Tidak bisa mendeteksi interface utama"

cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log

internal: 0.0.0.0 port = 40000
external: $primary_interface

method: none
user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}
EOF

if [ -f /usr/lib/systemd/system/danted.service ]; then
  grep -q 'ReadWriteDirectories=/var/log' /usr/lib/systemd/system/danted.service || \
  sed -i '/\[Service\]/a ReadWriteDirectories=/var/log' /usr/lib/systemd/system/danted.service
fi

systemctl daemon-reload
systemctl enable danted
systemctl restart danted
log "Dante configured"

# Set domain
clear
echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++++"
echo "            INPUT DOMAIN FOR SERVER"
echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++++"

while true; do
  read -rp "Input domain: " domain
  if [[ -n "${domain}" ]]; then
    break
  fi
  echo -e "\e[31m[!] Domain tidak boleh kosong, silakan ulangi.\e[0m"
done

echo "$domain" > /etc/xray/domain
log "Domain set -> $domain"

# Install Dropbear
apt install -y dropbear
bash <(curl -fsSL https://raw.githubusercontent.com/zyanv/WARP/main/dropbear.sh)

rm -f /etc/dropbear/dropbear_rsa_host_key
dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key

rm -f /etc/dropbear/dropbear_dss_host_key
dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key

rm -f /etc/dropbear/dropbear_ecdsa_host_key
dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key

cd /etc/default
rm -f dropbear
wget -qO dropbear "https://raw.githubusercontent.com/zyanv/SCRIPT/main/CONFIG/dropbear.conf"

grep -qxF "/bin/false" /etc/shells || echo "/bin/false" >> /etc/shells
grep -qxF "/usr/sbin/nologin" /etc/shells || echo "/usr/sbin/nologin" >> /etc/shells

echo "Dev @Rerechan02" > /etc/issue.net
systemctl daemon-reload
systemctl restart dropbear
cd /root
rm -rf dropbear*
log "Dropbear installed"

# Install SSH WebSocket
cd /usr/local/bin
wget -qO ssh-ws "https://raw.githubusercontent.com/zyanv/SCRIPT/main/CORE/ssh-ws"
chmod +x ssh-ws

cd /etc/systemd/system
wget -qO ssh-ws.service "https://raw.githubusercontent.com/zyanv/SCRIPT/main/SERVICE/ssh-ws.service"
systemctl daemon-reload
systemctl enable ssh-ws.service
systemctl restart ssh-ws.service
cd /root
log "SSH WebSocket installed"

# Install Xray data
wget -qO /usr/local/share/xray/geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
wget -qO /usr/local/share/xray/geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
chmod 644 /usr/local/share/xray/geosite.dat /usr/local/share/xray/geoip.dat

wget -qO /etc/xray/config.json "https://raw.githubusercontent.com/zyanv/SCRIPT/main/CONFIG/config.json"
uuid=$(cat /proc/sys/kernel/random/uuid)
sed -i "s|xxxxx|${uuid}|g" /etc/xray/config.json

bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u www-data

# Update ke latest official Xray
systemctl stop xray 2>/dev/null || true
LATEST=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
wget -qO /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${LATEST}/Xray-linux-64.zip"
unzip -o /tmp/xray.zip -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm -f /tmp/xray.zip
log "Xray updated to $LATEST"

# Fix Xray logs and service
mkdir -p /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chown -R root:root /var/log/xray
chmod 644 /var/log/xray/access.log /var/log/xray/error.log

wget -qO /etc/systemd/system/xray.service "https://raw.githubusercontent.com/zyanv/SCRIPT/main/SERVICE/xray.service"
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
log "Xray service configured"

# Input email for certbot
clear
echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++++"
echo "            INPUT EMAIL FOR CERTIFICATE"
echo "+++++++++++++++++++++++++++++++++++++++++++++++++++++++"

while true; do
  read -rp "Input email: " email
  if [[ -n "${email}" ]]; then
    break
  fi
  echo -e "\e[31m[!] Email tidak boleh kosong, silakan ulangi.\e[0m"
done
log "Email set -> $email"

# Nginx & certificate setup
systemctl stop apache2 2>/dev/null || true
systemctl disable apache2 2>/dev/null || true

if lsof -i:80 >/dev/null 2>&1; then
  warn "Port 80 sedang dipakai, mencoba hentikan proses terkait"
  fuser -k 80/tcp || true
fi

yes Y | certbot certonly --standalone --preferred-challenges http --agree-tos --email "$email" -d "$domain"

cp "/etc/letsencrypt/live/$domain/fullchain.pem" /etc/xray/xray.crt
cp "/etc/letsencrypt/live/$domain/privkey.pem" /etc/xray/xray.key
chmod 644 /etc/xray/xray.crt
chmod 600 /etc/xray/xray.key

bash <(curl -Lks https://raw.githubusercontent.com/zyanv/WARP/main/cert) || true
log "Certificate installed"

# Setup Nginx
bash <(curl -fsSL https://raw.githubusercontent.com/zyanv/WARP/main/nginx.sh)
systemctl stop nginx 2>/dev/null || true
wget -qO /etc/nginx/nginx.conf "https://raw.githubusercontent.com/zyanv/SCRIPT/main/CONFIG/nginx.conf"
sed -i "s|fn.com|${domain}|g" /etc/nginx/nginx.conf
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

nginx -t
systemctl enable nginx
systemctl restart nginx
log "Nginx configured"

# Setup crontab
grep -q "xp-ssh" /etc/crontab || echo "* * * * * root xp-ssh" >> /etc/crontab
grep -q "xp-vless" /etc/crontab || echo "* * * * * root xp-vless" >> /etc/crontab
grep -q "backup" /etc/crontab || echo "0 * * * * root backup" >> /etc/crontab
grep -q "fixlog" /etc/crontab || echo "0 0 * * * root fixlog" >> /etc/crontab
grep -q "cek-ssh" /etc/crontab || echo "0 * * * * root cek-ssh" >> /etc/crontab
grep -q "cek-vless" /etc/crontab || echo "0 * * * * root cek-vless" >> /etc/crontab

systemctl daemon-reload
systemctl restart cron
log "Cron configured"

# Install package lain
wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1vY2Cinutahu7x_zM8t5iGIHyUNo3PtgW' -O /usr/local/sbin/speedtest
chmod +x /usr/local/sbin/speedtest

# Setup limit IP & quota
cd /etc/systemd/system
wget -qO quota.service "https://raw.githubusercontent.com/zyanv/SCRIPT/main/SERVICE/quota.service"
wget -qO limit-ip-vless.service "https://raw.githubusercontent.com/zyanv/SCRIPT/main/SERVICE/limit-ip-vless.service"

systemctl daemon-reload
systemctl enable quota limit-ip-vless
systemctl restart quota limit-ip-vless
cd /root
log "Quota services configured"

# Fix Dropbear
pkill dropbear || true
systemctl restart dropbear

echo "clear ; menu" > /root/.profile

# Create swap
echo "Creating swap"
sh <(curl -fsSL https://raw.githubusercontent.com/zyanv/WARP/main/swap.sh)
echo "Swap created"

# Backup setup - aman, tanpa token hardcoded
curl -fsSL https://rclone.org/install.sh | bash
mkdir -p /root/.config/rclone
if [ ! -f /root/.config/rclone/rclone.conf ]; then
  cat > /root/.config/rclone/rclone.conf <<EOF
# Isi manual konfigurasi rclone di sini bila diperlukan
EOF
fi
log "Rclone installed"

# Setup UDP custom
bash <(curl -fsSL https://raw.githubusercontent.com/zyanv/WARP/main/udp.sh)

dos2unix /usr/local/sbin/menu-tweak || true

# Disable IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1

grep -q "net.ipv6.conf.all.disable_ipv6 = 1" /etc/sysctl.conf || cat >> /etc/sysctl.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

log "IPv6 disabled"

echo "Script success install"
rm -f /root/*.sh

reboot
