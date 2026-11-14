# dbseed.sh

![Логотип dbseed](assets/logo.png)

`dbseed.sh` — Bash-скрипт для подготовки PostgreSQL-базы из текстового SQL-дампа. Координирует работу `createdb` и `psql`, использует SQL-запросы, при необходимости открывает консоль подключения.

## Навигация

- [📋 Описание](#-описание)
- [💭 Как работает](#-как-работает)
- [🚀 Быстрый старт](#-быстрый-старт)
- [✏️ Примеры команд](#-примеры-команд)
- [⚙️ Параметры командной строки](#-параметры-командной-строки)
- [📊 Логирование](#-логирование)
  - [Настройка](#настройка)
  - [Запуск с кастомным логированием](#запуск-с-кастомным-логированием)
  - [Просмотр логов](#просмотр-логов)
  - [Настройка ротации логов](#настройка-ротации-логов)
- [🎯 Траблшутинг](#-траблшутинг)
  - [Настройка peer-аутентификации в pg_hba](#настройка-peer-аутентификации-в-pg_hba)
  - [Ошибка отсутствия роли](#ошибка-отсутствия-роли)
- [🧪 Тесты](#-тесты)
- [📝 Лицензия](#лицензия)

## 📋 Описание

Скрипт автоматизирует:
- Создание базы данных из SQL дампа
- Выполнение дополнительных SQL-запросов и файлов запросов
- Вывод списка таблиц
- Подключение к БД после создания через интерактивную консоль
- Удаление БД после завершения работы (опционально)

Для архивных дампов PostgreSQL, предназначенных для `pg_restore`, скрипт не подходит.

## 💭 Как работает

Скрипт проверяет наличие `psql`, `createdb` и `sudo`, затем выполняет следующие шаги:

1. Проверяет, существует ли целевая база.
2. Если база существует, останавливается или удаляет её при указанном `--drop-old-db`.
3. Создаёт базу и импортирует SQL-дамп.
4. Выполняет параметры `-q` и `-Q` в порядке их указания.
5. При необходимости выводит список таблиц.
6. При необходимости открывает интерактивную консоль.
7. Удаляет базу, если указан `--cleanup` и предыдущие шаги завершились успешно.

Команды для PostgreSQL выполняются через `sudo -u postgres`. Пользователь, под которым запускается скрипт, должен иметь право использовать `sudo` для пользователя `postgres`. Команда `sudo` может запросить пароль системной учётной записи. Пароль роли PostgreSQL зависит от настроек аутентификации сервера.

SQL выполняется с `ON_ERROR_STOP=1`: при ошибке скрипт прекращает выполнение.

Для `--post-connect` используется `usql`, если он установлен. Иначе скрипт открывает `psql`. `usql` - необязательная зависимость.

## 🚀 Быстрый старт

```bash
# Скачайте скрипт
wget https://raw.githubusercontent.com/webmeyer/dbseed/refs/heads/main/dbseed.sh

# Дайте права на выполнение
chmod +x dbseed.sh

# Запустите командой
./dbseed.sh --help

# (Опционально) Создайте символическую ссылку в PATH
sudo ln -s $(pwd)/dbseed.sh /usr/local/bin/dbseed.sh
```

## ✏️ Примеры команд

```bash
# 0. Показать справку или версию
./dbseed.sh --help
./dbseed.sh --version

# 1. Запуск с опциями по умолчанию
./dbseed.sh backup.sql

# 2. С указанием имени создаваемой БД (по умолчанию используется имя SQL-дампа)
./dbseed.sh backup.sql -d dbname

# 3. С удалением старой БД
./dbseed.sh backup.sql --drop-old-db

# 4. С SQL-запросом
./dbseed.sh backup.sql -q "CREATE EXTENSION pg_trgm;"

# 5. Используя готовый файл с несколькими SQL-запросами
./dbseed.sh backup.sql -Q /path/to/dump.sql

# 6. Несколько файлов с SQL-запросами (выполнятся в порядке указания)
./dbseed.sh backup.sql \
    -Q /path/to/01_schema.sql \
    -Q /path/to/02_data.sql \
    -Q /path/to/03_indexes.sql

# 7. Комбинирование всех опций
./dbseed.sh backup.sql \
    -d dbname \
    --drop-old-db \
    -q "CREATE EXTENSION IF NOT EXISTS pg_trgm;" \
    -q "SET work_mem = '256MB';" \
    -Q /path/to/init.sql \
    --list-tables \
    --post-connect

# 8. С подключением к интерактивному режиму
./dbseed.sh backup.sql --post-connect

# 9. Вывести таблицы и открыть интерактивную консоль после выполнения
./dbseed.sh backup.sql --list-tables --post-connect

# 10. Включить расширенный вывод
./dbseed.sh backup.sql --verbose

# . Удалить БД после работы с подтверждением (автоматическое подтверждение с флагом -C, --cleanup-yes)
./dbseed.sh backup.sql --cleanup

```

## ⚙️ Параметры командной строки
```bash
    -c, --cleanup            Удалить БД после успешного выполнения
    -C, --cleanup-yes        Не запрашивать подтверждение для --cleanup
    -d, --db-name <имя>      Имя базы данных (по умолчанию — имя файла без .sql)
    -D, --drop-old-db        Удалить существующую БД перед созданием
    -h, --help               Показать эту справку
    -l, --list-tables        Показать таблицы после создания
    -o, --output-file <файл> Записывать результаты пользовательских SQL-запросов и SQL-файлов в отдельный <файл>
    -p, --post-connect       Открыть консоль после выполнения
    -q, --query <запрос>     Выполнить SQL-запрос; можно указать несколько раз
    -Q, --query-file <файл>  Выполнить SQL-файл; можно указать несколько раз
    -v, --verbose            Показывать вывод psql при импорте дампа
    -V, --version            Показать версию скрипта

```

## 📊 Логирование
По умолчанию лог записывается в:
```bash
\${XDG\_STATE\_HOME:-\$HOME/.local/state}/dbseed/dbseed.log
```

При превышении `MAX_LOG_SIZE` предыдущий лог ротируется и сжимается. Размер можно задавать в байтах или с суффиксами `K`, `M`, `G`.

### Настройка
```bash
# Путь к лог-файлу
export LOG_FILE="/path/to/dbseed.log"

# Уровень логирования (DEBUG, INFO, WARN, ERROR)
export LOG_LEVEL="INFO"

# Максимальный размер лога (для ротации)
export MAX_LOG_SIZE="10M"
```

### Запуск с кастомным логированием
```bash
# Стандартное логирование
./dbseed.sh backup.sql

# С кастомным путём к логам
LOG_FILE=/tmp/dbseed.log ./dbseed.sh backup.sql

# С отладочным логированием
LOG_LEVEL=DEBUG ./dbseed.sh backup.sql

# Без логирования в файл (только stdout)
LOG_FILE="" ./dbseed.sh backup.sql
```

### Просмотр логов
```bash
# Просмотр последних записей
tail -f /var/log/dbseed/dbseed.log

# Поиск ошибок
grep "ERROR" /var/log/dbseed/dbseed.log

# Поиск по БД
grep "dbname" /var/log/dbseed/dbseed.log

# Статистика
grep -c "INFO" /var/log/dbseed/dbseed.log
grep -c "ERROR" /var/log/dbseed/dbseed.log
```

### Настройка ротации логов
```bash
# Автоматическая ротация (при превышении MAX_LOG_SIZE)
# Или вручную
sudo logrotate -f /etc/logrotate.d/dbseed

# Очистка старых логов
find /var/log/dbseed/ -name "*.gz" -mtime +30 -delete
```

## 🎯 Траблшутинг
###  Настройка peer-аутентификации в pg_hba
```bash
## проверка пути до конфига
sudo -u postgres psql -d postgres -c 'SHOW hba_file;'

## повышение прав и добавление строки
sudo -i
echo "local   all   postgres   peer" >> /var/lib/pgsql/18/data/pg_hba.conf

## перечитывание конфига
sudo -u postgres psql -d postgres -c 'SELECT pg_reload_conf();'
```

###  Ошибка отсутствия роли
При запуске скрипта ошибка:
```bash
psql:../knowledgebase_content_deployer (2).sql:26: ERROR: role "role_name" does not exist
```
Решение:
```bash
sudo -u postgres psql -d postgres -c 'CREATE ROLE role_name NOLOGIN;'
```

## 🧪 Тесты
Для запуска тестов нужен Bats: https://bats-core.readthedocs.io/

Чтобы запустить тесты с расширенным выводом при возникновении ошибок:
```bash
bats --print-output-on-failure tests/dbseed.bats
```

Тесты используют mock-команды и не требуют работающего PostgreSQL-сервера. В частности, проверяются режим `fallback` на `psql` без доступного `usql`, порядок выполнения `-q` и `-Q`, вывод результатов в файл и поведение `--cleanup` при пустом или некорректном ответе.

Если в репозитории настроен GitHub Actions workflow в `.github/workflows/tests.yml`, те же тесты запускаются автоматически при `push` и создании или обновлении `pull request`.

## 📝 Лицензия
Этот проект распространяется под лицензией MIT License.\
Полный текст лицензии доступен в файле [LICENSE](LICENSE).
