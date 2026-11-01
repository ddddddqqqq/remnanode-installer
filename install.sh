#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

INSTALLER_VERSION="1.0.0"
NODE_PORT="${NODE_PORT:-2222}"
SELF_STEAL_PORT="${SELF_STEAL_PORT:-9443}"
NODE_IMAGE="${REMNAWAVE_NODE_IMAGE:-remnawave/node:latest}"
FORCE=0
ASSUME_YES=0
DOMAIN=""
SECRET_KEY=""
PANEL_IP="${PANEL_IP:-}"
BACKUP_ROOT="/root/remnanode-installer-backups"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED=""
fi

usage() {
  cat <<'EOF'
RemnaNode + Selfsteal installer

Usage:
  sudo bash install.sh [options]

Options:
  --domain DOMAIN  Selfsteal/Reality domain (otherwise prompted)
  --yes            Do not ask for final confirmation
  --force          Back up and replace an existing RemnaNode/Nginx setup
  --help            Show this help

The node secret is intentionally accepted only through a hidden terminal prompt.

Optional environment variables:
  NODE_PORT=2222
  SELF_STEAL_PORT=9443
  REMNAWAVE_NODE_IMAGE=remnawave/node:latest
  PANEL_IP=203.0.113.10   Restrict TCP/2222 when UFW is active
EOF
}

log()  { printf '%s\n' "${C_BLUE}[$(date +%H:%M:%S)]${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
die()  { printf '%s\n' "${C_RED}Ошибка:${C_RESET} $*" >&2; exit 1; }

step() {
  local number="$1" title="$2"
  printf '\n%s\n' "${C_BOLD}${C_BLUE}Шаг ${number}/9 — ${title}${C_RESET}"
}

on_error() {
  local line="$1"
  printf '\n%s\n' "${C_RED}Установка остановлена на строке ${line}.${C_RESET}" >&2
  printf '%s\n' "Исправьте указанную выше ошибку и запустите установщик повторно." >&2
}
trap 'on_error "$LINENO"' ERR

tty_read() {
  local variable="$1" prompt_text="$2" hidden="${3:-0}" value=""
  [[ -r /dev/tty ]] || die "Нужен интерактивный терминал (/dev/tty)."
  if [[ "$hidden" == "1" ]]; then
    IFS= read -r -s -p "$prompt_text" value </dev/tty
    printf '\n' >/dev/tty
  else
    IFS= read -r -p "$prompt_text" value </dev/tty
  fi
  printf -v "$variable" '%s' "$value"
}

confirm() {
  local answer=""
  (( ASSUME_YES == 1 )) && return 0
  tty_read answer "Продолжить установку? [Y/n]: "
  [[ -z "$answer" || "$answer" =~ ^[YyДд]$ ]]
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_ip() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
}

port_owner() {
  local port="$1"
  ss -H -ltnp "sport = :${port}" 2>/dev/null || true
}

backup_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a --parents "$path" "$BACKUP_DIR"
}

write_file() {
  local target="$1" mode="$2"
  local temporary
  temporary="$(mktemp)"
  cat >"$temporary"
  install -D -m "$mode" "$temporary" "$target"
  rm -f "$temporary"
}

while (($#)); do
  case "$1" in
    --domain)
      [[ $# -ge 2 ]] || die "После --domain требуется значение."
      DOMAIN="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Неизвестный параметр: $1" ;;
  esac
done

printf '%s\n' "${C_BOLD}RemnaNode + Selfsteal Installer v${INSTALLER_VERSION}${C_RESET}"
printf '%s\n' "Схема: RemnaNode host network + NET_ADMIN + Nginx 127.0.0.1:${SELF_STEAL_PORT} + Certbot"

[[ "${EUID}" -eq 0 ]] || die "Запустите установщик от root: curl ... | sudo bash"
[[ -f /etc/os-release ]] || die "Не удалось определить операционную систему."
[[ "$NODE_PORT" =~ ^[0-9]+$ ]] && (( NODE_PORT >= 1 && NODE_PORT <= 65535 )) || die "Некорректный NODE_PORT: $NODE_PORT"
[[ "$SELF_STEAL_PORT" =~ ^[0-9]+$ ]] && (( SELF_STEAL_PORT >= 1 && SELF_STEAL_PORT <= 65535 )) || die "Некорректный SELF_STEAL_PORT: $SELF_STEAL_PORT"
[[ "$NODE_PORT" != "$SELF_STEAL_PORT" ]] || die "NODE_PORT и SELF_STEAL_PORT не могут совпадать."
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Поддерживаются Ubuntu и Debian. Обнаружено: ${ID:-unknown}." ;;
esac
command -v systemctl >/dev/null || die "Требуется systemd."
[[ "$(uname -m)" =~ ^(x86_64|aarch64|arm64)$ ]] || die "Неподдерживаемая архитектура: $(uname -m)."

if [[ -z "$DOMAIN" ]]; then
  tty_read DOMAIN "Домен selfsteal (например node.example.com): "
fi
DOMAIN="${DOMAIN,,}"
valid_domain "$DOMAIN" || die "Некорректный домен: $DOMAIN"

tty_read SECRET_KEY "Вставьте SECRET_KEY ноды из панели (ввод скрыт): " 1
[[ ${#SECRET_KEY} -ge 100 ]] || die "SECRET_KEY выглядит слишком коротким. Скопируйте ключ целиком из панели."
[[ "$SECRET_KEY" != *$'\n'* && "$SECRET_KEY" != *$'\r'* ]] || die "SECRET_KEY должен быть одной строкой."
[[ "$SECRET_KEY" != *[[:space:]]* ]] || die "SECRET_KEY не должен содержать пробелы."

if (( FORCE == 0 )); then
  if [[ -e /opt/remnanode/docker-compose.yml ]] || { command -v docker >/dev/null 2>&1 && docker inspect remnanode >/dev/null 2>&1; }; then
    die "Обнаружена существующая установка RemnaNode. Для её замены используйте --force."
  fi
  if [[ -e /etc/nginx/nginx.conf ]]; then
    die "Обнаружена существующая конфигурация Nginx. Для её резервного копирования и замены используйте --force."
  fi
fi

printf '\n%s\n' "${C_BOLD}Параметры установки:${C_RESET}"
printf '  Домен:             %s\n' "$DOMAIN"
printf '  API RemnaNode:      %s/tcp\n' "$NODE_PORT"
printf '  Selfsteal:          127.0.0.1:%s\n' "$SELF_STEAL_PORT"
printf '  Образ:              %s\n' "$NODE_IMAGE"
printf '  SECRET_KEY:         принят, %s символов\n' "${#SECRET_KEY}"
confirm || die "Отменено пользователем."

step 1 "Предварительные проверки"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg openssl python3 dnsutils jq nginx certbot logrotate

mapfile -t DOMAIN_IPV4 < <(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u)
(( ${#DOMAIN_IPV4[@]} > 0 )) || die "У домена $DOMAIN нет A-записи."
PUBLIC_IPV4="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
mapfile -t LOCAL_IPV4 < <(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}')
MATCHED=0
for dns_ip in "${DOMAIN_IPV4[@]}"; do
  [[ -n "$PUBLIC_IPV4" && "$dns_ip" == "$PUBLIC_IPV4" ]] && MATCHED=1
  for local_ip in "${LOCAL_IPV4[@]}"; do
    [[ "$dns_ip" == "$local_ip" ]] && MATCHED=1
  done
done
(( MATCHED == 1 )) || die "A-запись $DOMAIN (${DOMAIN_IPV4[*]}) не указывает на этот сервер (${PUBLIC_IPV4:-unknown})."

mapfile -t DOMAIN_IPV6 < <(getent ahostsv6 "$DOMAIN" | awk '{print $1}' | grep -v '^::ffff:' | sort -u || true)
if (( ${#DOMAIN_IPV6[@]} > 0 )); then
  mapfile -t LOCAL_IPV6 < <(ip -6 -o addr show scope global | awk '{split($4,a,"/"); print tolower(a[1])}')
  V6_MATCHED=0
  for dns_ip in "${DOMAIN_IPV6[@]}"; do
    for local_ip in "${LOCAL_IPV6[@]}"; do
      [[ "${dns_ip,,}" == "$local_ip" ]] && V6_MATCHED=1
    done
  done
  (( V6_MATCHED == 1 )) || die "AAAA-запись $DOMAIN указывает не на этот сервер. Исправьте или удалите её перед выпуском сертификата."
fi
ok "DNS домена указывает на сервер: ${DOMAIN_IPV4[*]}"

for port in 443 "$NODE_PORT" 8443 "$SELF_STEAL_PORT" 11443; do
  owner="$(port_owner "$port")"
  if [[ -n "$owner" ]]; then
    if (( FORCE == 0 )); then
      die "Порт $port уже занят: $owner"
    fi
    warn "Порт $port занят; --force разрешает заменить существующую установку."
  fi
done

step 2 "Установка Docker Engine и Compose"
if ! command -v docker >/dev/null 2>&1; then
  log "Docker не найден — запускаю официальный установщик get.docker.com."
  docker_script="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$docker_script"
  sh "$docker_script"
  rm -f "$docker_script"
fi
systemctl enable --now docker
docker compose version >/dev/null
ok "Docker $(docker --version | sed 's/^Docker version //')"

if (( FORCE == 1 )); then
  mkdir -p "$BACKUP_DIR"
  backup_path /opt/remnanode
  backup_path /var/www/selfsteal
  backup_path /etc/nginx/nginx.conf
  backup_path "/etc/letsencrypt/renewal/${DOMAIN}.conf"
  docker rm -f remnanode >/dev/null 2>&1 || true
  ok "Резервная копия существующих файлов: $BACKUP_DIR"
fi

step 3 "Настройка firewall"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp comment 'ACME HTTP-01'
  ufw allow 443/tcp comment 'Xray Reality TCP'
  ufw allow 443/udp comment 'Xray Reality UDP'
  ufw allow 8443/tcp comment 'Xray inbound TCP'
  ufw allow 8443/udp comment 'Xray inbound UDP'
  ufw allow 11443/tcp comment 'Xray gRPC TCP'
  if [[ -z "$PANEL_IP" ]]; then
    tty_read PANEL_IP "UFW активен. IP панели Remnawave для доступа к ${NODE_PORT}/tcp: "
  fi
  valid_ip "$PANEL_IP" || die "Некорректный IP панели: $PANEL_IP"
  ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave Panel to Node API'
  ok "UFW настроен; API ноды разрешён только для $PANEL_IP."
else
  warn "UFW не активен. Ограничьте ${NODE_PORT}/tcp адресом панели во внешнем firewall провайдера."
fi

step 4 "Выпуск сертификата Let's Encrypt"
systemctl stop nginx 2>/dev/null || true
if ss -H -ltn "sport = :80" | grep -q .; then
  die "Порт 80 занят. Освободите его для HTTP-01 проверки Let's Encrypt."
fi
if [[ -s "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" && -s "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]]; then
  log "Существующий сертификат найден — Certbot сохранит его, если продление пока не требуется."
fi
certbot certonly \
  --standalone \
  --preferred-challenges http \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --keep-until-expiring \
  --key-type ecdsa \
  -d "$DOMAIN"
openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -checkend 86400 >/dev/null
ok "Сертификат выпущен: $(openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -enddate | cut -d= -f2-)"

step 5 "Настройка selfsteal-заглушки Nginx"
backup_path /etc/nginx/nginx.conf
install -d -m 755 /var/www/selfsteal
write_file /var/www/selfsteal/index.html 0644 <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Welcome</title></head>
<body><main><h1>It works.</h1><p>The web server is running.</p></main></body>
</html>
EOF

write_file /etc/nginx/nginx.conf 0644 <<EOF
# Managed by remnanode-selfsteal-installer ${INSTALLER_VERSION}
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    access_log off;
    sendfile on;
    keepalive_timeout 65;
    ssl_protocols TLSv1.2 TLSv1.3;

    server {
        listen 127.0.0.1:${SELF_STEAL_PORT} ssl http2;
        server_name ${DOMAIN};

        ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        ssl_session_cache shared:selfsteal_tls:10m;
        ssl_session_timeout 1d;

        root /var/www/selfsteal;
        index index.html;

        location / {
            try_files \$uri \$uri/ /index.html;
        }
    }
}
EOF

write_file /etc/letsencrypt/renewal-hooks/deploy/remnanode-selfsteal-nginx 0755 <<EOF
#!/bin/sh
set -eu
if [ "\${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/${DOMAIN}" ]; then
    /usr/sbin/nginx -t
    /bin/systemctl reload nginx.service
fi
EOF

nginx -t
systemctl enable --now nginx
systemctl enable --now certbot.timer
curl -fsS --resolve "${DOMAIN}:${SELF_STEAL_PORT}:127.0.0.1" "https://${DOMAIN}:${SELF_STEAL_PORT}/" | grep -q 'It works.'
ok "Nginx отвечает на 127.0.0.1:${SELF_STEAL_PORT}; автопродление Certbot включено."

step 6 "Создание конфигурации RemnaNode с NET_ADMIN"
install -d -m 755 /opt/remnanode /var/log/remnanode
umask 077
{
  printf 'NODE_PORT=%s\n' "$NODE_PORT"
  printf 'SECRET_KEY=%s\n' "$SECRET_KEY"
} > /opt/remnanode/.env
chmod 600 /opt/remnanode/.env
unset SECRET_KEY
umask 022

write_file /opt/remnanode/docker-compose.yml 0644 <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE}
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    env_file:
      - .env
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
      - /tmp:/tmp
      - /var/log/remnanode:/var/log/supervisor
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: 50m
        max-file: "5"
EOF

write_file /etc/logrotate.d/remnanode 0644 <<'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

cd /opt/remnanode
docker compose config -q
ok "Compose и защищённый .env созданы в /opt/remnanode."

step 7 "Запуск RemnaNode"
docker compose pull
docker compose up -d --force-recreate
for _ in $(seq 1 30); do
  state="$(docker inspect -f '{{.State.Status}}' remnanode 2>/dev/null || true)"
  [[ "$state" == "running" ]] && break
  sleep 1
done
[[ "${state:-}" == "running" ]] || die "Контейнер RemnaNode не перешёл в состояние running."
ok "RemnaNode запущен."

step 8 "Проверка сервисов"
docker inspect remnanode --format '{{json .HostConfig.CapAdd}}' | grep -q 'CAP_NET_ADMIN'
docker inspect remnanode --format '{{.HostConfig.NetworkMode}}' | grep -qx 'host'
systemctl is-active --quiet nginx
systemctl is-active --quiet certbot.timer
ss -H -ltn "sport = :${NODE_PORT}" | grep -q . || warn "API ${NODE_PORT}/tcp ещё не слушается — проверьте логи контейнера."

if timeout 15 bash -c "until docker logs remnanode 2>&1 | grep -q 'Nest application successfully started'; do sleep 1; done"; then
  ok "API RemnaNode успешно запущен."
else
  warn "API ещё запускается. Проверьте: docker logs -f remnanode"
fi

if docker logs remnanode 2>&1 | grep -q 'XRay Core.*up and running'; then
  ok "Xray Core получил конфигурацию от панели и запущен."
else
  warn "Xray пока не получил профиль от панели — это нормально до подключения ноды в Remnawave."
fi

step 9 "Готово"
printf '%s\n' "${C_GREEN}${C_BOLD}Установка завершена.${C_RESET}"
printf '\nНастройки для профиля Xray Reality:\n'
printf '  serverNames: ["%s"]\n' "$DOMAIN"
printf '  dest:        "127.0.0.1:%s"\n' "$SELF_STEAL_PORT"
printf '  xver:        0\n'
printf '\nНастройки ноды в панели:\n'
printf '  Address:     %s\n' "${PUBLIC_IPV4:-${DOMAIN_IPV4[0]}}"
printf '  Port:        %s\n' "$NODE_PORT"
printf '  NET_ADMIN:   enabled\n'
printf '\nСертификаты Certbot для Hysteria2:\n'
printf '  Certificate: /etc/letsencrypt/live/%s/fullchain.pem\n' "$DOMAIN"
printf '  Private key: /etc/letsencrypt/live/%s/privkey.pem\n' "$DOMAIN"
printf '  Mount mode:  /etc/letsencrypt:ro\n'
printf '  Renewal:     certbot.timer enabled\n'
printf '\nПолезные команды:\n'
printf '  cd /opt/remnanode && docker compose logs -f -t\n'
printf '  nginx -t && systemctl status nginx --no-pager\n'
printf '  certbot certificates\n'
printf '\nSelfsteal URL: https://%s\n' "$DOMAIN"
if [[ -d "$BACKUP_DIR" ]]; then
  printf 'Резервная копия: %s\n' "$BACKUP_DIR"
fi

warn "Проверьте во внешнем firewall, что ${NODE_PORT}/tcp доступен только IP панели Remnawave."
