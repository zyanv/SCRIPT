#!/usr/bin/env bash
set -Eeuo pipefail

# Xray VLESS WS + HTTPUpgrade installer for Debian 12
# Ports:
# - TLS 443 via Nginx -> Xray localhost 10000 WS /vless, 10002 HTTPUpgrade /hu
# - NonTLS 80/8080/8880 via Nginx -> Xray localhost 10001 WS /vless, 10003 HTTPUpgrade /hu
# - ACME without Cloudflare API token: HTTP-01 webroot validation, orange cloud must be OFF during issue/renew.

XRAY_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
MENU_BIN="/usr/local/bin/xray-menu"
ACME_DIR="/var/www/acme"
WEB_DIR="/var/www/html"
NGINX_SITE="/etc/nginx/sites-available/xray.conf"
NGINX_LINK="/etc/nginx/sites-enabled/xray.conf"
DOMAIN_FILE="$XRAY_DIR/domain"
USER_FILE="$XRAY_DIR/clients.json"
SOCKS_FILE="$XRAY_DIR/socks.env"
LOG_DIR="/var/log/xray"

red(){ echo -e "\e[31m$*\e[0m"; }
green(){ echo -e "\e[32m$*\e[0m"; }
yellow(){ echo -e "\e[33m$*\e[0m"; }
need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || { red "Sila run sebagai root."; exit 1; }; }

install_packages(){
  apt update -y
  apt install -y nginx curl wget unzip jq uuid-runtime socat cron ca-certificates lsb-release dnsutils openssl
  mkdir -p "$XRAY_DIR" "$LOG_DIR" "$ACME_DIR" "$WEB_DIR"
}

install_xray_binary(){
  local zip_src=""
  if [[ -f ./xray.linux.zip ]]; then
    zip_src="./xray.linux.zip"
  elif [[ -f /root/xray.linux.zip ]]; then
    zip_src="/root/xray.linux.zip"
  elif [[ -f /mnt/data/xray.linux.zip ]]; then
    zip_src="/mnt/data/xray.linux.zip"
  fi

  if [[ -n "$zip_src" ]]; then
    yellow "Install Xray dari fail: $zip_src"
    unzip -o "$zip_src" xray -d /tmp/xray-install >/dev/null
    install -m 755 /tmp/xray-install/xray "$XRAY_BIN"
    rm -rf /tmp/xray-install
  else
    yellow "Fail xray.linux.zip tidak jumpa. Download Xray release rasmi terbaru..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi
  "$XRAY_BIN" version | head -n 1 || true
}

ask_domain(){
  local domain
  read -rp "Masukkan domain/subdomain Cloudflare: " domain
  domain=${domain,,}
  [[ -n "$domain" ]] || { red "Domain kosong."; exit 1; }
  echo "$domain" > "$DOMAIN_FILE"
}

issue_cert(){
  local domain cert key
  domain=$(cat "$DOMAIN_FILE")
  cert="/etc/letsencrypt/live/$domain/fullchain.pem"
  key="/etc/letsencrypt/live/$domain/privkey.pem"
  mkdir -p /etc/letsencrypt/live/$domain "$ACME_DIR"

  cat > /etc/nginx/sites-available/00-acme.conf <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $domain;
    root $WEB_DIR;
    location /.well-known/acme-challenge/ { root $ACME_DIR; }
    location / { return 200 'ACME ready'; add_header Content-Type text/plain; }
}
EOF
  ln -sf /etc/nginx/sites-available/00-acme.conf /etc/nginx/sites-enabled/00-acme.conf
  nginx -t && systemctl restart nginx

  if [[ -s "$cert" && -s "$key" ]]; then
    green "Certificate sudah ada: $cert"
    return 0
  fi

  yellow "Nota: Cloudflare orange cloud/proxy mesti OFF/DNS only untuk ACME tanpa API token. Port 80 mesti terbuka."
  curl https://get.acme.sh | sh -s email=admin@$domain
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ~/.acme.sh/acme.sh --issue -d "$domain" -w "$ACME_DIR" --keylength ec-256
  ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
    --fullchain-file "$cert" \
    --key-file "$key" \
    --reloadcmd "systemctl reload nginx || true"
}

init_clients(){
  if [[ ! -s "$USER_FILE" ]]; then
    echo '[]' > "$USER_FILE"
  fi
}

read_socks(){
  SOCKS_ENABLE="off"; SOCKS_ADDR=""; SOCKS_PORT=""; SOCKS_USER=""; SOCKS_PASS=""
  [[ -f "$SOCKS_FILE" ]] && source "$SOCKS_FILE"
}

build_xray_config(){
  local clients tmp route outbound
  init_clients
  read_socks
  clients=$(cat "$USER_FILE")
  tmp=$(mktemp)

  if [[ "${SOCKS_ENABLE:-off}" == "on" && -n "${SOCKS_ADDR:-}" && -n "${SOCKS_PORT:-}" ]]; then
    outbound=$(jq -n --arg addr "$SOCKS_ADDR" --argjson port "$SOCKS_PORT" --arg user "$SOCKS_USER" --arg pass "$SOCKS_PASS" '
      [
        {"protocol":"socks","tag":"proxy","settings":{"servers":[{"address":$addr,"port":$port,"users":(if $user == "" then [] else [{"user":$user,"pass":$pass}] end)}]}},
        {"protocol":"freedom","tag":"direct"},
        {"protocol":"blackhole","tag":"block"}
      ]')
    route='[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"},{"type":"field","network":"tcp,udp","outboundTag":"proxy"}]'
  else
    outbound='[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]'
    route='[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]'
  fi

  jq -n --argjson clients "$clients" --argjson outbounds "$outbound" --argjson rules "$route" '
  {
    log: {loglevel:"warning", access:"/var/log/xray/access.log", error:"/var/log/xray/error.log"},
    inbounds: [
      {tag:"vless-ws-tls", listen:"127.0.0.1", port:10000, protocol:"vless", settings:{clients:$clients, decryption:"none"}, streamSettings:{network:"ws", wsSettings:{path:"/vless"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"]}},
      {tag:"vless-ws-nontls", listen:"127.0.0.1", port:10001, protocol:"vless", settings:{clients:$clients, decryption:"none"}, streamSettings:{network:"ws", wsSettings:{path:"/vless"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"]}},
      {tag:"vless-hu-tls", listen:"127.0.0.1", port:10002, protocol:"vless", settings:{clients:$clients, decryption:"none"}, streamSettings:{network:"httpupgrade", httpupgradeSettings:{path:"/hu"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"]}},
      {tag:"vless-hu-nontls", listen:"127.0.0.1", port:10003, protocol:"vless", settings:{clients:$clients, decryption:"none"}, streamSettings:{network:"httpupgrade", httpupgradeSettings:{path:"/hu"}}, sniffing:{enabled:true, destOverride:["http","tls","quic"]}}
    ],
    outbounds: $outbounds,
    routing: {domainStrategy:"IPIfNonMatch", rules:$rules}
  }' > "$tmp"
  install -m 644 "$tmp" "$XRAY_DIR/config.json"
  rm -f "$tmp"
}

build_nginx_config(){
  local domain cert key
  domain=$(cat "$DOMAIN_FILE")
  cert="/etc/letsencrypt/live/$domain/fullchain.pem"
  key="/etc/letsencrypt/live/$domain/privkey.pem"

  cat > "$NGINX_SITE" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen [::]:80;
    listen 8080;
    listen [::]:8080;
    listen 8880;
    listen [::]:8880;
    server_name $domain;
    root $WEB_DIR;

    location /.well-known/acme-challenge/ { root $ACME_DIR; }

    location = /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location = /hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / { return 200 'ok'; add_header Content-Type text/plain; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $domain;
    root $WEB_DIR;

    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    location = /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location = /hu {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location / { return 200 'ok'; add_header Content-Type text/plain; }
}
EOF
  rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/00-acme.conf
  ln -sf "$NGINX_SITE" "$NGINX_LINK"
  nginx -t
}

install_service(){
  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
NoNewPrivileges=true
ExecStart=$XRAY_BIN run -config $XRAY_DIR/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray nginx >/dev/null
  systemctl restart xray nginx
}

make_link(){
  local name uuid domain port tls path type security net
  name="$1"; uuid="$2"; domain="$3"; port="$4"; tls="$5"; path="$6"; type="$7"
  if [[ "$tls" == "tls" ]]; then security="tls&sni=$domain&fp=chrome"; else security="none"; fi
  if [[ "$type" == "hu" ]]; then net="httpupgrade"; else net="ws"; fi
  echo "vless://$uuid@$domain:$port?encryption=none&security=$security&type=$net&host=$domain&path=$path#$name-$type-$tls-$port"
}

show_user_links(){
  local name uuid domain
  name="$1"; uuid="$2"; domain=$(cat "$DOMAIN_FILE")
  echo
  green "Link untuk user: $name"
  make_link "$name" "$uuid" "$domain" 443 tls /vless ws
  make_link "$name" "$uuid" "$domain" 80 none /vless ws
  make_link "$name" "$uuid" "$domain" 8080 none /vless ws
  make_link "$name" "$uuid" "$domain" 8880 none /vless ws
  make_link "$name" "$uuid" "$domain" 443 tls /hu hu
  make_link "$name" "$uuid" "$domain" 80 none /hu hu
  make_link "$name" "$uuid" "$domain" 8080 none /hu hu
  make_link "$name" "$uuid" "$domain" 8880 none /hu hu
}

add_user(){
  init_clients
  local name uuid exists tmp
  read -rp "Nama user: " name
  [[ -n "$name" ]] || { red "Nama kosong."; return; }
  uuid=$(uuidgen)
  exists=$(jq -r --arg email "$name" '.[] | select(.email==$email) | .email' "$USER_FILE")
  [[ -z "$exists" ]] || { red "User sudah ada."; return; }
  tmp=$(mktemp)
  jq --arg id "$uuid" --arg email "$name" '. + [{id:$id,email:$email,flow:""}]' "$USER_FILE" > "$tmp"
  install -m 644 "$tmp" "$USER_FILE"; rm -f "$tmp"
  build_xray_config
  systemctl restart xray
  show_user_links "$name" "$uuid"
}

delete_user(){
  init_clients
  local name tmp
  jq -r '.[].email' "$USER_FILE" || true
  read -rp "Nama user untuk delete: " name
  tmp=$(mktemp)
  jq --arg email "$name" '[.[] | select(.email != $email)]' "$USER_FILE" > "$tmp"
  install -m 644 "$tmp" "$USER_FILE"; rm -f "$tmp"
  build_xray_config
  systemctl restart xray
  green "Selesai delete jika user wujud: $name"
}

list_users(){
  init_clients
  local domain
  domain=$(cat "$DOMAIN_FILE" 2>/dev/null || echo "DOMAIN")
  jq -r '.[] | "\(.email) \(.id)"' "$USER_FILE" | while read -r name uuid; do
    [[ -n "$name" ]] && show_user_links "$name" "$uuid"
  done
}

check_config(){
  echo "== Xray version =="; "$XRAY_BIN" version | head -n 3 || true
  echo "== Xray config test =="; "$XRAY_BIN" run -test -config "$XRAY_DIR/config.json" || true
  echo "== Nginx test =="; nginx -t || true
  echo "== Service status =="; systemctl --no-pager --full status xray nginx | sed -n '1,80p' || true
  echo "== Listening ports =="; ss -lntp | grep -E ':(80|443|8080|8880|10000|10001|10002|10003)\b' || true
}

set_socks_proxy(){
  echo "1) Enable route traffic Xray users melalui SOCKS5 VPS lain"
  echo "2) Disable SOCKS5 / direct internet"
  read -rp "Pilih [1-2]: " p
  if [[ "$p" == "1" ]]; then
    local addr port user pass
    read -rp "IP/domain SOCKS5 VPS lain: " addr
    read -rp "Port SOCKS5: " port
    read -rp "Username SOCKS5 kosong jika tiada: " user
    read -rsp "Password SOCKS5 kosong jika tiada: " pass; echo
    cat > "$SOCKS_FILE" <<EOF
SOCKS_ENABLE="on"
SOCKS_ADDR="$addr"
SOCKS_PORT="$port"
SOCKS_USER="$user"
SOCKS_PASS="$pass"
EOF
  else
    cat > "$SOCKS_FILE" <<EOF
SOCKS_ENABLE="off"
SOCKS_ADDR=""
SOCKS_PORT=""
SOCKS_USER=""
SOCKS_PASS=""
EOF
  fi
  build_xray_config
  systemctl restart xray
  green "Tetapan SOCKS5 dikemaskini."
}

renew_cert(){
  ~/.acme.sh/acme.sh --renew-all --force || true
  systemctl reload nginx || true
}

menu(){
  need_root
  while true; do
    clear
    echo "=============================="
    echo "       XRAY VLESS MENU        "
    echo "=============================="
    echo "Domain: $(cat "$DOMAIN_FILE" 2>/dev/null || echo '-')"
    echo "1) Add user"
    echo "2) Delete user"
    echo "3) List user/link"
    echo "4) Check config/status"
    echo "5) Set SOCKS5 outbound VPS lain"
    echo "6) Renew certificate"
    echo "7) Restart Xray + Nginx"
    echo "0) Exit"
    read -rp "Pilih: " c
    case "$c" in
      1) add_user; read -rp "Enter untuk menu..." _;;
      2) delete_user; read -rp "Enter untuk menu..." _;;
      3) list_users; read -rp "Enter untuk menu..." _;;
      4) check_config; read -rp "Enter untuk menu..." _;;
      5) set_socks_proxy; read -rp "Enter untuk menu..." _;;
      6) renew_cert; read -rp "Enter untuk menu..." _;;
      7) systemctl restart xray nginx; green "Restart selesai"; sleep 1;;
      0) exit 0;;
      *) red "Pilihan salah"; sleep 1;;
    esac
  done
}

install_all(){
  need_root
  install_packages
  install_xray_binary
  ask_domain
  init_clients
  issue_cert
  build_xray_config
  build_nginx_config
  install_service
  install -m 755 "$0" "$MENU_BIN"
  green "Install selesai. Buka menu dengan: xray-menu"
  echo "Tambah user pertama sekarang."
  add_user
}

case "${1:-menu}" in
  install) install_all ;;
  menu) menu ;;
  add-user) add_user ;;
  del-user) delete_user ;;
  list) list_users ;;
  check) check_config ;;
  socks) set_socks_proxy ;;
  *) echo "Usage: $0 {install|menu|add-user|del-user|list|check|socks}" ;;
esac
" _;;
      2) delete_user; read -rp "Enter untuk menu..." _;;
      3) list_users; read -rp "Enter untuk menu..." _;;
      4) check_config; read -rp "Enter untuk menu..." _;;
      5) set_socks_proxy; read -rp "Enter untuk menu..." _;;
      6) renew_cert; read -rp "Enter untuk menu..." _;;
      7) systemctl restart xray nginx; green "Restart selesai"; sleep 1;;
      0) exit 0;;
      *) red "Pilihan s
