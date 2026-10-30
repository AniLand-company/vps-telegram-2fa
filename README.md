# vps-telegram-2fa

Один bash файл для 2FA на VPS.

Логика простая. Пароль подошел, скрипт шлет запрос в Telegram. Там две кнопки: пустить или не пустить. Пока кнопку не нажмешь, SSH дальше не пускает.

Если пароль неверный, бот молчит. Это норм, иначе от сканеров будет спам.

После установки защита выключена. Скрипт сначала только пишет удачные пароли в лог. Включать надо самому, после теста.

Что еще есть:

- user+IP запоминается на сутки после одобрения
- команды боту прямо в Telegram
- API на 99 порту, если надо срочно выключить или снести все
- если Telegram умер или токен битый, при FAIL_OPEN=1 вход пропустится и запишется в лог

Про FAIL_OPEN сразу честно. Это спасает от ситуации, когда сам себя закрыл снаружи. Но пока Telegram лежит, второго фактора по факту нет. Если надо жестко, ставь FAIL_OPEN=0.

## Что надо

Linux, root, systemd и PAM. У меня работает на Ubuntu. На другом Linux может тоже завестись, но смотреть надо по месту.

Из программ нужны bash, curl и flock. Для API нужен socat или ncat. При установке скрипт попробует сам поставить недостающее.

Один бот на один сервер. Не надо один токен пихать на две машины, они будут мешать друг другу. Webhook у бота должен быть выключен.

## Бот

1. Сделай бота через @BotFather.
2. Открой бота и нажми /start.
3. Узнай свой Telegram id. Можно через @userinfobot.
4. В начале vps-telegram-2fa.sh заполни вот это:

```bash
BOT_TOKEN="токен от BotFather"
CHAT_ID="твой id"
OWNER_USER_ID="твой id"
API_SECRET=""
```

В личном чате CHAT_ID и OWNER_USER_ID обычно одинаковые.

API_SECRET можно оставить пустым. При установке скрипт его сам сделает и покажет. Сразу сохрани его. Потом искать по файлам такое себе занятие.

Токен никому не показывай и заполненный файл в публичный репозиторий не лей.

## Установка

Закинь файл на сервер. Например в /root.

```bash
cd /root
sudo bash vps-telegram-2fa.sh install
sleep 3
sudo /usr/local/bin/vps-telegram-2fa.sh status
```

При установке скрипт копирует себя в /usr/local/bin, делает бэкап /etc/pam.d/sshd, добавляет туда строку PAM и создает две systemd службы.

Текущую SSH сессию не закрывай. Вообще. Пока все не проверишь.

Проверка:

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh validate
sudo /usr/local/bin/vps-telegram-2fa.sh test
```

В Telegram должно упасть тестовое сообщение. Жми разрешить. В консоли должен быть approved.

Еще напиши боту /ping. Если в ответ pong, служба бота жива.

## Включить и выключить

Когда тест прошел нормально:

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh enable
```

Теперь открой второй SSH и попробуй зайти. Первый терминал все еще не закрывай.

После одобрения пара user+IP запоминается на сутки. Поэтому следующий вход может пройти без кнопок. Это не баг, так задумано.

Если надо, чтоб спросил еще раз:

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh trust-clear
```

Выключить 2FA и оставить только лог:

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh disable
```

## Команды в консоли

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh status
sudo /usr/local/bin/vps-telegram-2fa.sh validate
sudo /usr/local/bin/vps-telegram-2fa.sh test
sudo /usr/local/bin/vps-telegram-2fa.sh enable
sudo /usr/local/bin/vps-telegram-2fa.sh disable
sudo /usr/local/bin/vps-telegram-2fa.sh logs 100
sudo /usr/local/bin/vps-telegram-2fa.sh trust-list
sudo /usr/local/bin/vps-telegram-2fa.sh trust-add root 203.0.113.10
sudo /usr/local/bin/vps-telegram-2fa.sh trust-clear
```

## Команды боту

Бот понимает /status, /on, /off, /test, /trust, /clear, /logs, /ping, /id, /help.

Чужих он слушать не должен. Работает только с владельцем и только в том чате, который указан в настройках.

## Логи

Основной лог:

```text
/var/log/vps-telegram-2fa.log
```

Смотреть так:

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh logs 100
sudo journalctl -u vps-telegram-2fa-bot -n 50 --no-pager
sudo journalctl -u vps-telegram-2fa-api -n 50 --no-pager
```

Служебные файлы лежат в /var/lib/vps-telegram-2fa. Руками туда без нужды лучше не лезть.

## API

API висит на 99 порту. Это обычный HTTP, без HTTPS.

Установщик сам порт в firewall не открывает. Если API нужен снаружи, открывай порт сам. Лучше только со своего IP.

Примеры:

```bash
curl http://SERVER:99/health
curl -H "Authorization: Bearer SECRET" http://SERVER:99/status
curl -X POST -H "Authorization: Bearer SECRET" http://SERVER:99/disable
```

Есть такие ручки:

```text
GET /health
GET /status
POST /enable
POST /disable
POST /clear-trusted
POST /uninstall
```

Удаление через API надо подтвердить:

```bash
curl -X POST \
  -H "Authorization: Bearer SECRET" \
  -H "Content-Type: application/json" \
  -d '{"confirm":"DELETE_VPS_TELEGRAM_2FA"}' \
  http://SERVER:99/uninstall
```

Если секрет потерял, он записан в начале установленного файла /usr/local/bin/vps-telegram-2fa.sh. Доступ туда только у root.

## Если не работает

Сначала смотри status, validate и лог. Чаще всего проблема в токене, chat id или в том, что bot служба не запустилась.

Старые кнопки после таймаута уже не сработают. Запусти test еще раз и жми новое сообщение.

Если вход проходит без Telegram, проверь две вещи. Может 2FA еще не включили. Или user+IP уже запомнен на сутки.

Если есть старая открытая сессия, самый быстрый откат вот:

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh disable
```

Если старой сессии нет, тогда консоль у хостера. Ну или API, если порт был открыт и секрет не потерялся.

## Удаление

```bash
sudo /usr/local/bin/vps-telegram-2fa.sh uninstall --yes
```

Сначала убирается PAM, потом службы и файлы. После удаления проверь обычный вход по SSH из нового окна.
