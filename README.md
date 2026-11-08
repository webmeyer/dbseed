# dbseed.sh

![Логотип dbseed](assets/logo.png)

`dbseed.sh` — Bash-скрипт для подготовки PostgreSQL-базы из текстового SQL-дампа. Координирует работу `createdb` и `psql`, использует SQL-запросы, при необходимости открывает консоль подключения.

## Содержание

- [dbseed.sh](#dbseedsh)
  - [📋 Описание](#-описание)
  - [🚀 Как работает](#-как-работает)
  - [🚀 Быстрый старт](#-быстрый-старт)
  - [🔄 Базовые команды для копирования](#-базовые-команды-для-копирования)
  - [Логирование](#логирование)
    - [Настройка](#настройка)
    - [Запуск с кастомным логированием](#запуск-с-кастомным-логированием)
    - [Просмотр логов](#просмотр-логов)
    - [Настройка ротации логов](#настройка-ротации-логов)
  - [Траблшутинг](#траблшутинг)
    - [1. Настройка pg_hba](#1-настройка-pg_hba)
    - [2. Ошибка отсутствия роли](#2-ошибка-отсутствия-роли)
  - [Лицензия](#лицензия)

## 📋 Описание

Автоматизирует процесс:
- Создания базы данных из SQL дампа
- Выполнения дополнительных SQL-запросов
- Автоматического подключения к БД после создания
- Удаления БД после завершения работы (опционально)

## Как работает

Скрипт выполняет команды PostgreSQL через `sudo -u postgres`. Запускающий пользователь должен иметь право использовать `sudo` для пользователя `postgres`. `sudo` может запросить пароль системной учётной записи; пароль роли PostgreSQL зависит от настроек аутентификации сервера.

Затем выполняется сценарий:

- Проверка необходимых зависимостей;
- При включённой опции: удаление пользовательской БД для дальнейшего пересоздания;
- Создание целевой БД;
- Импорт SQL-дампа;
- Выполнение запросов и файлов запросов в порядке их указания;
- При включённой опции: вывод списка таблиц;
- При включённой опции: открытите интерактивного подключения (требуется `usql`).
- При включённой опции: автоматическое удаление созданной БД после завершения работы (только если предыдущие шаги завершились успешно).

SQL выполняется с `ON_ERROR_STOP=1`: при ошибке скрипт прекращает выполнение.

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

## 🔄 Базовые команды для копирования

```bash
# 0. Показать справку
./dbseed.sh --help

# 1. Запуск с опциями по умолчанию
./dbseed.sh backup.sql

# 2. С указанием имени создаваемой БД (по умолчанию используется имя SQL-дампа)
./dbseed.sh backup.sql -d dbname

# 3. С удалением старой БД
./dbseed.sh backup.sql --drop-old

# 4. С SQL-запросом
./dbseed.sh backup.sql -q "CREATE EXTENSION pg_trgm;"

# 5. Используя готовый файл с несколькими SQL-запросами
./dbseed.sh backup.sql -f /path/to/dump.sql

# 6. Несколько файлов с SQL-запросами (выполнятся в порядке указания)
./dbseed.sh backup.sql \
    -f /path/to/01_schema.sql \
    -f /path/to/02_data.sql \
    -f /path/to/03_indexes.sql

# 7. Комбинирование всех опций
./dbseed.sh backup.sql \
    -d dbname \
    --drop-old \
    -q "CREATE EXTENSION IF NOT EXISTS pg_trgm;" \
    -q "SET work_mem = '256MB';" \
    -f /path/to/init.sql \
    --list-tables \
    --post-connect

# 8. С подключением к интерактивному режиму
./dbseed.sh backup.sql --post-connect

# 9. Удалить БД после работы с подтверждением (автоматическое подтверждение с доп.флагом --yes)
./dbseed.sh backup.sql --cleanup

```

## Логирование
### Настройка
```bash
# Путь к лог-файлу (по умолчанию: $HOME/.local/state/dbseed/dbseed.log)
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

## Траблшутинг
###  1. Настройка pg_hba
```bash
## проверка пути до конфига
sudo -u postgres psql -d postgres -c 'SHOW hba_file;'

## повышение прав и добавление строки
sudo -i
echo "local   all   postgres   peer" >> /var/lib/pgsql/18/data/pg_hba.conf

## перечитывание конфига
sudo -u postgres psql -d postgres -c 'SELECT pg_reload_conf();'
```

###  2. Ошибка отсутствия роли
При запуске скрипта ошибка:
```bash
psql:../knowledgebase_content_deployer (2).sql:26: ERROR: role "role_name" does not exist
```
Решение:
```bash
sudo -u postgres psql -d postgres -c 'CREATE ROLE role_name NOLOGIN;'
```

## Лицензия
Этот проект распространяется под лицензией MIT License.\
Полный текст лицензии доступен в файле [LICENSE](LICENSE).
