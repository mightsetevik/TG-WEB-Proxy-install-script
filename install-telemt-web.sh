#!/usr/bin/env bash
set -Eeuo pipefail

# Installs Telemt WEB mode behind Caddy on Debian/Ubuntu with systemd.
# Secrets are generated locally on the target host and never sent to a third party.

readonly TELEMT_REPO="telemt/telemt"
readonly TELEMT_USER="telemt"
readonly TELEMT_GROUP="telemt"
readonly TELEMT_CONFIG_DIR="/etc/telemt"
readonly TELEMT_CONFIG="/etc/telemt/telemt.toml"
readonly TELEMT_DATA_DIR="/var/lib/telemt"
readonly TELEMT_SITE_DIR="/srv/tproxy-site"
readonly TELEMT_SERVICE="telemt.service"
readonly CADDY_SERVICE="caddy.service"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly TELEMT_LISTEN="127.0.0.1:18080"
readonly API_LISTEN="127.0.0.1:9091"

DOMAIN=""
EMAIL=""
TELEMT_VERSION="3.5.7"
SSH_PORT="22"
PUBLIC_IP=""
FORCE=0
NON_INTERACTIVE=0

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Использование:
  sudo ./install-telemt-web.sh --domain proxy.example.com --email admin@example.com

Параметры:
  --domain NAME             Публичный FQDN WEB-прокси
  --email ADDRESS           Email для сертификата ACME
  --telemt-version VERSION  Версия релиза, по умолчанию: 3.5.7; latest для последней
  --ssh-port PORT           SSH-порт для UFW, по умолчанию: 22
  --public-ip ADDRESS       Публичный IPv4 для public_addr Telemt
  --non-interactive         Требовать domain и email в параметрах
  --force                   Заменить установку после резервного копирования
  -h, --help                Показать эту справку
EOF
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

parse_args() {
  while (($#)); do
    case "$1" in
      --domain)
        (($# >= 2)) || die "Для --domain требуется значение"
        DOMAIN="$2"; shift 2
        ;;
      --email)
        (($# >= 2)) || die "Для --email требуется значение"
        EMAIL="$2"; shift 2
        ;;
      --telemt-version)
        (($# >= 2)) || die "Для --telemt-version требуется значение"
        TELEMT_VERSION="$2"; shift 2
        ;;
      --ssh-port)
        (($# >= 2)) || die "Для --ssh-port требуется значение"
        SSH_PORT="$2"; shift 2
        ;;
      --public-ip)
        (($# >= 2)) || die "Для --public-ip требуется значение"
        PUBLIC_IP="$2"; shift 2
        ;;
      --non-interactive) NON_INTERACTIVE=1; shift ;;
      --force) FORCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный аргумент: $1" ;;
    esac
  done
}

require_root() {
  (( EUID == 0 )) || die "Запустите от root или через sudo"
  [[ -d /run/systemd/system ]] || die "Требуется systemd"
  [[ -r /etc/os-release ]] || die "Не удалось определить операционную систему"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == debian || "${ID:-}" == ubuntu || "${ID_LIKE:-}" == *debian* ]] || \
    die "Поддерживаются Debian и Ubuntu"
  [[ "${VERSION_CODENAME:-}" != "" || "${VERSION_ID:-}" != "" ]] || die "Не удалось прочитать данные ОС"
}

prompt_values() {
  if (( NON_INTERACTIVE )); then
    [[ -n "$DOMAIN" && -n "$EMAIL" ]] || die "В --non-interactive обязательны --domain и --email"
  else
    [[ -r /dev/tty ]] || die "Интерактивный режим требует TTY; используйте --domain и --email"
    if [[ -z "$DOMAIN" ]]; then
      printf 'Публичный домен: ' >/dev/tty
      IFS= read -r DOMAIN </dev/tty
      printf '\n' >/dev/tty
    fi
    if [[ -z "$EMAIL" ]]; then
      printf 'Email для ACME: ' >/dev/tty
      IFS= read -r EMAIL </dev/tty
      printf '\n' >/dev/tty
    fi
  fi
  valid_domain "$DOMAIN" || die "Недопустимый домен: $DOMAIN"
  valid_email "$EMAIL" || die "Недопустимый email: $EMAIL"
  valid_port "$SSH_PORT" || die "Недопустимый SSH-порт: $SSH_PORT"
  [[ "$TELEMT_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "Недопустимая версия Telemt"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Установка базовых зависимостей"
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl openssl tar gzip coreutils ufw gnupg debian-keyring debian-archive-keyring apt-transport-https
  if ! apt-cache show caddy >/dev/null 2>&1; then
    log "Добавление официального репозитория Caddy"
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      -o /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
  fi
  apt-get install -y -qq caddy
}

check_existing_install() {
  if (( FORCE )); then
    local backup_dir="/root/telemt-web-backup-$(date -u +%Y%m%d%H%M%S)"
    install -d -m 0700 "$backup_dir"
    [[ -e "$TELEMT_CONFIG_DIR" ]] && cp -a "$TELEMT_CONFIG_DIR" "$backup_dir/telemt-config"
    [[ -e "$CADDYFILE" ]] && cp -a "$CADDYFILE" "$backup_dir/Caddyfile"
    [[ -e "/etc/systemd/system/$TELEMT_SERVICE" ]] && cp -a "/etc/systemd/system/$TELEMT_SERVICE" "$backup_dir/telemt.service"
    log "Существующие файлы сохранены в $backup_dir"
    return
  fi
  if [[ -e "$TELEMT_CONFIG" || -e "$CADDYFILE" || -e "/etc/systemd/system/$TELEMT_SERVICE" ]]; then
    die "Найдена существующая конфигурация Telemt/Caddy. Для замены используйте --force осознанно."
  fi
}

detect_public_ip() {
  if [[ -n "$PUBLIC_IP" ]]; then
    [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "--public-ip должен быть IPv4"
    return
  fi
  PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
  [[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Не удалось определить публичный IPv4; используйте --public-ip"
}

check_dns() {
  log "Проверка DNS для $DOMAIN"
  getent ahostsv4 "$DOMAIN" >/dev/null 2>&1 || warn "Домен пока не разрешается через DNS; ACME может завершиться ошибкой"
  if getent ahostsv4 "$DOMAIN" | awk '{print $1}' | grep -qx "$PUBLIC_IP"; then
    return
  fi
  warn "$DOMAIN не указывает на определённый публичный IP $PUBLIC_IP"
  (( NON_INTERACTIVE )) && die "Исправьте DNS или передайте правильный --public-ip"
  read -r -p "Продолжить? [y/N] " answer </dev/tty
  [[ "$answer" == [yY] ]] || die "Операция отменена"
}

check_ports() {
  local port
  for port in 80 443; do
    if ss -Hlt "sport = :$port" 2>/dev/null | grep -q .; then
      die "TCP-порт $port уже занят"
    fi
  done
}

create_users_dirs() {
  getent group "$TELEMT_GROUP" >/dev/null || groupadd --system "$TELEMT_GROUP"
  id "$TELEMT_USER" >/dev/null 2>&1 || useradd --system --gid "$TELEMT_GROUP" --home-dir "$TELEMT_DATA_DIR" \
    --create-home --shell /usr/sbin/nologin "$TELEMT_USER"
  install -d -o "$TELEMT_USER" -g "$TELEMT_GROUP" -m 0750 "$TELEMT_DATA_DIR"
  install -d -o root -g "$TELEMT_GROUP" -m 0750 "$TELEMT_CONFIG_DIR"
  install -d -o root -g root -m 0755 "$TELEMT_SITE_DIR"
}

install_telemt() {
  local arch libc asset base_url archive checksum expected actual extracted
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
      *) die "Неподдерживаемая архитектура: $(uname -m)" ;;
  esac
  if [[ -e /lib/ld-musl-*.so.* ]] || grep -q '^ID=\("\)alpine\1' /etc/os-release 2>/dev/null; then
    libc="musl"
  else
    libc="gnu"
  fi
  if [[ "$TELEMT_VERSION" == latest ]]; then
    TELEMT_VERSION="$(curl -fsSL https://api.github.com/repos/$TELEMT_REPO/releases/latest \
      | awk -F'"' '/"tag_name"/ {print $4; exit}')"
    [[ -n "$TELEMT_VERSION" ]] || die "Не удалось определить последний релиз Telemt"
  fi
  TELEMT_VERSION="${TELEMT_VERSION#v}"
  asset="telemt-${arch}-linux-${libc}.tar.gz"
  base_url="https://github.com/$TELEMT_REPO/releases/download/$TELEMT_VERSION"
  archive="$(mktemp)"
  checksum="$(mktemp)"
  trap 'rm -f "$archive" "$checksum"' RETURN
  log "Загрузка Telemt $TELEMT_VERSION ($arch/$libc)"
  curl -fsSL --retry 3 "$base_url/$asset" -o "$archive"
  curl -fsSL --retry 3 "$base_url/$asset.sha256" -o "$checksum"
  expected="$(awk '{print $1; exit}' "$checksum")"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "Контрольная сумма архива Telemt не совпадает"
  extracted="$(mktemp -d)"
  tar -xzf "$archive" -C "$extracted"
  install -m 0755 "$(find "$extracted" -type f -name telemt -print -quit)" /usr/local/bin/telemt
  rm -rf "$extracted"
}

generate_secrets() {
  PROXY_SECRET="$(openssl rand -hex 16)"
  API_TOKEN="$(openssl rand -hex 32)"
}

write_site() {
  cat > "$TELEMT_SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Добро пожаловать</title><link rel="stylesheet" href="/styles.css"></head>
<body><main><p class="eyebrow">$DOMAIN</p><h1>Добро пожаловать</h1><p>Сайт находится в разработке.</p></main></body></html>
EOF
  cat > "$TELEMT_SITE_DIR/styles.css" <<'EOF'
:root{font-family:system-ui,sans-serif;color:#202124;background:#f7f8fa}body{margin:0;min-height:100vh;display:grid;place-items:center}main{max-width:38rem;padding:3rem}.eyebrow{color:#68707d;font-size:.8rem;letter-spacing:.12em;text-transform:uppercase}h1{font-size:clamp(2.5rem,8vw,5rem);margin:.2em 0}p{line-height:1.6;color:#59616d}
EOF
  chown -R root:root "$TELEMT_SITE_DIR"
  chmod 0755 "$TELEMT_SITE_DIR"
  chmod 0644 "$TELEMT_SITE_DIR"/*
}

write_telemt_config() {
  cat > "$TELEMT_CONFIG" <<EOF
[general]
data_path = "$TELEMT_DATA_DIR"
log_level = "normal"

[general.links]
show = ["web-user"]
public_host = "$DOMAIN"
public_port = 443

[server]
port = 18080

[server.api]
enabled = true
listen = "$API_LISTEN"
whitelist = ["127.0.0.1/32", "::1/128"]
auth_header = "Bearer $API_TOKEN"
read_only = true

[[server.listeners]]
ip = "127.0.0.1"
port = 18080
transport = "web"
proxy_protocol = false
reuse_allow = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["127.0.0.1/32"]

[access.users]
web-user = "$PROXY_SECRET"

[web]
enabled = true
carrier = "https"
http_connection_capacity_action = "wait"

[web.debug]
enabled = false
capture_headers = false

[[web.vhosts]]
host = "$DOMAIN"
public_addr = "$PUBLIC_IP:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "$TELEMT_SITE_DIR"
index = "index.html"

[[web.vhosts.profiles]]
user = "web-user"
secret_mode = "dd"
EOF
  chown root:"$TELEMT_GROUP" "$TELEMT_CONFIG"
  chmod 0640 "$TELEMT_CONFIG"
}

write_caddy_config() {
  install -d -o root -g root -m 0755 /etc/caddy
  cat > "$CADDYFILE" <<EOF
{
    email $EMAIL
    admin off
    servers {
        protocols h1 h2
    }
}

$DOMAIN {
    header {
        -Via
        -X-Powered-By
    }
    reverse_proxy $TELEMT_LISTEN {
        flush_interval -1
        header_up X-Forwarded-For {http.request.remote.host}
        transport http {
            response_header_timeout 65s
        }
    }
}
EOF
  chown root:root "$CADDYFILE"
  chmod 0644 "$CADDYFILE"
  caddy validate --config "$CADDYFILE"
}

write_systemd_unit() {
  cat > "/etc/systemd/system/$TELEMT_SERVICE" <<EOF
[Unit]
Description=Telemt MTProxy WEB proxy
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$TELEMT_USER
Group=$TELEMT_GROUP
WorkingDirectory=$TELEMT_DATA_DIR
ExecStart=/usr/local/bin/telemt $TELEMT_CONFIG
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$TELEMT_DATA_DIR
ProtectProc=invisible
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "/etc/systemd/system/$TELEMT_SERVICE"
}

configure_firewall() {
  ufw allow "$SSH_PORT/tcp" comment 'SSH' >/dev/null
  ufw allow 80/tcp comment 'HTTP' >/dev/null
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
  ufw --force enable >/dev/null
}

start_services() {
  systemctl daemon-reload
  systemctl enable --now "$TELEMT_SERVICE"
  systemctl enable --now "$CADDY_SERVICE"
  systemctl is-active --quiet "$TELEMT_SERVICE" || { journalctl -u "$TELEMT_SERVICE" -n 40 --no-pager; die "Telemt не запустился"; }
  systemctl is-active --quiet "$CADDY_SERVICE" || { journalctl -u "$CADDY_SERVICE" -n 40 --no-pager; die "Caddy не запустился"; }
}

print_result() {
  local secret_file="/root/telemt-web-credentials-$DOMAIN.txt"
  umask 077
  cat > "$secret_file" <<EOF
Установка Telemt WEB
Домен: $DOMAIN
Публичный адрес: $PUBLIC_IP:443
Режим секрета: dd
Секрет: $PROXY_SECRET
WEB-ссылка (Telegram Desktop WEB proxy): tg://webproxy?server=$DOMAIN&secret=dd$PROXY_SECRET
API-токен: $API_TOKEN
EOF
  chmod 0600 "$secret_file"
  cat <<EOF

Домен: $DOMAIN
Версия Telemt: $TELEMT_VERSION
Файл с реквизитами: $secret_file

Проверка сервисов:
  systemctl status telemt caddy
  journalctl -u telemt -f

WEB listener закрыт на loopback: $TELEMT_LISTEN; снаружи Caddy принимает TCP 80/443.

EOF
}

main() {
  parse_args "$@"
  require_root
  prompt_values
  check_existing_install
  install_packages
  # The package may start Caddy with its default configuration before ours is installed.
  systemctl stop "$CADDY_SERVICE" 2>/dev/null || true
  detect_public_ip
  check_dns
  check_ports
  create_users_dirs
  install_telemt
  generate_secrets
  write_site
  write_telemt_config
  write_caddy_config
  write_systemd_unit
  configure_firewall
  start_services
  print_result
}

main "$@"
