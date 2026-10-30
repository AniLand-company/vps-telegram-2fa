#!/usr/bin/env bash

set +e

VERSION="1.1.4"

BOT_TOKEN=""
CHAT_ID=""
OWNER_USER_ID=""

API_SECRET=""

API_BIND="0.0.0.0"
API_PORT="99"
APPROVAL_TIMEOUT_SECONDS="60"
TRUST_SECONDS="86400"
FAIL_OPEN="1"

BOT_TOKEN="${VPS_TELEGRAM_2FA_BOT_TOKEN:-$BOT_TOKEN}"
CHAT_ID="${VPS_TELEGRAM_2FA_CHAT_ID:-$CHAT_ID}"
OWNER_USER_ID="${VPS_TELEGRAM_2FA_OWNER_USER_ID:-$OWNER_USER_ID}"
API_SECRET="${VPS_TELEGRAM_2FA_API_SECRET:-$API_SECRET}"
API_BIND="${VPS_TELEGRAM_2FA_API_BIND:-$API_BIND}"
API_PORT="${VPS_TELEGRAM_2FA_API_PORT:-$API_PORT}"
APPROVAL_TIMEOUT_SECONDS="${VPS_TELEGRAM_2FA_APPROVAL_TIMEOUT:-$APPROVAL_TIMEOUT_SECONDS}"
TRUST_SECONDS="${VPS_TELEGRAM_2FA_TRUST_SECONDS:-$TRUST_SECONDS}"
FAIL_OPEN="${VPS_TELEGRAM_2FA_FAIL_OPEN:-$FAIL_OPEN}"

INSTALLED_FILE="${VPS_TELEGRAM_2FA_INSTALLED_FILE:-/usr/local/bin/vps-telegram-2fa.sh}"
PAM_FILE="${VPS_TELEGRAM_2FA_PAM_FILE:-/etc/pam.d/sshd}"
UNIT_FILE="${VPS_TELEGRAM_2FA_UNIT_FILE:-/etc/systemd/system/vps-telegram-2fa-api.service}"
UNIT_BOT_FILE="${VPS_TELEGRAM_2FA_BOT_UNIT_FILE:-/etc/systemd/system/vps-telegram-2fa-bot.service}"
STATE_DIR="${VPS_TELEGRAM_2FA_STATE_DIR:-/var/lib/vps-telegram-2fa}"
LOG_FILE="${VPS_TELEGRAM_2FA_LOG_FILE:-/var/log/vps-telegram-2fa.log}"
ENABLED_FILE="$STATE_DIR/enabled"
TRUSTED_FILE="$STATE_DIR/trusted.txt"
FAILED_AUTH_FILE="$STATE_DIR/api-failed-auth.txt"
STATE_LOCK_FILE="$STATE_DIR/state.lock"
TELEGRAM_LOCK_FILE="$STATE_DIR/telegram.lock"
PENDING_DIR="$STATE_DIR/pending"
BOT_HEARTBEAT_FILE="$STATE_DIR/bot-heartbeat"
BOT_OFFSET_FILE="$STATE_DIR/bot-offset"
SERVICE_NAME="vps-telegram-2fa-api.service"
BOT_SERVICE_NAME="vps-telegram-2fa-bot.service"
UNINSTALL_CONFIRM="DELETE_VPS_TELEGRAM_2FA"
NO_SYSTEMCTL="${VPS_TELEGRAM_2FA_NO_SYSTEMCTL:-0}"
TEST_MODE="${VPS_TELEGRAM_2FA_TEST_MODE:-0}"
LOG_DISABLED="0"
UNINSTALL_REMOVED="0"
UNINSTALL_OK="1"
PAM_BACKUP_FILE=""

SELF_PATH="$0"
case "$SELF_PATH" in
    */*) ;;
    *) SELF_PATH="$(command -v -- "$SELF_PATH" 2>/dev/null || printf '%s' "$SELF_PATH")" ;;
esac
if command -v readlink >/dev/null 2>&1; then
    _resolved="$(readlink -f -- "$SELF_PATH" 2>/dev/null)"
    [ -n "$_resolved" ] && SELF_PATH="$_resolved"
    unset _resolved
fi

case "$APPROVAL_TIMEOUT_SECONDS" in ''|*[!0-9]*) APPROVAL_TIMEOUT_SECONDS="60" ;; esac
if [ "$APPROVAL_TIMEOUT_SECONDS" -lt 1 ]; then APPROVAL_TIMEOUT_SECONDS="60"; fi
if [ "$APPROVAL_TIMEOUT_SECONDS" -gt 300 ]; then APPROVAL_TIMEOUT_SECONDS="300"; fi
case "$TRUST_SECONDS" in ''|*[!0-9]*) TRUST_SECONDS="86400" ;; esac
case "$API_PORT" in ''|*[!0-9]*) API_PORT="99" ;; esac
if [ "$API_PORT" -lt 1 ] || [ "$API_PORT" -gt 65535 ]; then API_PORT="99"; fi
case "$FAIL_OPEN" in 1|true|TRUE|yes|YES|on|ON) FAIL_OPEN="1" ;; *) FAIL_OPEN="0" ;; esac

sanitize() {
    printf '%s' "${1:-}" | tr '\n\r\t ' '____' | cut -c1-300
}

utc_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown-time'
}

log_event() {
    [ "$LOG_DISABLED" = "1" ] && return 0
    _event="$1"
    shift
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || return 0
    _line="$(utc_now) event=$_event"
    for _pair in "$@"; do
        _line="$_line $_pair"
    done
    printf '%s\n' "$_line" >>"$LOG_FILE" 2>/dev/null || true
    return 0
}

ensure_state() {
    mkdir -p "$STATE_DIR" "$PENDING_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || return 1
    touch "$TRUSTED_FILE" "$FAILED_AUTH_FILE" 2>/dev/null || return 1
    chmod 700 "$STATE_DIR" "$PENDING_DIR" 2>/dev/null || true
    chmod 600 "$TRUSTED_FILE" "$FAILED_AUTH_FILE" 2>/dev/null || true
    return 0
}

is_enabled() {
    [ -f "$ENABLED_FILE" ]
}

set_enabled() {
    ensure_state || return 1
    (
        flock -x 9 || exit 1
        if [ "$1" = "1" ]; then
            : >"$ENABLED_FILE"
            chmod 600 "$ENABLED_FILE" 2>/dev/null || true
        else
            rm -f "$ENABLED_FILE"
        fi
    ) 9>"$STATE_LOCK_FILE"
}

valid_ip() {
    _ip="$1"
    case "$_ip" in
        *:*)
            case "$_ip" in *[!0-9A-Fa-f:.]*) return 1 ;; *) return 0 ;; esac
            ;;
        *.*.*.*)
            _oldifs="$IFS"
            IFS='.'
            set -- $_ip
            IFS="$_oldifs"
            [ "$#" -eq 4 ] || return 1
            for _part in "$@"; do
                case "$_part" in ''|*[!0-9]*) return 1 ;; esac
                [ "${#_part}" -le 3 ] || return 1
                [ "$((10#$_part))" -le 255 ] || return 1
            done
            return 0
            ;;
        *) return 1 ;;
    esac
}

is_trusted() {
    _user="$1"
    _ip="$2"
    valid_ip "$_ip" || return 1
    ensure_state || return 1
    (
        flock -x 9 || exit 1
        _now="$(date '+%s' 2>/dev/null || printf '0')"
        _tmp="$(mktemp "$STATE_DIR/.trusted.XXXXXX" 2>/dev/null)" || exit 1
        _found="1"
        if [ -f "$TRUSTED_FILE" ]; then
            while IFS='|' read -r _u _i _exp || [ -n "${_u:-}" ]; do
                case "${_exp:-}" in ''|*[!0-9]*) continue ;; esac
                if [ "$_exp" -gt "$_now" ]; then
                    printf '%s|%s|%s\n' "$_u" "$_i" "$_exp" >>"$_tmp"
                    if [ "$_u" = "$_user" ] && [ "$_i" = "$_ip" ]; then _found="0"; fi
                fi
            done <"$TRUSTED_FILE"
        fi
        mv "$_tmp" "$TRUSTED_FILE" 2>/dev/null || exit 1
        chmod 600 "$TRUSTED_FILE" 2>/dev/null || true
        exit "$_found"
    ) 9>"$STATE_LOCK_FILE"
}

remember_trusted() {
    _user="$1"
    _ip="$2"
    valid_ip "$_ip" || return 1
    [ "$TRUST_SECONDS" -gt 0 ] || return 1
    ensure_state || return 1
    (
        flock -x 9 || exit 1
        _now="$(date '+%s' 2>/dev/null || printf '0')"
        _expires=$((_now + TRUST_SECONDS))
        _tmp="$(mktemp "$STATE_DIR/.trusted.XXXXXX" 2>/dev/null)" || exit 1
        if [ -f "$TRUSTED_FILE" ]; then
            while IFS='|' read -r _u _i _exp || [ -n "${_u:-}" ]; do
                case "${_exp:-}" in ''|*[!0-9]*) continue ;; esac
                if [ "$_exp" -gt "$_now" ] && ! { [ "$_u" = "$_user" ] && [ "$_i" = "$_ip" ]; }; then
                    printf '%s|%s|%s\n' "$_u" "$_i" "$_exp" >>"$_tmp"
                fi
            done <"$TRUSTED_FILE"
        fi
        printf '%s|%s|%s\n' "$_user" "$_ip" "$_expires" >>"$_tmp"
        mv "$_tmp" "$TRUSTED_FILE" 2>/dev/null || exit 1
        chmod 600 "$TRUSTED_FILE" 2>/dev/null || true
    ) 9>"$STATE_LOCK_FILE"
}

forget_trusted() {
    _user="$1"
    _ip="$2"
    ensure_state || return 1
    (
        flock -x 9 || exit 1
        _tmp="$(mktemp "$STATE_DIR/.trusted.XXXXXX" 2>/dev/null)" || exit 1
        if [ -f "$TRUSTED_FILE" ]; then
            while IFS='|' read -r _u _i _exp || [ -n "${_u:-}" ]; do
                if ! { [ "$_u" = "$_user" ] && [ "$_i" = "$_ip" ]; }; then
                    printf '%s|%s|%s\n' "$_u" "$_i" "${_exp:-0}" >>"$_tmp"
                fi
            done <"$TRUSTED_FILE"
        fi
        mv "$_tmp" "$TRUSTED_FILE" 2>/dev/null || exit 1
        chmod 600 "$TRUSTED_FILE" 2>/dev/null || true
    ) 9>"$STATE_LOCK_FILE"
}

clear_trusted() {
    ensure_state || return 1
    (
        flock -x 9 || exit 1
        : >"$TRUSTED_FILE"
        chmod 600 "$TRUSTED_FILE" 2>/dev/null || true
    ) 9>"$STATE_LOCK_FILE"
}

trusted_count() {
    _now="$(date '+%s' 2>/dev/null || printf '0')"
    [ -f "$TRUSTED_FILE" ] || { printf '0'; return 0; }
    awk -F'|' -v now="$_now" '$3 ~ /^[0-9]+$/ && $3 > now {c++} END {print c+0}' "$TRUSTED_FILE" 2>/dev/null || printf '0'
}

list_trusted() {
    ensure_state || return 1
    _now="$(date '+%s' 2>/dev/null || printf '0')"
    if [ ! -s "$TRUSTED_FILE" ]; then
        printf 'Список пуст.\n'
        return 0
    fi
    while IFS='|' read -r _u _i _exp || [ -n "${_u:-}" ]; do
        case "${_exp:-}" in ''|*[!0-9]*) continue ;; esac
        [ "$_exp" -gt "$_now" ] || continue
        _when="$(date -u -d "@$_exp" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'epoch %s' "$_exp")"
        printf '%s | %s | до %s\n' "$_u" "$_i" "$_when"
    done <"$TRUSTED_FILE"
}


tg_call() {
    _method="$1"
    shift
    curl -sS --max-time 15 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/${_method}" "$@"
}

tg_compact_json() {
    printf '%s' "$1" | tr -d '\r\n'
}

tg_ok() {
    case "$1" in
        *'"ok":true'*) return 0 ;;
        *) return 1 ;;
    esac
}

tg_max_update_id() {
    printf '%s' "$1" \
        | grep -o '"update_id":[0-9][0-9]*' 2>/dev/null \
        | sed 's/.*://' \
        | sort -n 2>/dev/null \
        | tail -n 1
}

tg_drain_old_updates() {
    _offset="0"
    _n="0"
    while [ "$_n" -lt 5 ]; do
        _n=$((_n + 1))
        _resp="$(tg_call getUpdates \
            --data-urlencode "offset=$_offset" \
            --data-urlencode "timeout=0" \
            --data-urlencode 'allowed_updates=["callback_query"]' 2>/dev/null)"
        tg_ok "$_resp" || return 1
        _max="$(tg_max_update_id "$_resp")"
        [ -n "$_max" ] || break
        _offset=$((_max + 1))
    done
    printf '%s' "$_offset"
}

tg_finalize_message() {
    [ -n "${1:-}" ] || return 0
    tg_call editMessageText \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "message_id=$1" \
        --data-urlencode "text=$2" >/dev/null 2>&1 || true
}

_perform_approval_locked() {
    _user="$1"
    _ip="$2"
    _test="${3:-0}"
    _owner_id="${OWNER_USER_ID:-$CHAT_ID}"

    command -v curl >/dev/null 2>&1 || return 3
    [ -n "$BOT_TOKEN" ] || return 3
    [ -n "$CHAT_ID" ] || return 3
    case "$_owner_id" in ''|*[!0-9-]*) return 3 ;; esac
    case "$CHAT_ID" in ''|*[!0-9-]*) return 3 ;; esac

    _resp="$(tg_call getMe 2>/dev/null)"
    tg_ok "$_resp" || return 3

    _offset="$(tg_drain_old_updates)" || return 3
    case "$_offset" in ''|*[!0-9]*) _offset="0" ;; esac

    _nonce="$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ "${#_nonce}" -eq 24 ] || return 3
    _test_label=""
    [ "$_test" = "1" ] && _test_label=" (тест)"
    _text="🔐 Подтвердите вход на VPS$_test_label
Пользователь: $_user
IP: $_ip
Сервер: $(hostname 2>/dev/null || printf 'unknown')
Время UTC: $(utc_now)

Если это не вы, нажмите «Отклонить» и смените пароль сервера."
    _keyboard="{\"inline_keyboard\":[[{\"text\":\"✅ Разрешить\",\"callback_data\":\"a:$_nonce\"},{\"text\":\"❌ Отклонить\",\"callback_data\":\"d:$_nonce\"}]]}"

    _resp="$(tg_call sendMessage \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$_text" \
        --data-urlencode "reply_markup=$_keyboard" 2>/dev/null)"
    tg_ok "$_resp" || return 3
    _message_id="$(printf '%s' "$_resp" | grep -o '"message_id":[0-9][0-9]*' | head -n 1 | sed 's/.*://')"

    _deadline=$(( $(date '+%s') + APPROVAL_TIMEOUT_SECONDS ))
    while [ "$(date '+%s')" -lt "$_deadline" ]; do
        _now="$(date '+%s')"
        _remaining=$((_deadline - _now))
        [ "$_remaining" -gt 0 ] || break
        _poll="5"
        [ "$_remaining" -lt 5 ] && _poll="$_remaining"
        _resp="$(tg_call getUpdates \
            --data-urlencode "offset=$_offset" \
            --data-urlencode "timeout=$_poll" \
            --data-urlencode 'allowed_updates=["callback_query"]' 2>/dev/null)"
        tg_ok "$_resp" || return 3

        _max="$(tg_max_update_id "$_resp")"
        [ -n "$_max" ] && _offset=$((_max + 1))

        _updates="$(tg_compact_json "$_resp" | sed 's/"update_id"/\n"update_id"/g')"
        _decision=""
        while IFS= read -r _update; do
            case "$_update" in
                *"\"data\":\"a:$_nonce\""*) _decision="approved" ;;
                *"\"data\":\"d:$_nonce\""*) _decision="denied" ;;
                *) continue ;;
            esac

            case "$_update" in
                *"\"from\":{\"id\":$_owner_id,"*) ;;
                *"\"from\":{\"id\":$_owner_id}"*) ;;
                *) _decision=""; continue ;;
            esac
            case "$_update" in
                *"\"chat\":{\"id\":$CHAT_ID,"*) ;;
                *"\"chat\":{\"id\":$CHAT_ID}"*) ;;
                *) _decision=""; continue ;;
            esac

            _callback_id="$(printf '%s' "$_update" | sed -n 's/.*"callback_query":{"id":"\([^"]*\)".*/\1/p' | head -n 1)"
            if [ -n "$_callback_id" ]; then
                if [ "$_decision" = "approved" ]; then _answer="Вход разрешён"; else _answer="Вход отклонён"; fi
                tg_call answerCallbackQuery \
                    --data-urlencode "callback_query_id=$_callback_id" \
                    --data-urlencode "text=$_answer" >/dev/null 2>&1 || true
            fi
            break
        done <<<"$_updates"

        if [ "$_decision" = "approved" ]; then
            tg_finalize_message "$_message_id" "$_text

✅ Решение: разрешено"
            return 0
        fi
        if [ "$_decision" = "denied" ]; then
            tg_finalize_message "$_message_id" "$_text

❌ Решение: отклонено"
            return 1
        fi
    done

    tg_finalize_message "$_message_id" "$_text

⌛ Решение: время истекло, вход отклонён."
    return 2
}

perform_approval_direct() {
    ensure_state || return 3
    (
        flock -w 2 -x 9 || exit 3
        _perform_approval_locked "$@"
    ) 9>"$TELEGRAM_LOCK_FILE"
}

bot_is_running() {
    [ -f "$BOT_HEARTBEAT_FILE" ] || return 1
    _hb="$(cat "$BOT_HEARTBEAT_FILE" 2>/dev/null)"
    case "${_hb:-}" in ''|*[!0-9]*) return 1 ;; esac
    _now="$(date '+%s' 2>/dev/null || printf '0')"
    _age=$((_now - _hb))
    [ "$_age" -ge 0 ] && [ "$_age" -le 45 ]
}

cleanup_pending() {
    rm -f "$PENDING_DIR/$1.req" "$PENDING_DIR/$1.sent" "$PENDING_DIR/$1.decision" 2>/dev/null || true
}

perform_approval_via_bot() {
    _user="$1"
    _ip="$2"
    _test="${3:-0}"
    ensure_state || return 3
    mkdir -p "$PENDING_DIR" 2>/dev/null || return 3
    [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || return 3

    _nonce="$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ "${#_nonce}" -eq 24 ] || return 3
    _type="ssh"
    [ "$_test" = "1" ] && _type="test"
    _now="$(date '+%s' 2>/dev/null || printf '0')"
    _expires=$((_now + APPROVAL_TIMEOUT_SECONDS))
    _req="$PENDING_DIR/$_nonce.req"
    _decision_file="$PENDING_DIR/$_nonce.decision"
    _tmp="$PENDING_DIR/.${_nonce}.$$"
    printf '%s\t%s\t%s\t%s\t%s\n' "$_nonce" "$_type" "$_user" "$_ip" "$_expires" >"$_tmp" 2>/dev/null || return 3
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$_req" 2>/dev/null || { rm -f "$_tmp"; return 3; }

    while [ "$(date '+%s')" -le "$_expires" ]; do
        if [ -f "$_decision_file" ]; then
            _decision="$(head -n 1 "$_decision_file" 2>/dev/null)"
            cleanup_pending "$_nonce"
            case "$_decision" in
                approved) return 0 ;;
                denied) return 1 ;;
                timeout) return 2 ;;
                *) return 3 ;;
            esac
        fi
        if ! bot_is_running; then
            cleanup_pending "$_nonce"
            return 3
        fi
        sleep 0.25 2>/dev/null || sleep 1
    done
    cleanup_pending "$_nonce"
    return 2
}

perform_approval() {
    if bot_is_running; then
        perform_approval_via_bot "$@"
        return "$?"
    fi
    perform_approval_direct "$@"
    return "$?"
}


pam_main() {
    exec 2>/dev/null
    _user="${PAM_USER:-$(id -un 2>/dev/null || printf 'unknown')}"
    _ip="${PAM_RHOST:-unknown}"

    if [ -n "${PAM_TYPE:-}" ] && [ "$PAM_TYPE" != "auth" ]; then
        return 0
    fi

    ensure_state || {
        log_event state_error_fail_open "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
        return 0
    }

    _enabled="0"
    is_enabled && _enabled="1"
    log_event password_success \
        "user=$(sanitize "$_user")" \
        "ip=$(sanitize "$_ip")" \
        "enabled=$_enabled" \
        "pam_service=$(sanitize "${PAM_SERVICE:-}")"

    if [ "$_enabled" != "1" ]; then
        log_event 2fa_skipped_disabled "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
        return 0
    fi

    if is_trusted "$_user" "$_ip"; then
        log_event 2fa_skipped_trusted_ip "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
        return 0
    fi

    log_event 2fa_requested "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
    perform_approval "$_user" "$_ip" "0"
    _rc="$?"
    case "$_rc" in
        0)
            remember_trusted "$_user" "$_ip" || true
            log_event 2fa_approved "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
            return 0
            ;;
        1)
            forget_trusted "$_user" "$_ip" || true
            log_event 2fa_denied "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
            return 1
            ;;
        2)
            log_event 2fa_timeout_denied "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
            return 1
            ;;
        3)
            if [ "$FAIL_OPEN" = "1" ]; then
                log_event 2fa_technical_error_fail_open "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
                return 0
            fi
            log_event 2fa_technical_error_denied "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
            return 1
            ;;
        *)
            log_event 2fa_unexpected_error_fail_open "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")" "rc=$_rc"
            return 0
            ;;
    esac
}


require_root() {
    if [ "$TEST_MODE" != "1" ] && [ "$(id -u 2>/dev/null || printf '1')" != "0" ]; then
        printf 'Эту команду нужно запускать через sudo/root\n' >&2
        return 1
    fi
    return 0
}

run_systemctl() {
    [ "$NO_SYSTEMCTL" = "1" ] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl "$@" >/dev/null 2>&1
}

ensure_dependencies() {
    _missing=""
    for _cmd in curl flock awk grep sed date od mktemp; do
        command -v "$_cmd" >/dev/null 2>&1 || _missing="$_missing $_cmd"
    done
    if ! command -v socat >/dev/null 2>&1 && ! command -v ncat >/dev/null 2>&1; then
        _missing="$_missing socat"
    fi
    [ -z "$_missing" ] && return 0

    printf 'Нужно доустановить зависимости:%s\n' "$_missing"
    if [ "$TEST_MODE" = "1" ] || [ "$(id -u 2>/dev/null || printf '1')" != "0" ]; then
        printf 'Автоматическая установка пропущена: нет root или включён тестовый режим.\n' >&2
        return 1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl socat util-linux ca-certificates
        return "$?"
    fi
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y curl socat util-linux ca-certificates
        return "$?"
    fi
    if command -v yum >/dev/null 2>&1; then
        yum install -y curl socat util-linux ca-certificates
        return "$?"
    fi
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl socat util-linux ca-certificates bash coreutils
        return "$?"
    fi
    printf 'Не найден apt/dnf/yum/apk; поставьте curl, socat и util-linux вручную.\n' >&2
    return 1
}

pam_line() {
    printf 'auth required pam_exec.so %s pam' "$INSTALLED_FILE"
}

pam_is_installed() {
    [ -f "$PAM_FILE" ] || return 1
    grep -Eq 'pam_exec\.so.*vps-telegram-2fa\.sh' "$PAM_FILE" 2>/dev/null
}

backup_pam() {
    PAM_BACKUP_FILE="${PAM_FILE}.bak.vps-telegram-2fa-$(date '+%Y%m%d%H%M%S')"
    cp -a "$PAM_FILE" "$PAM_BACKUP_FILE" 2>/dev/null || PAM_BACKUP_FILE=""
}

install_pam() {
    [ -f "$PAM_FILE" ] || { printf 'Файл PAM не найден: %s\n' "$PAM_FILE" >&2; return 1; }
    _tmp="$(mktemp)" || return 1
    _line="$(pam_line)"
    awk -v insert1='# vps-telegram-2fa: Telegram confirmation after successful password' -v insert2="$_line" '
        BEGIN { inserted = 0 }
        /pam_exec\.so/ && /vps-telegram-2fa\.sh/ { next }
        /^[[:space:]]*# vps-telegram-2fa/ { next }
        {
            print
            if (!inserted && ($0 ~ /^@include[[:space:]]+common-auth([[:space:]]|$)/ || $0 ~ /^auth[[:space:]]+(include|substack)[[:space:]]+(common-auth|password-auth|system-auth)([[:space:]]|$)/)) {
                print insert1
                print insert2
                inserted = 1
            }
        }
        END { exit(inserted ? 0 : 42) }
    ' "$PAM_FILE" >"$_tmp"
    _rc="$?"
    if [ "$_rc" -ne 0 ]; then
        rm -f "$_tmp"
        printf 'Не удалось найти common-auth/password-auth в PAM. PAM не изменён.\n' >&2
        printf 'Добавьте вручную ПОСЛЕ проверки пароля: %s\n' "$_line" >&2
        return 42
    fi
    backup_pam
    cat "$_tmp" >"$PAM_FILE" || { rm -f "$_tmp"; return 1; }
    rm -f "$_tmp"
    log_event pam_installed "backup=$(sanitize "$PAM_BACKUP_FILE")"
    return 0
}

remove_pam() {
    UNINSTALL_REMOVED="0"
    [ -f "$PAM_FILE" ] || return 0
    _tmp="$(mktemp)" || return 1
    _before="$(wc -l <"$PAM_FILE" 2>/dev/null | tr -d ' ')"
    grep -v -E 'pam_exec\.so.*vps-telegram-2fa\.sh|^[[:space:]]*# vps-telegram-2fa' "$PAM_FILE" >"$_tmp" 2>/dev/null
    _rc="$?"
    if [ "$_rc" -gt 1 ]; then
        rm -f "$_tmp"
        return 1
    fi
    _after="$(wc -l <"$_tmp" 2>/dev/null | tr -d ' ')"
    case "$_before:$_after" in *[!0-9:]*|'') _removed="0" ;; *) _removed=$((_before - _after)) ;; esac
    [ "$_removed" -lt 0 ] && _removed="0"
    UNINSTALL_REMOVED="$_removed"
    if [ "$_removed" -gt 0 ]; then
        backup_pam
        cat "$_tmp" >"$PAM_FILE" || { rm -f "$_tmp"; return 1; }
        log_event pam_lines_removed "count=$_removed"
    fi
    rm -f "$_tmp"
    return 0
}

extract_setting() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | head -n 1
}

patch_setting() {
    sed -i "0,/^$2=.*/s//${2}=\"$3\"/" "$1"
}

generate_secret() {
    od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

install_self() {
    require_root || return 1
    bash -n "$SELF_PATH" || { printf 'В скрипте есть синтаксическая ошибка; установка остановлена.\n' >&2; return 1; }
    ensure_dependencies || printf 'Продолжаю без части зависимостей: PAM по умолчанию останется в режиме логов, но Telegram/API могут не заработать до их установки.\n' >&2

    mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$INSTALLED_FILE")" "$(dirname "$UNIT_FILE")" || return 1
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    ensure_state || return 1

    _saved_bot_token="$BOT_TOKEN"
    [ -n "$_saved_bot_token" ] || _saved_bot_token="$(extract_setting "$INSTALLED_FILE" BOT_TOKEN)"
    _saved_chat_id="$CHAT_ID"
    [ -n "$_saved_chat_id" ] || _saved_chat_id="$(extract_setting "$INSTALLED_FILE" CHAT_ID)"
    _saved_owner_id="$OWNER_USER_ID"
    [ -n "$_saved_owner_id" ] || _saved_owner_id="$(extract_setting "$INSTALLED_FILE" OWNER_USER_ID)"

    _secret="$API_SECRET"
    if [ "${#_secret}" -lt 24 ]; then
        _secret="$(extract_setting "$INSTALLED_FILE" API_SECRET)"
    fi
    _generated="0"
    if [ "${#_secret}" -lt 24 ]; then
        _secret="$(generate_secret)"
        [ "${#_secret}" -ge 24 ] || { printf 'Не удалось сгенерировать секрет API.\n' >&2; return 1; }
        _generated="1"
    fi

    _tmp="$(mktemp "$(dirname "$INSTALLED_FILE")/.vps-telegram-2fa.XXXXXX")" || return 1
    cp "$SELF_PATH" "$_tmp" || { rm -f "$_tmp"; return 1; }
    [ -n "$_saved_bot_token" ] && patch_setting "$_tmp" BOT_TOKEN "$_saved_bot_token"
    [ -n "$_saved_chat_id" ] && patch_setting "$_tmp" CHAT_ID "$_saved_chat_id"
    [ -n "$_saved_owner_id" ] && patch_setting "$_tmp" OWNER_USER_ID "$_saved_owner_id"
    patch_setting "$_tmp" API_SECRET "$_secret" || { rm -f "$_tmp"; return 1; }
    bash -n "$_tmp" || { rm -f "$_tmp"; printf 'Проверка установленной копии не прошла.\n' >&2; return 1; }
    chmod 700 "$_tmp" || { rm -f "$_tmp"; return 1; }
    mv "$_tmp" "$INSTALLED_FILE" || return 1

    "$INSTALLED_FILE" status >/dev/null 2>&1 || {
        printf 'Установленная копия не прошла проверку status; PAM не изменён.\n' >&2
        return 1
    }

    cat >"$UNIT_FILE" <<EOF_UNIT
[Unit]
Description=Emergency API for Telegram SSH 2FA (single sh file)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$INSTALLED_FILE api
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 644 "$UNIT_FILE" 2>/dev/null || true

    cat >"$UNIT_BOT_FILE" <<EOF_BOT_UNIT
[Unit]
Description=Telegram command bot for SSH 2FA (single sh file)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=$INSTALLED_FILE bot
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF_BOT_UNIT
    chmod 644 "$UNIT_BOT_FILE" 2>/dev/null || true

    install_pam
    _pam_rc="$?"
    run_systemctl daemon-reload
    _api_rc="1"
    if run_systemctl enable "$SERVICE_NAME" && run_systemctl restart "$SERVICE_NAME"; then _api_rc="0"; fi
    _bot_rc="1"
    if [ -n "$_saved_bot_token" ] && [ -n "$_saved_chat_id" ]; then
        if run_systemctl enable "$BOT_SERVICE_NAME" && run_systemctl restart "$BOT_SERVICE_NAME"; then _bot_rc="0"; fi
    fi

    log_event installed "pam_rc=$_pam_rc" "api_started=$_api_rc" "bot_started=$_bot_rc"
    printf 'Установка завершена. По умолчанию 2FA ВЫКЛЮЧЕНА, работает только лог.\n'
    printf 'Установленный файл: %s\n' "$INSTALLED_FILE"
    [ -n "$PAM_BACKUP_FILE" ] && printf 'Резервная копия PAM: %s\n' "$PAM_BACKUP_FILE"
    if [ "$_generated" = "1" ]; then
        printf '\nСОХРАНИ СЕКРЕТ АВАРИЙНОГО API В МЕНЕДЖЕРЕ ПАРОЛЕЙ:\n%s\n' "$_secret"
    fi
    if [ "$_pam_rc" -ne 0 ]; then
        printf 'ВНИМАНИЕ: PAM автоматически не настроен (код %s). Смотри сообщение выше.\n' "$_pam_rc" >&2
    fi
    if [ "$_api_rc" -ne 0 ]; then
        printf 'ВНИМАНИЕ: API-служба не подтвердила запуск. journalctl -u %s -e\n' "$SERVICE_NAME" >&2
    fi
    if [ "$_bot_rc" -ne 0 ]; then
        printf 'ВНИМАНИЕ: Telegram-бот команд не подтвердила запуск. journalctl -u %s -e\n' "$BOT_SERVICE_NAME" >&2
    else
        printf 'Telegram-бот команд запущен. Напишите боту /start\n'
    fi
    printf 'Лог: %s\n' "$LOG_FILE"
    printf 'Тест: sudo vps-telegram-2fa.sh test\n'
    printf 'Включить: sudo vps-telegram-2fa.sh enable\n'
    printf 'Не закрывай текущую SSH-сессию, пока не проверишь второй вход.\n'
    printf 'Порт 99 установщик в файрволе сам не открывает.\n'
    [ "$_pam_rc" -eq 0 ]
}

uninstall_self() {
    require_root || return 1
    UNINSTALL_OK="1"
    remove_pam || UNINSTALL_OK="0"

    run_systemctl disable --now "$BOT_SERVICE_NAME" || true
    if [ "${2:-0}" = "1" ]; then
        run_systemctl disable --now "$SERVICE_NAME" || true
    else
        run_systemctl disable "$SERVICE_NAME" || true
    fi

    rm -f "$INSTALLED_FILE" 2>/dev/null || UNINSTALL_OK="0"
    rm -f "$UNIT_FILE" 2>/dev/null || UNINSTALL_OK="0"
    rm -f "$UNIT_BOT_FILE" 2>/dev/null || UNINSTALL_OK="0"

    case "$STATE_DIR" in
        ''|'/'|'/etc'|'/var'|'/usr'|'/home')
            UNINSTALL_OK="0"
            ;;
        *)
            rm -rf "$STATE_DIR" 2>/dev/null || UNINSTALL_OK="0"
            ;;
    esac

    if [ "${1:-1}" = "1" ]; then
        rm -f "$LOG_FILE" 2>/dev/null || UNINSTALL_OK="0"
    fi
    run_systemctl daemon-reload || true
    [ "$UNINSTALL_OK" = "1" ]
}


bot_touch_heartbeat() {
    _tmp="$BOT_HEARTBEAT_FILE.tmp.$$"
    printf '%s' "$(date '+%s' 2>/dev/null || printf '0')" >"$_tmp" 2>/dev/null || return 1
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$BOT_HEARTBEAT_FILE" 2>/dev/null || { rm -f "$_tmp"; return 1; }
}

bot_save_offset() {
    _tmp="$BOT_OFFSET_FILE.tmp.$$"
    printf '%s' "$1" >"$_tmp" 2>/dev/null || return 1
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$BOT_OFFSET_FILE" 2>/dev/null || { rm -f "$_tmp"; return 1; }
}

bot_write_decision() {
    mkdir -p "$PENDING_DIR" 2>/dev/null || return 1
    _tmp="$PENDING_DIR/.${1}.decision.$$"
    printf '%s\n' "$2" >"$_tmp" 2>/dev/null || return 1
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$PENDING_DIR/$1.decision" 2>/dev/null || { rm -f "$_tmp"; return 1; }
}

json_id_after() {
    printf '%s' "$1" \
        | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*.[[:space:]]*\"id\"[[:space:]]*:[[:space:]]*-?[0-9]+" \
        | head -n 1 \
        | grep -oE -- '-?[0-9]+$'
}

json_text_value() {
    printf '%s' "$1" | sed -nE 's/.*"text"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n 1
}

bot_send_text() {
    _resp="$(tg_call sendMessage \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$1" \
        --data-urlencode "disable_web_page_preview=true" 2>/dev/null)"
    if tg_ok "$_resp"; then
        return 0
    fi
    _desc="$(printf '%s' "$_resp" | sed -nE 's/.*"description"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n 1)"
    log_event bot_send_failed "error=$(sanitize "${_desc:-empty_or_invalid_response}")"
    return 1
}

bot_help_text() {
    cat <<'EOF_BOT_HELP'
Команды управления SSH-2FA:

/status — состояние защиты
/on — включить 2FA
/off — выключить 2FA, оставить только логи
/test — отправить тестовое подтверждение
/trust — запомненные пользователь+IP
/clear — очистить запомненные адреса
/logs — последние события входа
/ping — проверить связь с сервером
/id — показать Telegram ID
/help — эта справка

При входе по SSH я пришлю отдельное сообщение с кнопками «Разрешить» и «Отклонить».
EOF_BOT_HELP
}

bot_status_text() {
    _enabled="❌ выключена, работают только логи"
    is_enabled && _enabled="✅ включена"
    _pam="не установлена"
    pam_is_installed && _pam="установлена"
    _fail="при технической ошибке запрещать вход"
    [ "$FAIL_OPEN" = "1" ] && _fail="при технической ошибке пропускать вход (fail-open)"
    _api_state="неизвестно"
    if [ "$NO_SYSTEMCTL" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        _api_state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || printf 'не запущен')"
    fi
    printf 'Состояние SSH-2FA\n\nСервер: %s\nВерсия: %s\n2FA: %s\nPAM-строка: %s\nЗапомнено user+IP: %s\nРежим ошибок: %s\nAPI-порт: %s (%s)\nВремя UTC: %s' \
        "$(hostname 2>/dev/null || printf 'unknown')" \
        "$VERSION" "$_enabled" "$_pam" "$(trusted_count)" "$_fail" "$API_PORT" "$_api_state" "$(utc_now)"
}

bot_send_logs() {
    _logs="$(tail -n 15 "$LOG_FILE" 2>/dev/null)"
    if [ -z "$_logs" ]; then
        bot_send_text "Лог пока пуст."
        return 0
    fi
    _logs="$(printf '%s' "$_logs" | tail -c 3000)"
    bot_send_text "Последние события:

$_logs"
}

bot_approval_text() {
    _type="$1"
    _user="$2"
    _ip="$3"
    case "$_type" in
        test) _label=" (тест с сервера)" ;;
        bottest) _label=" (тест из Telegram)" ;;
        *) _label="" ;;
    esac
    printf '🔐 Подтвердите вход на VPS%s\nПользователь: %s\nIP: %s\nСервер: %s\nВремя UTC: %s\n\nЕсли это не вы, нажмите «Отклонить» и смените пароль сервера.' \
        "$_label" "$_user" "$_ip" "$(hostname 2>/dev/null || printf 'unknown')" "$(utc_now)"
}

bot_send_approval_message() {
    _nonce="$1"
    _type="$2"
    _user="$3"
    _ip="$4"
    _text="$(bot_approval_text "$_type" "$_user" "$_ip")"
    _keyboard="{\"inline_keyboard\":[[{\"text\":\"✅ Разрешить\",\"callback_data\":\"a:$_nonce\"},{\"text\":\"❌ Отклонить\",\"callback_data\":\"d:$_nonce\"}]]}"
    _resp="$(tg_call sendMessage \
        --data-urlencode "chat_id=$CHAT_ID" \
        --data-urlencode "text=$_text" \
        --data-urlencode "reply_markup=$_keyboard" 2>/dev/null)"
    tg_ok "$_resp" || return 1
    _message_id="$(printf '%s' "$_resp" | grep -o '"message_id":[0-9][0-9]*' | head -n 1 | sed 's/.*://')"
    [ -n "$_message_id" ] || return 1
    printf '%s' "$_message_id"
}

bot_write_sent() {
    mkdir -p "$PENDING_DIR" 2>/dev/null || return 1
    _tmp="$PENDING_DIR/.${1}.sent.$$"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >"$_tmp" 2>/dev/null || return 1
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$PENDING_DIR/$1.sent" 2>/dev/null || { rm -f "$_tmp"; return 1; }
}

bot_final_text() {
    _type="$1"
    _user="$2"
    _ip="$3"
    _result="$4"
    case "$_result" in
        approved) _mark="✅ Решение: разрешено" ;;
        denied) _mark="❌ Решение: отклонено" ;;
        *) _mark="⌛ Решение: время истекло" ;;
    esac
    printf '%s\n\n%s' "$(bot_approval_text "$_type" "$_user" "$_ip")" "$_mark"
}

bot_process_pending() {
    mkdir -p "$PENDING_DIR" 2>/dev/null || return 0
    _now="$(date '+%s' 2>/dev/null || printf '0')"

    for _req in "$PENDING_DIR"/*.req; do
        [ -e "$_req" ] || continue
        IFS="$(printf '\t')" read -r _nonce _type _user _ip _expires <"$_req" || continue
        case "${_nonce:-}" in ''|*[!0-9a-f]*) rm -f "$_req"; continue ;; esac
        [ "${#_nonce}" -eq 24 ] || { rm -f "$_req"; continue; }
        [ -f "$PENDING_DIR/$_nonce.decision" ] && continue
        case "${_expires:-}" in ''|*[!0-9]*) bot_write_decision "$_nonce" technical_error; continue ;; esac
        if [ "$_now" -gt "$_expires" ]; then
            bot_write_decision "$_nonce" timeout
            continue
        fi
        if [ ! -f "$PENDING_DIR/$_nonce.sent" ]; then
            _message_id="$(bot_send_approval_message "$_nonce" "$_type" "$_user" "$_ip")"
            if [ -z "${_message_id:-}" ]; then
                bot_write_decision "$_nonce" technical_error
                log_event bot_pending_send_failed "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")"
                continue
            fi
            bot_write_sent "$_nonce" "$_type" "$_user" "$_ip" "$_expires" "$_message_id" || bot_write_decision "$_nonce" technical_error
        fi
    done

    for _sent in "$PENDING_DIR"/*.sent; do
        [ -e "$_sent" ] || continue
        IFS="$(printf '\t')" read -r _nonce _type _user _ip _expires _message_id <"$_sent" || continue
        case "${_nonce:-}" in ''|*[!0-9a-f]*) rm -f "$_sent"; continue ;; esac
        [ -f "$PENDING_DIR/$_nonce.decision" ] && continue
        case "${_expires:-}" in ''|*[!0-9]*) continue ;; esac
        if [ "$_now" -gt "$_expires" ]; then
            tg_finalize_message "$_message_id" "$(bot_final_text "$_type" "$_user" "$_ip" timeout)"
            if [ "$_type" = "bottest" ]; then
                cleanup_pending "$_nonce"
            else
                bot_write_decision "$_nonce" timeout
            fi
        fi
    done
}

bot_answer_callback() {
    [ -n "${1:-}" ] || return 0
    tg_call answerCallbackQuery \
        --data-urlencode "callback_query_id=$1" \
        --data-urlencode "text=$2" >/dev/null 2>&1 || true
}

bot_handle_callback() {
    _update="$1"
    _data="$(printf '%s' "$_update" | sed -nE 's/.*"data"[[:space:]]*:[[:space:]]*"([ad]:[0-9a-f]*)".*/\1/p' | head -n 1)"
    case "$_data" in a:*|d:*) ;; *) return 0 ;; esac
    _prefix="${_data%%:*}"
    _nonce="${_data#*:}"
    _from_id="$(json_id_after "$_update" from)"
    _chat_id="$(json_id_after "$_update" chat)"
    _callback_id="$(printf '%s' "$_update" | sed -nE 's/.*"callback_query"[[:space:]]*:[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -n 1)"
    _owner_id="${OWNER_USER_ID:-$CHAT_ID}"

    if [ "$_from_id" != "$_owner_id" ] || [ "$_chat_id" != "$CHAT_ID" ]; then
        log_event bot_callback_ignored "from=$(sanitize "${_from_id:-empty}")" "chat=$(sanitize "${_chat_id:-empty}")" "expected_from=$(sanitize "$_owner_id")" "expected_chat=$(sanitize "$CHAT_ID")"
        bot_answer_callback "$_callback_id" "Недостаточно прав"
        return 0
    fi

    _sent="$PENDING_DIR/$_nonce.sent"
    if [ ! -f "$_sent" ]; then
        bot_answer_callback "$_callback_id" "Устаревший запрос"
        return 0
    fi
    IFS="$(printf '\t')" read -r _saved_nonce _type _user _ip _expires _message_id <"$_sent" || return 0
    _now="$(date '+%s' 2>/dev/null || printf '0')"
    if [ -n "${_expires:-}" ] && [ "$_now" -gt "$_expires" ]; then
        bot_answer_callback "$_callback_id" "Запрос истёк"
        tg_finalize_message "$_message_id" "$(bot_final_text "$_type" "$_user" "$_ip" timeout)"
        if [ "$_type" = "bottest" ]; then cleanup_pending "$_nonce"; else bot_write_decision "$_nonce" timeout; fi
        return 0
    fi

    if [ "$_prefix" = "a" ]; then _decision="approved"; else _decision="denied"; fi
    [ "$_type" = "bottest" ] || bot_write_decision "$_nonce" "$_decision"
    bot_answer_callback "$_callback_id" "$(if [ "$_decision" = "approved" ]; then printf 'Вход разрешён'; else printf 'Вход отклонён'; fi)"
    tg_finalize_message "$_message_id" "$(bot_final_text "$_type" "$_user" "$_ip" "$_decision")"
    log_event bot_callback "user=$(sanitize "$_user")" "ip=$(sanitize "$_ip")" "decision=$_decision" "type=$(sanitize "$_type")"
    [ "$_type" = "bottest" ] && cleanup_pending "$_nonce"
    return 0
}

bot_handle_message() {
    _update="$1"
    _from_id="$(json_id_after "$_update" from)"
    _chat_id="$(json_id_after "$_update" chat)"
    _owner_id="${OWNER_USER_ID:-$CHAT_ID}"
    _text="$(json_text_value "$_update")"
    _cmd="$(printf '%s' "$_text" | awk '{print $1}')"
    _cmd="${_cmd%%@*}"
    _cmd="$(printf '%s' "$_cmd" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"

    if [ "$_from_id" != "$_owner_id" ] || [ "$_chat_id" != "$CHAT_ID" ]; then
        log_event bot_message_ignored "from=$(sanitize "${_from_id:-empty}")" "chat=$(sanitize "${_chat_id:-empty}")" "expected_from=$(sanitize "$_owner_id")" "expected_chat=$(sanitize "$CHAT_ID")" "command=$(sanitize "${_cmd:-empty}")"
        return 0
    fi

    log_event bot_command "command=$(sanitize "${_cmd:-empty}")"

    case "$_cmd" in
        /start|/help)
            bot_send_text "$(bot_help_text)"
            ;;
        /ping)
            bot_send_text "pong
Сервер: $(hostname 2>/dev/null || printf 'unknown')
Время UTC: $(utc_now)"
            ;;
        /id)
            bot_send_text "Ваш user ID: $_from_id
Chat ID: $_chat_id"
            ;;
        /status)
            bot_send_text "$(bot_status_text)"
            ;;
        /on)
            if set_enabled 1; then
                log_event enabled_by_telegram
                bot_send_text "✅ Telegram-2FA включена."
            else
                bot_send_text "Не удалось включить 2FA. Проверьте журнал службы vps-telegram-2fa-bot."
            fi
            ;;
        /off)
            if set_enabled 0; then
                log_event disabled_by_telegram
                bot_send_text "❌ Telegram-2FA выключена. Продолжится только логирование успешных паролей."
            else
                bot_send_text "Не удалось выключить 2FA. Проверьте журнал службы vps-telegram-2fa-bot."
            fi
            ;;
        /test)
            _nonce="$(od -An -N12 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
            _now="$(date '+%s' 2>/dev/null || printf '0')"
            _expires=$((_now + APPROVAL_TIMEOUT_SECONDS))
            _message_id="$(bot_send_approval_message "$_nonce" bottest "telegram-test" "127.0.0.1")"
            if [ -n "${_message_id:-}" ]; then
                bot_write_sent "$_nonce" bottest "telegram-test" "127.0.0.1" "$_expires" "$_message_id" || bot_send_text "Не удалось зарегистрировать тестовый запрос."
            else
                bot_send_text "Не удалось отправить тестовый запрос."
            fi
            ;;
        /trust)
            _trusted="$(list_trusted 2>/dev/null)"
            bot_send_text "Запомненные пользователь+IP:

$_trusted"
            ;;
        /clear)
            if clear_trusted; then
                log_event trusted_cleared_by_telegram
                bot_send_text "Список запомненных пользователь+IP очищен."
            else
                bot_send_text "Не удалось очистить список запомненных адресов."
            fi
            ;;
        /logs)
            bot_send_logs
            ;;
        /*)
            bot_send_text "Неизвестная команда. Напишите /help"
            ;;
        *)
            ;;
    esac
    return 0
}

bot_process_update() {
    case "$1" in
        *'"callback_query"'*) bot_handle_callback "$1" ;;
        *'"message"'*) bot_handle_message "$1" ;;
        *) log_event bot_update_ignored "prefix=$(sanitize "$(printf '%s' "$1" | cut -c1-120)")" ;;
    esac
}

bot_set_commands() {
    _commands='[{"command":"start","description":"Справка"},{"command":"help","description":"Список команд"},{"command":"status","description":"Состояние защиты"},{"command":"on","description":"Включить 2FA"},{"command":"off","description":"Выключить 2FA"},{"command":"test","description":"Тестовое подтверждение"},{"command":"trust","description":"Доверенные IP"},{"command":"clear","description":"Очистить доверенные IP"},{"command":"logs","description":"Последние события"},{"command":"ping","description":"Проверка связи"},{"command":"id","description":"Мой Telegram ID"}]'
    _resp="$(tg_call setMyCommands --data-urlencode "commands=$_commands" 2>/dev/null)"
    tg_ok "$_resp"
}

bot_init_offset() {
    if [ -f "$BOT_OFFSET_FILE" ]; then
        _saved="$(cat "$BOT_OFFSET_FILE" 2>/dev/null)"
        case "${_saved:-}" in ''|*[!0-9]*) ;;
            *) printf '%s' "$_saved"; return 0 ;;
        esac
    fi
    _offset="0"
    _n="0"
    while [ "$_n" -lt 5 ]; do
        _n=$((_n + 1))
        _resp="$(tg_call getUpdates \
            --data-urlencode "offset=$_offset" \
            --data-urlencode "timeout=0" \
            --data-urlencode 'allowed_updates=["message","callback_query"]' 2>/dev/null)"
        tg_ok "$_resp" || return 1
        _max="$(tg_max_update_id "$_resp")"
        [ -n "$_max" ] || break
        _offset=$((_max + 1))
    done
    bot_save_offset "$_offset" || return 1
    printf '%s' "$_offset"
}

bot_main() {
    require_root || return 1
    command -v curl >/dev/null 2>&1 || { printf 'Для Telegram-бота нужен curl.\n' >&2; return 2; }
    _owner_id="${OWNER_USER_ID:-$CHAT_ID}"
    case "$BOT_TOKEN" in '') printf 'BOT_TOKEN не задан.\n' >&2; return 2 ;; esac
    case "$CHAT_ID" in ''|*[!0-9-]*) printf 'CHAT_ID должен быть числом.\n' >&2; return 2 ;; esac
    case "$_owner_id" in ''|*[!0-9-]*) printf 'OWNER_USER_ID должен быть числом.\n' >&2; return 2 ;; esac

    ensure_state || return 2
    exec 7>"$TELEGRAM_LOCK_FILE"
    if ! flock -n 7; then
        printf 'Telegram-бот уже запущен или сейчас идёт прямое подтверждение входа.\n' >&2
        return 2
    fi
    trap 'rm -f "$BOT_HEARTBEAT_FILE"; exit 0' INT TERM
    bot_touch_heartbeat || return 2

    if bot_set_commands; then
        log_event bot_commands_registered
    else
        log_event bot_commands_register_failed
        printf 'Не удалось зарегистрировать команды в Telegram; бот продолжит работу.\n' >&2
    fi
    bot_touch_heartbeat || true

    _offset="$(bot_init_offset)" || {
        printf 'Не удалось получить начальный offset Telegram.\n' >&2
        rm -f "$BOT_HEARTBEAT_FILE"
        return 2
    }
    log_event bot_started "offset=$_offset"
    printf 'vps-telegram-2fa bot %s started\n' "$VERSION"

    while true; do
        bot_touch_heartbeat || true
        bot_process_pending
        _resp="$(tg_call getUpdates \
            --data-urlencode "offset=$_offset" \
            --data-urlencode "timeout=2" \
            --data-urlencode 'allowed_updates=["message","callback_query"]' 2>/dev/null)"
        if ! tg_ok "$_resp"; then
            log_event bot_poll_error
            sleep 5
            bot_touch_heartbeat || true
            continue
        fi

        _updates="$(tg_compact_json "$_resp" | sed 's/"update_id"/\n"update_id"/g')"
        while IFS= read -r _update; do
            _update_id="$(printf '%s' "$_update" | sed -nE 's/.*"update_id"[[:space:]]*:[[:space:]]*([0-9]*).*/\1/p' | head -n 1)"
            case "${_update_id:-}" in ''|*[!0-9]*) continue ;; esac
            log_event bot_update_received "update_id=$_update_id"
            bot_process_update "$_update"
            _next_offset=$((_update_id + 1))
            if [ "$_next_offset" -gt "$_offset" ]; then
                _offset="$_next_offset"
                bot_save_offset "$_offset" || true
            fi
        done <<<"$_updates"
        bot_touch_heartbeat || true
    done
}


api_client_ip() {
    printf '%s' "${SOCAT_PEERADDR:-${NCAT_REMOTE_ADDR:-${NCAT_REMOTE_ADDRESS:-unknown}}}"
}

api_failed_count() {
    _ip="$1"
    _now="$(date '+%s' 2>/dev/null || printf '0')"
    [ -f "$FAILED_AUTH_FILE" ] || { printf '0'; return 0; }
    awk -F'|' -v now="$_now" -v ip="$_ip" '$1 ~ /^[0-9]+$/ && $2 == ip && now-$1 < 300 {c++} END {print c+0}' "$FAILED_AUTH_FILE" 2>/dev/null || printf '0'
}

api_record_failure() {
    ensure_state || return 0
    printf '%s|%s\n' "$(date '+%s')" "$1" >>"$FAILED_AUTH_FILE" 2>/dev/null || true
}

api_clear_failures() {
    _ip="$1"
    ensure_state || return 0
    (
        flock -x 9 || exit 0
        _tmp="$(mktemp "$STATE_DIR/.failed.XXXXXX" 2>/dev/null)" || exit 0
        awk -F'|' -v ip="$_ip" '$2 != ip' "$FAILED_AUTH_FILE" >"$_tmp" 2>/dev/null || true
        mv "$_tmp" "$FAILED_AUTH_FILE" 2>/dev/null || true
        chmod 600 "$FAILED_AUTH_FILE" 2>/dev/null || true
    ) 9>"$STATE_LOCK_FILE"
}

http_status_text() {
    case "$1" in
        200) printf 'OK' ;;
        400) printf 'Bad Request' ;;
        401) printf 'Unauthorized' ;;
        404) printf 'Not Found' ;;
        413) printf 'Payload Too Large' ;;
        429) printf 'Too Many Requests' ;;
        500) printf 'Internal Server Error' ;;
        503) printf 'Service Unavailable' ;;
        *) printf 'Status' ;;
    esac
}

http_json() {
    _status="$1"
    _body="$2"
    _length="$(printf '%s' "$_body" | wc -c | tr -d ' ')"
    printf 'HTTP/1.1 %s %s\r\n' "$_status" "$(http_status_text "$_status")"
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Content-Length: %s\r\n' "$_length"
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n\r\n'
    printf '%s' "$_body"
}

find_api_listener_pid() {
    _pid="$PPID"
    _found=""
    while [ -n "${_pid:-}" ] && [ "$_pid" -gt 1 ] 2>/dev/null; do
        if [ -r "/proc/$_pid/cmdline" ]; then
            _cmd="$(tr '\0' ' ' <"/proc/$_pid/cmdline" 2>/dev/null)"
            case "$_cmd" in
                *socat*TCP-LISTEN*|*ncat*' -l '*) _found="$_pid" ;;
            esac
            _next="$(awk '{print $4}' "/proc/$_pid/stat" 2>/dev/null)"
        else
            break
        fi
        case "${_next:-}" in ''|*[!0-9]*) break ;; esac
        [ "$_next" = "$_pid" ] && break
        _pid="$_next"
    done
    printf '%s' "${_found:-$PPID}"
}

schedule_api_stop() {
    _listener_pid="$(find_api_listener_pid)"
    (
        sleep 1
        kill -TERM "$_listener_pid" >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
}

api_request_main() {
    exec 2>/dev/null
    ensure_state || true
    _client="$(api_client_ip)"

    IFS=' ' read -r -t 5 _method _raw_path _http_version || return 0
    _path="${_raw_path%%\?*}"
    _content_length="0"
    _candidate=""

    while IFS= read -r -t 5 _line; do
        _line="${_line%$'\r'}"
        [ -z "$_line" ] && break
        _name="$(printf '%s' "${_line%%:*}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
        _value="${_line#*:}"
        _value="${_value# }"
        _value="${_value%$'\r'}"
        case "$_name" in
            content-length)
                case "$_value" in ''|*[!0-9]*) _content_length="0" ;; *) _content_length="$_value" ;; esac
                ;;
            authorization)
                _first7="$(printf '%s' "${_value:0:7}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
                [ "$_first7" = "bearer " ] && _candidate="${_value:7}"
                ;;
            x-api-key)
                [ -z "$_candidate" ] && _candidate="$_value"
                ;;
        esac
    done

    _body=""
    if [ "$_content_length" -gt 4096 ]; then
        http_json 413 '{"ok":false,"error":"request body is too large"}'
        return 0
    fi
    if [ "$_content_length" -gt 0 ]; then
        _body="$(dd bs=1 count="$_content_length" 2>/dev/null)"
    fi

    if [ "$_method" = "GET" ] && [ "$_path" = "/health" ]; then
        http_json 200 '{"ok":true}'
        return 0
    fi

    if [ "$(api_failed_count "$_client")" -ge 10 ]; then
        http_json 429 '{"ok":false,"error":"too many failed attempts"}'
        return 0
    fi
    if [ "${#API_SECRET}" -lt 24 ]; then
        http_json 503 '{"ok":false,"error":"API secret is not configured"}'
        return 0
    fi
    if [ -z "$_candidate" ] || [ "$_candidate" != "$API_SECRET" ]; then
        api_record_failure "$_client"
        log_event api_auth_failed "client=$(sanitize "$_client")"
        http_json 401 '{"ok":false,"error":"unauthorized"}'
        return 0
    fi
    api_clear_failures "$_client"

    if [ "$_method" = "GET" ] && [ "$_path" = "/status" ]; then
        _enabled='false'; is_enabled && _enabled='true'
        _pam='false'; pam_is_installed && _pam='true'
        _bot='false'; [ -n "$BOT_TOKEN" ] && _bot='true'
        _chat='false'; [ -n "$CHAT_ID" ] && _chat='true'
        _fail='false'; [ "$FAIL_OPEN" = "1" ] && _fail='true'
        _installed='false'; [ -f "$INSTALLED_FILE" ] && _installed='true'
        _bot_running='false'; bot_is_running && _bot_running='true'
        http_json 200 "{\"ok\":true,\"version\":\"$VERSION\",\"enabled\":$_enabled,\"pam_installed\":$_pam,\"bot_configured\":$_bot,\"bot_running\":$_bot_running,\"chat_configured\":$_chat,\"fail_open\":$_fail,\"trusted_count\":$(trusted_count),\"installed_file_exists\":$_installed,\"api_port\":$API_PORT}"
        return 0
    fi

    if [ "$_method" = "POST" ] && [ "$_path" = "/enable" ]; then
        set_enabled 1 || { http_json 500 '{"ok":false,"error":"cannot enable"}'; return 0; }
        log_event api_enabled "client=$(sanitize "$_client")"
        http_json 200 '{"ok":true,"enabled":true}'
        return 0
    fi
    if [ "$_method" = "POST" ] && [ "$_path" = "/disable" ]; then
        set_enabled 0 || { http_json 500 '{"ok":false,"error":"cannot disable"}'; return 0; }
        log_event api_disabled "client=$(sanitize "$_client")"
        http_json 200 '{"ok":true,"enabled":false}'
        return 0
    fi
    if [ "$_method" = "POST" ] && [ "$_path" = "/clear-trusted" ]; then
        clear_trusted || { http_json 500 '{"ok":false,"error":"cannot clear trusted"}'; return 0; }
        log_event api_trusted_cleared "client=$(sanitize "$_client")"
        http_json 200 '{"ok":true,"action":"trusted_cleared"}'
        return 0
    fi
    if [ "$_method" = "POST" ] && [ "$_path" = "/uninstall" ]; then
        _normalized="$(printf '%s' "$_body" | tr -d ' \t\r\n')"
        case "$_normalized" in
            *"\"confirm\":\"$UNINSTALL_CONFIRM\""*) ;;
            *)
                http_json 400 "{\"ok\":false,\"error\":\"JSON must contain confirm DELETE_VPS_TELEGRAM_2FA\"}"
                return 0
                ;;
        esac
        _delete_logs="1"
        case "$_normalized" in *'"delete_logs":false'*) _delete_logs="0" ;; esac
        uninstall_self "$_delete_logs" "0"
        _ok='false'; [ "$UNINSTALL_OK" = "1" ] && _ok='true'
        LOG_DISABLED="1"
        http_json 200 "{\"ok\":$_ok,\"action\":\"uninstall\",\"removed_pam_lines\":$UNINSTALL_REMOVED,\"message\":\"PAM removed first; API process will stop now\"}"
        schedule_api_stop
        return 0
    fi

    http_json 404 '{"ok":false,"error":"not found"}'
    return 0
}

run_api() {
    if [ "${#API_SECRET}" -lt 24 ]; then
        printf 'API_SECRET должен быть не короче 24 символов.\n' >&2
        return 2
    fi
    ensure_state || return 2
    log_event api_started "bind=$(sanitize "$API_BIND")" "port=$API_PORT"

    if command -v socat >/dev/null 2>&1; then
        exec socat "TCP-LISTEN:${API_PORT},bind=${API_BIND},reuseaddr,fork" "EXEC:${SELF_PATH} api-request"
    fi
    if command -v ncat >/dev/null 2>&1; then
        exec ncat -l "$API_BIND" "$API_PORT" --keep-open -c "$SELF_PATH api-request"
    fi

    printf 'Для API нужен socat или ncat. Запустите install от root, он попробует поставить socat.\n' >&2
    return 2
}


usage() {
    cat <<EOF_USAGE
vps-telegram-2fa.sh $VERSION — один .sh файл Telegram-2FA для SSH

Команды:
  install              установить файл, PAM-строку, API и Telegram-бота команд
  uninstall --yes      полностью удалить установку
  enable               включить Telegram-2FA
  disable              выключить 2FA, оставить только логи
  status               показать состояние
  validate             проверить токен Telegram
  test [--user U --ip IP --remember]
                       отправить тестовое подтверждение в Telegram
  trust-add USER IP    запомнить user+IP на $TRUST_SECONDS секунд
  trust-list           показать запомненные user+IP
  trust-clear          очистить запомненные user+IP
  logs [N]             показать последние N строк лога, по умолчанию 50
  api                  запустить API (обычно запускается через systemd)
  bot                  запустить Telegram-бота команд (обычно через systemd)
  pam                  точка входа PAM, вручную не запускать

Примеры:
  sudo bash vps-telegram-2fa.sh install
  sudo vps-telegram-2fa.sh test
  sudo vps-telegram-2fa.sh enable
  sudo vps-telegram-2fa.sh disable
EOF_USAGE
}

print_status() {
    _enabled='ВЫКЛЮЧЕНА, только логи'
    is_enabled && _enabled='ВКЛЮЧЕНА'
    _pam='нет'; pam_is_installed && _pam='да'
    _bot='нет'; [ -n "$BOT_TOKEN" ] && _bot='да'
    _chat='нет'; [ -n "$CHAT_ID" ] && _chat='да'
    _secret='нет'; [ "${#API_SECRET}" -ge 24 ] && _secret='да'
    _installed='нет'; [ -f "$INSTALLED_FILE" ] && _installed='да'
    _fail='запрещать вход'; [ "$FAIL_OPEN" = "1" ] && _fail='пропускать вход (fail-open)'
    printf 'Версия: %s\n' "$VERSION"
    printf 'Текущий файл: %s\n' "$SELF_PATH"
    printf 'Установленный файл: %s (%s)\n' "$INSTALLED_FILE" "$_installed"
    printf '2FA: %s\n' "$_enabled"
    printf 'PAM-строка установлена: %s\n' "$_pam"
    printf 'Токен бота задан: %s\n' "$_bot"
    printf 'Chat ID задан: %s\n' "$_chat"
    _bot_running='нет'; bot_is_running && _bot_running='да'
    printf 'Telegram-бот команд запущен: %s\n' "$_bot_running"
    printf 'Секрет API задан: %s\n' "$_secret"
    printf 'API: %s:%s\n' "$API_BIND" "$API_PORT"
    printf 'Тайм-аут Telegram: %s сек\n' "$APPROVAL_TIMEOUT_SECONDS"
    printf 'Запоминание user+IP: %s сек\n' "$TRUST_SECONDS"
    printf 'Запомнено user+IP: %s\n' "$(trusted_count)"
    printf 'При технической ошибке: %s\n' "$_fail"
    printf 'Лог: %s\n' "$LOG_FILE"
}

cli_test() {
    _test_user="$(id -un 2>/dev/null || printf 'test')"
    _test_ip="127.0.0.1"
    _remember="0"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --user) shift; _test_user="${1:-$_test_user}" ;;
            --ip) shift; _test_ip="${1:-$_test_ip}" ;;
            --remember) _remember="1" ;;
            *) printf 'Неизвестный параметр test: %s\n' "$1" >&2; return 2 ;;
        esac
        shift
    done
    perform_approval "$_test_user" "$_test_ip" "1"
    _rc="$?"
    case "$_rc" in
        0)
            printf 'Результат: approved\n'
            if [ "$_remember" = "1" ]; then
                remember_trusted "$_test_user" "$_test_ip" && printf 'User+IP запомнен.\n'
            fi
            return 0
            ;;
        1) printf 'Результат: denied\n'; return 1 ;;
        2) printf 'Результат: timeout\n'; return 1 ;;
        *)
            printf 'Результат: техническая ошибка (токен, chat_id, сеть или Telegram).\n' >&2
            printf 'При FAIL_OPEN=1 настоящий SSH-вход был бы пропущен и записан в лог.\n' >&2
            return 2
            ;;
    esac
}

main() {
    _cmd="${1:-help}"
    case "$_cmd" in
        pam)
            pam_main
            return "$?"
            ;;
        api)
            run_api
            return "$?"
            ;;
        bot)
            bot_main
            return "$?"
            ;;
        api-request)
            api_request_main
            return 0
            ;;
        install)
            install_self
            return "$?"
            ;;
        uninstall)
            if [ "${2:-}" != "--yes" ]; then
                printf 'Для подтверждения: sudo vps-telegram-2fa.sh uninstall --yes\n' >&2
                return 2
            fi
            uninstall_self 1 1
            _rc="$?"
            printf 'Удалено строк PAM: %s\n' "$UNINSTALL_REMOVED"
            printf 'Проверь новый SSH-вход из второго терминала, не закрывая текущую сессию.\n'
            return "$_rc"
            ;;
        enable)
            require_root || return 1
            set_enabled 1 || return 1
            log_event enabled_by_cli
            printf '2FA включена.\n'
            _resp="$(tg_call getMe 2>/dev/null)"
            if tg_ok "$_resp"; then
                _bot_name="$(printf '%s' "$_resp" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -n 1)"
                printf 'Telegram-токен работает%s\n' "${_bot_name:+: $_bot_name}"
            else
                printf 'ВНИМАНИЕ: Telegram/токен сейчас не работает; при FAIL_OPEN=1 вход будет пропускаться.\n' >&2
            fi
            return 0
            ;;
        disable)
            require_root || return 1
            set_enabled 0 || return 1
            log_event disabled_by_cli
            printf '2FA выключена. Осталось логирование успешных паролей.\n'
            return 0
            ;;
        status)
            print_status
            return 0
            ;;
        validate)
            _resp="$(tg_call getMe 2>/dev/null)"
            if tg_ok "$_resp"; then
                _bot_name="$(printf '%s' "$_resp" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -n 1)"
                printf 'OK: бот %s\n' "${_bot_name:-без username}"
                return 0
            fi
            printf 'Telegram-токен не работает или сеть недоступна.\n' >&2
            return 2
            ;;
        test)
            shift
            cli_test "$@"
            return "$?"
            ;;
        trust-add)
            require_root || return 1
            [ "$#" -eq 3 ] || { printf 'Использование: trust-add USER IP\n' >&2; return 2; }
            valid_ip "$3" || { printf 'Нужен корректный IP.\n' >&2; return 2; }
            remember_trusted "$2" "$3" && printf 'Добавлено.\n'
            return "$?"
            ;;
        trust-list)
            list_trusted
            return "$?"
            ;;
        trust-clear)
            require_root || return 1
            clear_trusted && printf 'Список запомненных user+IP очищен.\n'
            return "$?"
            ;;
        logs)
            _lines="${2:-50}"
            case "$_lines" in ''|*[!0-9]*) _lines="50" ;; esac
            if [ -f "$LOG_FILE" ]; then tail -n "$_lines" "$LOG_FILE"; else printf 'Лог пока пуст.\n'; fi
            return 0
            ;;
        --version|version)
            printf '%s\n' "$VERSION"
            return 0
            ;;
        help|--help|-h|'')
            usage
            return 0
            ;;
        *)
            printf 'Неизвестная команда: %s\n\n' "$_cmd" >&2
            usage >&2
            return 2
            ;;
    esac
}

main "$@"
exit "$?"
