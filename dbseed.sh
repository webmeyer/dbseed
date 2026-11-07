#!/usr/bin/env bash
# Создание PostgreSQL-базы из текстового SQL-дампа.

set -Eeuo pipefail

LOG_FILE="${LOG_FILE:-${XDG_STATE_HOME:-${HOME:-.}/.local/state}/dbseed/dbseed.log}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-10M}"

DB_NAME=""
SQL_FILE=""
DROP_OLD=false
LIST_TABLES=false
POST_CONNECT=false
CLEANUP=false
CONFIRM_CLEANUP=false

# Хранят SQL-запросы и файлы в порядке указания аргументов.
declare -a TASK_TYPES=()
declare -a TASK_VALUES=()

USE_USQL=false

show_usage() {
    cat <<EOF
Использование:
    $0 <путь_к_файлу.sql> [параметры]

Параметры:
    -d, --db-name <имя>      Имя базы данных (по умолчанию — имя файла без .sql)
    -o, --drop-old           Удалить существующую БД перед созданием
    -l, --list-tables        Показать таблицы после создания
    -q, --query <запрос>     Выполнить SQL-запрос; можно указать несколько раз
    -f, --query-file <файл>  Выполнить SQL-файл; можно указать несколько раз
    -p, --post-connect       Открыть консоль после выполнения
    -n, --no-connect         Не открывать консоль (поведение по умолчанию)
    -c, --cleanup            Удалить БД после успешного выполнения
    -y, --yes                Не запрашивать подтверждение для --cleanup
    -h, --help               Показать эту справку

Запросы -q и файлы -f выполняются в порядке указания.
Скрипт принимает текстовые SQL-файлы. Для архивных дампов PostgreSQL используйте pg_restore.
EOF
}

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
    show_usage
    exit 0
fi

die() {
    print_error "$*"
    exit 1
}

parse_size() {
    local value="$1"
    local number suffix multiplier=1

    if [[ ! "$value" =~ ^([0-9]+)([KkMmGg]?)$ ]]; then
        return 1
    fi

    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"

    case "$suffix" in
        [Kk]) multiplier=1024 ;;
        [Mm]) multiplier=$((1024 * 1024)) ;;
        [Gg]) multiplier=$((1024 * 1024 * 1024)) ;;
    esac

    printf '%s\n' "$((number * multiplier))"
}

init_logging() {
    case "$LOG_LEVEL" in
        DEBUG|INFO|WARN|ERROR) ;;
        *)
            printf 'Некорректный LOG_LEVEL=%s; используется INFO\n' "$LOG_LEVEL" >&2
            LOG_LEVEL="INFO"
            ;;
    esac

    if [[ -n "$LOG_FILE" ]]; then
        local log_dir
        log_dir="$(dirname -- "$LOG_FILE")"
        if ! mkdir -p -- "$log_dir" 2>/dev/null; then
            printf 'Не удалось создать каталог логов: %s\n' "$log_dir" >&2
            return 1
        fi
        if ! ( : >> "$LOG_FILE" ) 2>/dev/null; then
            printf 'Нет доступа для записи в лог: %s\n' "$LOG_FILE" >&2
            return 1
        fi

        if [[ -f "$LOG_FILE" ]]; then
            local max_bytes size stamp rotated

            if max_bytes="$(parse_size "$MAX_LOG_SIZE")"; then
                size="$(stat -c '%s' -- "$LOG_FILE" 2>/dev/null \
                    || stat -f '%z' "$LOG_FILE" 2>/dev/null \
                    || printf '0')"

                if [[ "$size" =~ ^[0-9]+$ ]] && (( size > max_bytes )); then
                    stamp="$(date '+%Y%m%d%H%M%S')"
                    rotated="${LOG_FILE}.${stamp}"

                    if mv -- "$LOG_FILE" "$rotated" 2>/dev/null; then
                        gzip -f "$rotated" 2>/dev/null || true
                    fi
                fi
            else
                printf 'Некорректный MAX_LOG_SIZE=%s; ротация отключена\n' \
                    "$MAX_LOG_SIZE" >&2
            fi
        fi
    fi

    return 0
}

log() {
    local level="$1"
    shift
    local message="$*"
    local level_rank min_rank timestamp entry color

    case "$level" in
        DEBUG) level_rank=10 ;;
        INFO)  level_rank=20 ;;
        WARN)  level_rank=30 ;;
        ERROR) level_rank=40 ;;
        *)     level_rank=20 ;;
    esac

    case "$LOG_LEVEL" in
        DEBUG) min_rank=10 ;;
        INFO)  min_rank=20 ;;
        WARN)  min_rank=30 ;;
        ERROR) min_rank=40 ;;
    esac

    if (( level_rank < min_rank )); then
        return 0
    fi

    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    entry="[$timestamp] [$level] [$$] $message"

    if [[ -t 1 ]]; then
        case "$level" in
            ERROR) color=$'\033[0;31m' ;;
            WARN)  color=$'\033[1;33m' ;;
            INFO)  color=$'\033[0;34m' ;;
            DEBUG) color=$'\033[0;36m' ;;
            *)     color="" ;;
        esac
        printf '%s%s\033[0m\n' "$color" "$entry"
    else
        printf '%s\n' "$entry"
    fi

    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$entry" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

print_info()    { log INFO "$*"; }
print_success() { log INFO "[OK] $*"; }
print_warning() { log WARN "$*"; }
print_error()   { log ERROR "$*"; }

require_value() {
    local option="$1"
    local value="${2-}"

    [[ -n "$value" ]] || die "Для параметра $option требуется значение"
}

if ! init_logging; then
    exit 1
fi
print_info "Скрипт запущен"

# Разбор аргументов.
while (($# > 0)); do
    case "$1" in
        -d|--db-name)
            require_value "$1" "${2-}"
            DB_NAME="$2"
            shift 2
            ;;
        -o|--drop-old)
            DROP_OLD=true
            shift
            ;;
        -l|--list-tables)
            LIST_TABLES=true
            shift
            ;;
        -q|--query)
            require_value "$1" "${2-}"
            TASK_TYPES+=(query)
            TASK_VALUES+=("$2")
            shift 2
            ;;
        -f|--query-file)
            require_value "$1" "${2-}"
            TASK_TYPES+=(file)
            TASK_VALUES+=("$2")
            shift 2
            ;;
        -p|--post-connect)
            POST_CONNECT=true
            shift
            ;;
        -n|--no-connect)
            POST_CONNECT=false
            shift
            ;;
        -c|--cleanup)
            CLEANUP=true
            shift
            ;;
        -y|--yes)
            CONFIRM_CLEANUP=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            print_error "Неизвестный параметр: $1"
            show_usage
            exit 1
            ;;
        *)
            if [[ -z "$SQL_FILE" ]]; then
                SQL_FILE="$1"
            else
                print_error "Избыточный аргумент: $1"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

[[ -n "$SQL_FILE" ]] || {
    print_error "Не указан путь к SQL-файлу"
    show_usage
    exit 1
}

[[ -f "$SQL_FILE" ]] || die "Файл не найден: $SQL_FILE"

if [[ -z "$DB_NAME" ]]; then
    DB_NAME="$(basename -- "$SQL_FILE" .sql)"
    DB_NAME="${DB_NAME//[^a-zA-Z0-9_]/_}"
fi

if [[ ! "$DB_NAME" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    die "Недопустимое имя БД: $DB_NAME. Используйте буквы, цифры и _; первый символ должен быть буквой или _"
fi

for ((i = 0; i < ${#TASK_TYPES[@]}; i++)); do
    if [[ "${TASK_TYPES[$i]}" == "file" && ! -f "${TASK_VALUES[$i]}" ]]; then
        die "Файл запросов не найден: ${TASK_VALUES[$i]}"
    fi
done

check_dependencies() {
    command -v psql >/dev/null 2>&1 || die "psql не найден. Установите клиент PostgreSQL."
    command -v createdb >/dev/null 2>&1 || die "createdb не найден. Установите клиент PostgreSQL."
    command -v sudo >/dev/null 2>&1 || die "sudo не найден, но скрипт использует sudo -u postgres."

    if command -v usql >/dev/null 2>&1; then
        USE_USQL=true
    else
        print_warning "usql не найден; для интерактивного подключения будет использован psql"
    fi
}

psql_as_postgres() {
    sudo -u postgres env -u PGUSER -u PGPASSWORD \
        psql -X -U postgres -v ON_ERROR_STOP=1 "$@"
}


database_exists() {
    psql_as_postgres \
        -v "dbname=$DB_NAME" \
        -d postgres -tA <<'SQL'
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM pg_database WHERE datname = :'dbname'
) THEN 1 ELSE 0 END;
SQL
}


drop_database() {
    psql_as_postgres \
        -d postgres \
        -v "dbname=$DB_NAME" \
        -f - <<'SQL'
DROP DATABASE :"dbname";
SQL
}

execute_task() {
    local type="$1"
    local value="$2"

    case "$type" in
        query)
            print_info "Выполнение SQL-запроса"
            psql_as_postgres -d "$DB_NAME" -c "$value"
            ;;
        file)
            print_info "Выполнение запросов из файла: $value"
            psql_as_postgres -d "$DB_NAME" -f "$value"
            ;;
        *)
            die "Внутренняя ошибка: неизвестный тип задачи '$type'"
            ;;
    esac

    print_success "Операция выполнена"
}

cleanup_database() {
    local confirm

    [[ "$CLEANUP" == true ]] || return 0

    print_warning "Запрошено удаление БД '$DB_NAME'"

    if [[ "$CONFIRM_CLEANUP" != true ]]; then
        if ! read -r -p "Удалить БД '$DB_NAME'? (y/N): " confirm; then
            confirm=""
        fi

        case "$confirm" in
            y|Y|yes|YES|Yes) ;;
            *)
                print_info "Удаление отменено"
                return 0
                ;;
        esac
    fi

    local db_exists
    if ! db_exists="$(database_exists)"; then
        die "Не удалось проверить существование БД '$DB_NAME'"
    fi

    if [[ "$db_exists" == "1" ]]; then
            drop_database
	print_success "БД '$DB_NAME' удалена"
    else
        print_warning "БД '$DB_NAME' не найдена"
    fi
}

check_dependencies

print_info "SQL-файл: $SQL_FILE"
print_info "Имя БД: $DB_NAME"
print_info "Дополнительных задач: ${#TASK_TYPES[@]}"
print_info "Подключение после выполнения: $POST_CONNECT"
print_info "Удаление после выполнения: $CLEANUP"

DB_EXISTS="$(database_exists)" || die "Не удалось проверить существование БД '$DB_NAME'"

if [[ "$DB_EXISTS" == "1" ]]; then
    if [[ "$DROP_OLD" == true ]]; then
        print_warning "Существующая БД '$DB_NAME' будет удалена"
        psql_as_postgres \
            -v "dbname=$DB_NAME" \
            -d postgres \
            -c "DROP DATABASE \"$DB_NAME\";"
    else
        die "БД '$DB_NAME' уже существует. Для её удаления укажите --drop-old"
    fi
fi

print_info "Создание БД '$DB_NAME'"
sudo -u postgres createdb "$DB_NAME"
print_success "БД создана"

print_info "Импорт дампа: $SQL_FILE"
psql_as_postgres -d "$DB_NAME" -f "$SQL_FILE"
print_success "Дамп импортирован"

for ((i = 0; i < ${#TASK_TYPES[@]}; i++)); do
    execute_task "${TASK_TYPES[$i]}" "${TASK_VALUES[$i]}"
done

if [[ "$LIST_TABLES" == true ]]; then
    print_info "Таблицы в БД:"
    psql_as_postgres -d "$DB_NAME" -c '\dt'
fi

if [[ "$POST_CONNECT" == true ]]; then
    print_info "Подключение к БД '$DB_NAME'"

    if [[ "$USE_USQL" == true ]]; then
        PG_SOCKET_DIR=$(
            sudo -u postgres psql -X -Atqc 'SHOW unix_socket_directories' |
                cut -d, -f1 |
                xargs
        )

        if [[ -z "$PG_SOCKET_DIR" ]]; then
            print_error "Не удалось определить каталог сокета PostgreSQL"
            exit 1
        fi

        sudo -u postgres usql "pg+unix://$PG_SOCKET_DIR/$DB_NAME"
    else
        sudo -u postgres psql -X -d "$DB_NAME"
    fi
fi

cleanup_database
print_success "Скрипт завершён"
