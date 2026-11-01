# RemnaNode + Selfsteal Installer

Самостоятельный интерактивный установщик RemnaNode и selfsteal-заглушки:

- RemnaNode в `network_mode: host`;
- capability `NET_ADMIN`;
- API ноды на `2222/tcp`;
- Xray Reality на стандартных портах профиля;
- selfsteal-заглушка Nginx на `127.0.0.1:9443`;
- автоматическая установка Certbot и выпуск сертификата Let's Encrypt;
- хранение сертификатов в `/etc/letsencrypt` с подключением в RemnaNode для Hysteria2;
- автоматическое продление сертификатов через `certbot.timer` и reload Nginx после обновления;
- logrotate, проверки DNS, портов и состояния сервисов.

Контейнер RemnaNode получает capability `NET_ADMIN`, необходимую для сетевых функций ноды. Полный режим `privileged` не используется.

## Требования

- чистый сервер Ubuntu или Debian с `systemd`;
- доступ `root` или `sudo`;
- домен с прямой A-записью на IP сервера, без CDN/proxy;
- входящий `80/tcp` доступен для Let's Encrypt;
- SECRET_KEY, скопированный при создании ноды в панели Remnawave.

## Пошаговая настройка

### 1. Подготовьте домен

Создайте прямую DNS-запись типа `A`:

```text
node.example.com → IPv4 вашего сервера
```

Отключите CDN и proxy-режим. Домен должен напрямую разрешаться в IP сервера. Если у домена есть запись `AAAA`, она также должна указывать на этот сервер, иначе её следует удалить.

Проверьте DNS:

```bash
dig +short A node.example.com
dig +short AAAA node.example.com
```

### 2. Создайте ноду в Remnawave

В панели Remnawave откройте раздел управления нодами и добавьте новую ноду:

1. Укажите публичный IPv4 сервера.
2. Укажите порт API ноды `2222`.
3. Скопируйте выданный панелью `SECRET_KEY` целиком.
4. Не публикуйте этот ключ и не сохраняйте его в GitHub.

### 3. Проверьте доступность портов

На уровне firewall хостинга должны быть доступны:

```text
80/tcp          Let's Encrypt HTTP-01
443/tcp+udp     основной Reality/Hysteria inbound
8443/tcp+udp    дополнительный inbound
11443/tcp       gRPC inbound
2222/tcp        API RemnaNode — только для IP панели
```

Если на сервере активен UFW, установщик добавит необходимые правила и запросит IP панели для ограничения `2222/tcp`.

### 4. Запустите установщик

```bash
curl -fsSL https://raw.githubusercontent.com/ddddddqqqq/remnanode-installer/main/install.sh | sudo bash
```

Введите:

1. Подготовленный домен selfsteal.
2. `SECRET_KEY` из панели — ввод будет скрыт.
3. IP панели, если установщик обнаружит активный UFW.

Скрипт автоматически установит Docker, Nginx, Certbot и RemnaNode, добавит контейнеру capability `NET_ADMIN`, выпустит сертификат, настроит автопродление и запустит сервисы.

### 5. Настройте Reality в профиле Xray

В используемом inbound укажите тот же домен и локальную selfsteal-заглушку:

```json
{
  "realitySettings": {
    "serverNames": ["node.example.com"],
    "dest": "127.0.0.1:9443",
    "xver": 0
  }
}
```

Значение `serverNames` должно полностью совпадать с доменом, введённым при установке.

### 6. Используйте сертификат в Hysteria2

Certbot сохраняет сертификат и приватный ключ в стандартном каталоге Let's Encrypt:

```text
/etc/letsencrypt/live/node.example.com/fullchain.pem
/etc/letsencrypt/live/node.example.com/privkey.pem
```

Каталог `/etc/letsencrypt` автоматически монтируется внутрь контейнера RemnaNode в режиме `read-only`, поэтому эти же пути можно указать в TLS-настройках inbound Hysteria2:

```json
{
  "tlsSettings": {
    "certificates": [
      {
        "certificateFile": "/etc/letsencrypt/live/node.example.com/fullchain.pem",
        "keyFile": "/etc/letsencrypt/live/node.example.com/privkey.pem"
      }
    ]
  }
}
```

Подставьте свой домен вместо `node.example.com`. Certbot будет автоматически продлевать сертификат, а deploy-hook перезагрузит Nginx после успешного обновления.

### 7. Завершите создание ноды

Назначьте ноде нужный Config Profile в панели и завершите создание. После передачи конфигурации в журнале должна появиться строка о запуске Xray Core.

Проверьте состояние:

```bash
cd /opt/remnanode
docker compose ps
docker compose logs --tail=100
curl -I https://node.example.com
```

Ожидаемый результат для selfsteal — `HTTP/1.1 200 OK` и заголовок `Server: nginx`.

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/ddddddqqqq/remnanode-installer/main/install.sh | sudo bash
```

Установщик читает домен и SECRET_KEY непосредственно из `/dev/tty`, поэтому интерактивный ввод работает даже при запуске через pipe. SECRET_KEY вводится скрыто.

Более безопасный вариант — сначала скачать и проверить скрипт:

```bash
curl -fsSLO https://raw.githubusercontent.com/ddddddqqqq/remnanode-installer/main/install.sh
less install.sh
sudo bash install.sh
```

## Что потребуется ввести

1. Домен selfsteal, например `node.example.com`.
2. SECRET_KEY ноды из панели Remnawave.
3. Если UFW активен — IP панели, которому будет разрешён доступ к `2222/tcp`.

Остальные компоненты устанавливаются и проверяются автоматически.

## Параметры

```text
--domain DOMAIN  передать домен аргументом
--yes            не задавать финальный вопрос подтверждения
--force          сохранить backup и заменить существующую установку
--help           показать справку
```

Дополнительные переменные окружения:

```bash
NODE_PORT=2222
SELF_STEAL_PORT=9443
REMNAWAVE_NODE_IMAGE=remnawave/node:latest
PANEL_IP=203.0.113.10
```

Пример:

```bash
curl -fsSL https://raw.githubusercontent.com/ddddddqqqq/remnanode-installer/main/install.sh \
  | sudo PANEL_IP=203.0.113.10 bash -s -- --domain node.example.com --yes
```

SECRET_KEY нельзя передавать аргументом командной строки: так он не попадает в shell history и список процессов.

## Настройки профиля Reality

После установки профиль Xray в панели должен содержать:

```json
{
  "realitySettings": {
    "serverNames": ["node.example.com"],
    "dest": "127.0.0.1:9443",
    "xver": 0
  }
}
```

Домен должен совпадать с введённым при установке.

## Файлы на сервере

```text
/opt/remnanode/docker-compose.yml
/opt/remnanode/.env
/etc/nginx/nginx.conf
/var/www/selfsteal/index.html
/etc/letsencrypt/live/DOMAIN/
/etc/letsencrypt/renewal-hooks/deploy/remnanode-selfsteal-nginx
/etc/logrotate.d/remnanode
```

`.env` создаётся с правами `0600`. Установщик не печатает SECRET_KEY в терминал.

В `docker-compose.yml` автоматически добавляется:

```yaml
cap_add:
  - NET_ADMIN
```

Сертификаты подключаются к контейнеру без права записи:

```yaml
volumes:
  - /etc/letsencrypt:/etc/letsencrypt:ro
```

## Диагностика

```bash
cd /opt/remnanode && docker compose ps
cd /opt/remnanode && docker compose logs -f -t
nginx -t
systemctl status nginx certbot.timer --no-pager
certbot certificates
ss -lntup | grep -E ':(443|2222|8443|9443|11443)\\b'
```

Проверка заглушки через Reality:

```bash
curl -I https://node.example.com
```

Ожидаемый результат — `HTTP/1.1 200 OK` и заголовок `Server: nginx`.

## Обновление RemnaNode

```bash
cd /opt/remnanode
docker compose pull
docker compose up -d
```

## Безопасность

- Ограничьте `2222/tcp` IP-адресом панели Remnawave. Это также рекомендует официальная документация Remnawave.
- Не публикуйте `/opt/remnanode/.env` и SECRET_KEY в GitHub.
- Перед запуском удалённого скрипта рекомендуется просмотреть его содержимое.
- `--force` предназначен только для осознанной замены существующей установки; файлы предварительно копируются в `/root/remnanode-installer-backups/`.

## Поддерживаемые системы

- Ubuntu x86_64/arm64;
- Debian x86_64/arm64.

Другие дистрибутивы установщик намеренно отклоняет.
