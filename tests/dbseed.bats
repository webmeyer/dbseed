#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$ROOT/dbseed.sh"
    MOCK_BIN="$BATS_TEST_TMPDIR/bin"
    CALLS="$BATS_TEST_TMPDIR/calls.log"

    mkdir -p "$MOCK_BIN" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/state"
    touch "$CALLS"

    export DBSEED_TEST_CALLS="$CALLS"
    export DBSEED_TEST_DB_STATE="$BATS_TEST_TMPDIR/db-exists"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    export LOG_FILE="$BATS_TEST_TMPDIR/dbseed.log"
    export PATH="$MOCK_BIN:$PATH"

    cat > "$MOCK_BIN/sudo" <<'SH'
#!/usr/bin/env bash
while (($#)); do
    case "$1" in
        -u) shift 2 ;;
        -n|-E) shift ;;
        --) shift; break ;;
        *) break ;;
    esac
done
exec "$@"
SH

    cat > "$MOCK_BIN/psql" <<'SH'
#!/usr/bin/env bash
{
    printf 'psql'
    printf '\t%s' "$@"
    printf '\n'
} >> "$DBSEED_TEST_CALLS"

args=" $* "

# Управляемая ошибка для тестов отказа импорта/запроса.
if [[ -n "${DBSEED_TEST_FAIL_ARG:-}" &&
      "$args" == *"$DBSEED_TEST_FAIL_ARG"* ]]; then
    exit 42
fi

# Каталог сокета для сценария post-connect с usql.
if [[ "$args" == *"SHOW unix_socket_directories"* ]]; then
    printf '/var/run/postgresql\n'
    exit 0
fi

# database_exists передаёт запрос через stdin и использует -tA.
if [[ "$args" == *" -tA "* ]]; then
    sql="$(cat)"
    if [[ "$sql" == *"SELECT CASE WHEN EXISTS"* ]]; then
        if [[ -f "$DBSEED_TEST_DB_STATE" ]]; then
            printf '1\n'
        else
            printf '0\n'
        fi
        exit 0
    fi
fi

# Имитируем удаление базы.
if [[ "$args" == *"DROP DATABASE"* ]]; then
    rm -f "$DBSEED_TEST_DB_STATE"
    printf 'DROP DATABASE\n'
    exit 0
fi

# DROP DATABASE из here-document.
if [[ "$args" == *" -f - "* ]]; then
    sql="$(cat)"
    if [[ "$sql" == *"DROP DATABASE"* ]]; then
        rm -f "$DBSEED_TEST_DB_STATE"
        printf 'DROP DATABASE\n'
        exit 0
    fi
fi

printf 'mock-result\n'
SH

    cat > "$MOCK_BIN/createdb" <<'SH'
#!/usr/bin/env bash
{
    printf 'createdb'
    printf '\t%s' "$@"
    printf '\n'
} >> "$DBSEED_TEST_CALLS"

touch "$DBSEED_TEST_DB_STATE"
SH

    chmod +x "$MOCK_BIN/sudo" "$MOCK_BIN/psql" "$MOCK_BIN/createdb"
}

@test "--version выводит версию без стартового лога" {
    run bash "$SCRIPT" --version

    [ "$status" -eq 0 ]
    [ "$output" = "dbseed.sh 0.3.0" ]
}

@test "результаты SQL-запроса записываются в файл через -o" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    results="$BATS_TEST_TMPDIR/results.txt"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump" \
        -q "SELECT OUTPUT_MARKER" \
        -o "$results"

    [ "$status" -eq 0 ]
    [ -f "$results" ]
    grep -q "mock-result" "$results"
}

@test "-q и -Q выполняются в порядке указания" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    query_file="$BATS_TEST_TMPDIR/check.sql"
    printf 'SELECT FILE_MARKER;\n' > "$dump"
    printf 'SELECT 1;\n' > "$query_file"

    run bash "$SCRIPT" "$dump" \
        -q "SELECT FIRST_MARKER" \
        -Q "$query_file" \
        -q "SELECT SECOND_MARKER"

    [ "$status" -eq 0 ]

    first_line=$(grep -nF "SELECT FIRST_MARKER" "$CALLS" | cut -d: -f1)
    file_line=$(grep -nF "$query_file" "$CALLS" | cut -d: -f1)
    second_line=$(grep -nF "SELECT SECOND_MARKER" "$CALLS" | cut -d: -f1)

    [ "$first_line" -lt "$file_line" ]
    [ "$file_line" -lt "$second_line" ]
}


@test "--help показывает справку и не запускает PostgreSQL-команды" {
    run bash "$SCRIPT" --help

    [ "$status" -eq 0 ]
    [[ "$output" == *"--cleanup"* ]]
    [[ "$output" == *"--query-file"* ]]
    [ ! -s "$CALLS" ]
}

@test "имя БД по умолчанию санитизируется из имени SQL-файла" {
    dump="$BATS_TEST_TMPDIR/my-db dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump"

    [ "$status" -eq 0 ]
    grep -q $'^createdb\tmy_db_dump$' "$CALLS"
}

@test "-d и --db-name задают явное имя базы" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump" --db-name custom_db

    [ "$status" -eq 0 ]
    grep -q $'^createdb\tcustom_db$' "$CALLS"
}

@test "импорт дампа тихий по умолчанию, а --verbose включает -e" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump"

    [ "$status" -eq 0 ]
    ! grep -F -- $'\t-e\t' "$CALLS"
    [[ "$output" != *"mock-result"* ]]

    : > "$CALLS"
    rm -f "$DBSEED_TEST_DB_STATE"

    run bash "$SCRIPT" "$dump" --verbose

    [ "$status" -eq 0 ]
    grep -F -- $'\t-e\t' "$CALLS"
    [[ "$output" == *"mock-result"* ]]
}

@test "-l и --list-tables запускают psql с командой \\dt" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump" --list-tables

    [ "$status" -eq 0 ]
    grep -F -- $'\t-c\t\\dt' "$CALLS"
}

@test "-p без usql использует интерактивный psql" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    no_usql_bin="$BATS_TEST_TMPDIR/no-usql-bin"
    mkdir -p "$no_usql_bin"

    # Скрипту и mock-командам нужны эти утилиты; системный каталог целиком
    # не добавляем, чтобы command -v не нашёл установленный usql.
    for utility in bash env basename dirname mkdir stat date cat rm touch; do
        utility_path="$(type -P "$utility")"
        ln -s "$utility_path" "$no_usql_bin/$utility"
    done

    run env PATH="$MOCK_BIN:$no_usql_bin" \
        bash "$SCRIPT" "$dump" --post-connect

    [ "$status" -eq 0 ]
    grep -F -- $'psql\t-X\t-d\tdump' "$CALLS"
    ! grep -q '^usql' "$CALLS"
}

@test "-p использует usql с адресом Unix-сокета, если он доступен" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    cat > "$MOCK_BIN/usql" <<'SH'
#!/usr/bin/env bash
{
    printf 'usql'
    printf '\t%s' "$@"
    printf '\n'
} >> "$DBSEED_TEST_CALLS"
SH
    chmod +x "$MOCK_BIN/usql"

    run bash "$SCRIPT" "$dump" -p

    [ "$status" -eq 0 ]
    grep -F -- $'usql\tpg+unix:///var/run/postgresql/dump' "$CALLS"
}

@test "--cleanup и --cleanup-yes удаляют БД после успешного завершения" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump" --cleanup --cleanup-yes

    [ "$status" -eq 0 ]
    [ ! -e "$DBSEED_TEST_DB_STATE" ]
    [[ "$output" != *"DROP DATABASE"* ]]
}

@test "--cleanup без подтверждения не удаляет БД при пустом stdin" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump" --cleanup </dev/null

    [ "$status" -eq 0 ]
    [ -e "$DBSEED_TEST_DB_STATE" ]
}

@test "--cleanup отменяет удаление при некорректном ответе" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"

    run bash "$SCRIPT" "$dump" --cleanup <<<"maybe"

    [ "$status" -eq 0 ]
    [ -e "$DBSEED_TEST_DB_STATE" ]
    [[ "$output" == *"Удаление отменено"* ]]
}

@test "ошибка импорта прекращает выполнение и не запускает cleanup" {
    dump="$BATS_TEST_TMPDIR/failing-dump.sql"
    printf 'SELECT 1;\n' > "$dump"
    export DBSEED_TEST_FAIL_ARG="failing-dump.sql"

    run bash "$SCRIPT" "$dump" --cleanup --cleanup-yes

    [ "$status" -ne 0 ]
    [ -e "$DBSEED_TEST_DB_STATE" ]
    ! grep -F -- "DROP DATABASE" "$CALLS"
}

@test "-D удаляет старую БД перед созданием новой и не печатает DROP DATABASE" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"
    touch "$DBSEED_TEST_DB_STATE"

    run bash "$SCRIPT" "$dump" --drop-old-db

    [ "$status" -eq 0 ]
    [[ "$output" != *"DROP DATABASE"* ]]

    drop_line=$(grep -nF "DROP DATABASE" "$CALLS" | head -n1 | cut -d: -f1)
    create_line=$(grep -nF $'createdb\tdump' "$CALLS" | cut -d: -f1)
    [ "$drop_line" -lt "$create_line" ]
}

@test "ротация лога сжимает предыдущий файл при превышении лимита" {
    dump="$BATS_TEST_TMPDIR/dump.sql"
    printf 'SELECT 1;\n' > "$dump"
    printf 'previous log content\n' > "$LOG_FILE"
    export MAX_LOG_SIZE=1

    run bash "$SCRIPT" "$dump"

    [ "$status" -eq 0 ]
    compgen -G "${LOG_FILE}.*.gz" >/dev/null
    grep -q "Версия dbseed.sh: 0.3.0" "$LOG_FILE"
    grep -q "Скрипт запущен" "$LOG_FILE"
}
