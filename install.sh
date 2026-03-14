#!/bin/bash
clear

# Update & install package
apt update
apt install wget curl openssl sudo binutils coreutils gnupg bc vnstat -y
apt install sudo -y
apt install htop lsof -y
apt install jq -y
apt install python3 -y

# Fix Multi Collor
apt install ruby -y
apt install lolcat -y
gem install lolcat

# Fix DNS
cat <(echo "nameserver 8.8.8.8") /etc/resolv.conf > /etc/resolv.conf.tmp && mv /etc/resolv.conf.tmp /etc/resolv.conf && cat <(echo "nameserver 1.1.1.1") /etc/resolv.conf > /etc/resolv.conf.tmp && mv /etc/resolv.conf.tmp /etc/resolv.conf

# Fix Port OpenSSH
cd /etc/ssh
find . -type f -name "*sshd_config*" -exec sed -i 's|#Port 22|Port 22|g' {} +
echo -e "Port 3303" >> sshd_config
cd
systemctl daemon-reload
systemctl restart ssh
systemctl restart sshd

# Make A Directory
mkdir -p /etc/xray/limit/ip/ssh
mkdir -p /etc/xray/limit/ip/vless
mkdir -p /etc/xray/limit/quota/ssh
mkdir -p /etc/xray/limit/database/ssh
mkdir -p /etc/xray/limit/database/vless
mkdir -p /etc/xray/usage/quta/vless
mkdir -p /etc/xray/recovery/ssh
mkdir -p /etc/xray/recovery/vless
mkdir -p /etc/xray/usage/quota/vless

# Copy Menu
cd /usr/local/sbin
apt update
apt install zip unzip -y
wget -qO menu.zip "https://raw.githubusercontent.com/zyanv/SCRIPT/main/file/main.zip"
unzip menu.zip
rm -f menu.zip
chmod +x *
cd

# Setup Firewall
systemctl stop ufw
systemctl disable ufw
apt purge ufw -y
apt autoremove -y
apt update
apt install iptables iptables-persistent -y
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
#iptables -L -v -n

# Setup Socks5 Proxy
apt install dante-server curl -y
touch /var/log/danted.log
chown root:root /var/log/danted.log
primary_interface=$(ip route | grep default | awk '{print $5}')
bash -c "cat <<EOF > /etc/danted.conf
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
EOF"
sed -i '/\[Service\]/a ReadWriteDirectories=/var/log' /usr/lib/systemd/system/danted.service
systemctl daemon-reload
systemctl restart danted
systemctl enable danted

# Set Data Domain Server
clear
echo -e "
+++++++++++++++++++++++++++++++++++++++++++++++++++++++
            INPUT DOMAIN FOR SERVER
+++++++++++++++++++++++++++++++++++++++++++++++++++++++
"

while true; do
    read -p "Input: " domain
    if [[ -n "$domain" ]]; then
        break
    read -p "Input: " email
    if [[ -n "$email" ]]; then
        break
    else
        echo -e "\e[31m[!] Domain tidak boleh kosong, silakan ulangi.\e[0m"
    fi
done

echo -e "\e[32m[OK]\e[0m Domain set -> $domain"

clear
echo -e "$domain" > /etc/xray/domain

# Install Dropbear
apt install dropbear -y
bash <(curl -s https://raw.githubusercontent.com/zyanv/WARP/main/dropbear.sh)
rm -f /etc/dropbear/dropbear_rsa_host_key
dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
rm -f /etc/dropbear/dropbear_dss_host_key
dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key
rm -f /etc/dropbear/dropbear_ecdsa_host_key
dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
cd /etc/default
rm -f dropbear
wget -qO dropbear "https://raw.githubusercontent.com/zyanv/SCRIPT/main/config/dropbear.conf"
echo "/bin/false" >> /etc/shells
echo "/usr/sbin/nologin" >> /etc/shells
echo -e "Dev @Rerechan02" > /etc/issue.net
clear
systemctl daemon-reload
/etc/init.d/dropbear restart
clear
cd /root
rm -fr dropbear*

# Install SSH WebSocket
cd /usr/local/bin
wget -qO ssh-ws "https://raw.githubusercontent.com/zyanv/SCRIPT/main/core/ssh-ws"
chmod +x ssh-ws
cd /etc/systemd/system
wget -qO ssh-ws.service "https://raw.githubusercontent.com/zyanv/SCRIPT/main/service/ssh-ws.service"
cd
systemctl daemon-reload
systemctl start ssh-ws.service
systemctl enable ssh-ws.service

# Install Xray
mkdir -p /usr/local/share/xray
wget -q -O /usr/local/share/xray/geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" >/dev/null 2>&1
wget -q -O /usr/local/share/xray/geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" >/dev/null 2>&1
chmod +x /usr/local/share/xray/*
wget -q -O /etc/xray/config.json "https://raw.githubusercontent.com/zyanv/SCRIPT/main/config/config.json"
cd /etc/xray
uuid=$(cat /proc/sys/kernel/random/uuid)
sed -i "s|xxxxx|${uuid}|g" /etc/xray/config.json
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u www-data --version 25.10.15

# Change Core Xray
cd /usr/local/bin
systemctl stop xray
systemctl disable xray
mv xray xray.bak
apt install zip -y
apt install unzip -y
wget -O xray.zip "https://raw.githubusercontent.com/zyanv/SCRIPT/main/core/xray.zip"
unzip xray.zip
chmod +x xray

# Fix Service Xray
cd /var/log
rm -r xray
mkdir -p xray
chown -R root:root /var/log/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chmod 644 /var/log/xray/*.log
cd /etc/systemd/system
rm -fr xray*
wget -qO xray.service "https://raw.githubusercontent.com/zyanv/SCRIPT/main/service/xray.service"
systemctl enable xray
systemctl start xray
systemctl restart xray

# Set
domain=$(cat /etc/xray/domain)

# Nginx & Certificate Setup
apt install socat -y
apt install lsof socat certbot -y
port=$(lsof -i:80 | awk '{print $1}')
systemctl stop apache2
systemctl disable apache2
pkill $port
yes Y | certbot certonly --standalone --preferred-challenges http --agree-tos --email $email -d $domain 
cp /etc/letsencrypt/live/$domain/fullchain.pem /etc/xray/xray.crt
cp /etc/letsencrypt/live/$domain/privkey.pem /etc/xray/xray.key
cd /etc/xray
chmod 644 /etc/xray/xray.key
chmod 644 /etc/xray/xray.crt

# Fix Cert if error
bash <(curl -Lks https://raw.githubusercontent.com/zyanv/WARP/main/cert)

# Setup Nginx
bash <(curl -s https://raw.githubusercontent.com/zyanv/WARP/main/nginx.sh)
systemctl stop nginx
wget -qO /etc/nginx/nginx.conf "https://raw.githubusercontent.com/zyanv/SCRIPT/main/config/nginx.conf"
sed -i "s|fn.com|${domain}|g" /etc/nginx/nginx.conf
systemctl daemon-reload
systemctl start nginx

# Setup Crontab
apt install cron -y

# Setup Auto Backup
echo "* * * * * root xp-ssh" >> /etc/crontab
echo "* * * * * root xp-vless" >> /etc/crontab
echo "0 * * * * root backup" >> /etc/crontab
echo "0 0 * * * root fixlog" >> /etc/crontab
echo "0 * * * * root cek-ssh" >> /etc/crontab
echo "0 * * * * root cek-vless" >> /etc/crontab

# restart service
systemctl daemon-reload
systemctl restart cron

# Install Package Lain
wget --no-check-certificate 'https://docs.google.com/uc?export=download&id=1vY2Cinutahu7x_zM8t5iGIHyUNo3PtgW' -O /usr/local/sbin/speedtest && chmod +x /usr/local/sbin/speedtest && sleep 0.5 && clear

# Setup Limit IP & Quota
cd /etc/systemd/system
wget -q https://raw.githubusercontent.com/zyanv/SCRIPT/main/service/quota.service
wget -q https://raw.githubusercontent.com/zyanv/SCRIPT/main/service/limit-ip-vless.service

systemctl daemon-reload
systemctl start quota limit-ip-vless
systemctl enable quota limit-ip-vless
cd

# Fix Dropbear
pkill dropbear
systemctl restart dropbear

clear
echo -e "clear ; menu" > /root/.profile

# Create Swap
echo -e "Creating Swap Ram"
sh <(curl -s https://raw.githubusercontent.com/zyanv/WARP/main/swap.sh)
echo -e "Success Create Swap Ram"

# Backup Setup
curl https://rclone.org/install.sh | bash
printf "q\n" | rclone config
rm -fr /root/.config/rclone/rclone.conf
cat > /root/.config/rclone/rclone.conf <<EOL
[rerechan]
type = drive
scope = drive
use_trash = false
metadata_owner = read,write
metadata_permissions = read,write
metadata_labels = read,write
token = {"access_token":"ya29.a0AZYkNZgbRJZcQjDt_mqZ6fyNmTfWkQYc8mzf6SyfR0Wk16YR3RUCuQf4hMol3izLaj43Q1R85EqCKNO0yrY2igEuactxcaZPhscBz1UJM8HhO5VT05Om4wG96mdVT4iyPQJ91vnIjr6tGMFGc6Ieh1-N4aYKOc-4dqY4xp0JaCgYKARcSARESFQHGX2MikSBSmHt3K5WTimMhqcm8jQ0175","token_type":"Bearer","refresh_token":"1//0gy_QhkW2lmAaCgYIARAAGBASNwF-L9Ircw-lb7lBdaev_Pq_ml4hZcnSJ1r4mHs3jnj4HFZ7e6a2RQPLAsJa1DBuHesE4MkVRbg","expiry":"2025-04-13T02:20:19.628115625Z"}


EOL
cd /root

# Setup UDP Custom
bash <(curl -s https://raw.githubusercontent.com/zyanv/WARP/main/udp.sh)
clear

apt install dos2unix -y ; dos2unix /usr/local/sbin/menu-tweak

# Disable IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1
echo -e "net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
sleep 2
clear

# Notification
echo -e " Script Success Install"
rm -fr *.sh

reboot
