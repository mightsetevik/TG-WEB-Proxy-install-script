# Установщик Telemt WEB

`install-telemt-web.sh` устанавливает Telemt WEB за Caddy на Debian/Ubuntu с systemd.

Скрипт:

- загружает закреплённую версию Telemt и проверяет SHA-256;
- создаёт отдельного непривилегированного пользователя `telemt`;
- генерирует новый секрет прокси и API-токен непосредственно на VPS;
- создаёт локальный сайт-заглушку на русском языке;
- получает TLS-сертификат через Caddy/Let's Encrypt;
- открывает во внешнем firewall только SSH, TCP `80` и TCP `443`;
- оставляет WEB listener и API Telemt доступными только через loopback;
- включает systemd-hardening для Telemt.

## Требования

- Debian или Ubuntu;
- systemd;
- архитектура `amd64` или `arm64`;
- root-доступ;
- домен, уже указывающий на VPS;
- свободные TCP-порты `80` и `443`.

## Установка

```bash
chmod +x install-telemt-web.sh
sudo ./install-telemt-web.sh \
  --domain proxy.example.com \
  --email admin@example.com
```

Интерактивный режим:

```bash
sudo ./install-telemt-web.sh
```

Последняя версия Telemt:

```bash
sudo ./install-telemt-web.sh \
  --domain proxy.example.com \
  --email admin@example.com \
  --telemt-version latest
```

После установки секрет, WEB-ссылка и API-токен сохраняются в root-only файле:

```text
/root/telemt-web-credentials-<домен>.txt
```

## Запуск Через GitHub

Публичный репозиторий можно запустить одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/mightsetevik/TG-WEB-Proxy-install-script/main/install-telemt-web.sh \
  | sudo bash -s -- \
    --domain proxy.example.com \
    --email admin@example.com
```

Безопаснее сначала скачать и просмотреть скрипт:

```bash
curl -fsSLO https://raw.githubusercontent.com/mightsetevik/TG-WEB-Proxy-install-script/main/install-telemt-web.sh
less install-telemt-web.sh
sudo bash install-telemt-web.sh --domain proxy.example.com --email admin@example.com
```

Не запускайте непроверенные удалённые скрипты с правами root. Для production лучше использовать URL конкретного проверенного commit или release tag, а не `main`.

## Проверка

```bash
systemctl status telemt caddy
journalctl -u telemt -f
```

Telemt слушает только `127.0.0.1:18080`, API — только `127.0.0.1:9091`. Публичный HTTPS принимает Caddy на TCP `443`.
