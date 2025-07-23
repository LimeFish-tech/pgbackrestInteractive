#!/bin/bash

# Проверка пользователя
if [ "$(whoami)" != "gpadmin" ]; then
    echo -e "\033[0;31mОШИБКА: Скрипт должен запускаться под пользователем gpadmin!\033[0m"
    exit 1
fi

# Глобальные переменные
current_user=$(whoami)
current_host=$(hostname)
declare -gA host_segments
segment_sections=""
global_section=""
host_list_file="hosts_list.txt"
storage_host=""
backup_dir="/home/gpadmin/backup_configs"
config_dir="/home/gpadmin/seg_configs"
script_name=$(basename "$0" .sh)
timestamp=$(date +%Y%m%d_%H%M%S)
log_dir="/home/gpadmin/logs"
log_file="$log_dir/${script_name}-${timestamp}.log"
cmd_log_file="$log_dir/${script_name}-commands-${timestamp}.log"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Обработка прерывания
trap 'cleanup_on_exit' INT TERM

function cleanup_on_exit() {
    log "Скрипт прерван пользователем" "ERROR"
    exit 1
}

# Логирование команд
function log_command() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$cmd_log_file"
}

# Функция логирования
function log() {
    local msg=$1
    local level=${2:-"INFO"}
    local color=$NC
    
    case $level in
        "ERROR") color=$RED ;;
        "WARN") color=$YELLOW ;;
        "INFO") color=$GREEN ;;
        "DEBUG") color=$CYAN ;;
    esac
    
    mkdir -p "$log_dir"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $1" >> "$log_file"
    echo -e "$color[$timestamp] [$level] $1${NC}"
}

# Функция проверки зависимостей
function check_dependencies() {
    local dependencies=("psql" "ssh" "scp" "gpscp" "gpssh")
    local missing=()
    
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log "Отсутствуют необходимые утилиты: ${missing[*]}" "ERROR"
        return 1
    fi
    return 0
}

# Проверка доступности Greenplum
function check_greenplum_availability() {
    log "Проверка доступности Greenplum..." "INFO"
    log_command "psql -d postgres -c \"SELECT 1\""
    
    if ! psql -d postgres -c "SELECT 1" &>> "$cmd_log_file"; then
        log "Не удалось подключиться к Greenplum!" "ERROR"
        return 1
    fi
    
    log "Подключение к Greenplum успешно" "DEBUG"
    return 0
}

# СИСТЕМА БЭКАПИРОВАНИЯ

# Функция для создания резервной копии конфига
function backup_config() {
    local src_file=$1
    local suffix=$2   # Необязательный суффикс
    
    # Проверяем, что файл существует
    if [ ! -f "$src_file" ]; then
        log "Файл для бэкапа не найден: $src_file" "WARN"
        return 1
    fi

    local filename=$(basename "$src_file")
    local backup_subdir="$backup_dir/$filename"
    mkdir -p "$backup_subdir"

    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="${timestamp}${suffix:+_$suffix}_$filename"
    local backup_path="$backup_subdir/$backup_name"

    # Копируем файл
    cp "$src_file" "$backup_path" || {
        log "Ошибка при создании бэкапа $backup_path" "ERROR"
        return 1
    }

    log "Бэкап создан: $backup_path" "INFO"

    # Удаляем старые бэкапы, оставляем последние 10
    (cd "$backup_subdir" && ls -t | tail -n +11 | xargs rm -f --)
}

# Функция для восстановления конфигов из бэкапа
function restore_from_backup() {
    echo -e "\n${YELLOW}=== ВОССТАНОВЛЕНИЕ ИЗ БЭКАПА ===${NC}"

    # Получаем список файлов, для которых есть бэкапы
    local backup_files=($(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;))
    if [ ${#backup_files[@]} -eq 0 ]; then
        log "Нет доступных бэкапов." "ERROR"
        return 1
    fi

    echo -e "\n${CYAN}Выберите файл для восстановления:${NC}"
    local PS3="Введите номер файла: "
    select file_to_restore in "${backup_files[@]}" "Отмена"; do
        if [ "$REPLY" -ge 1 ] && [ "$REPLY" -le ${#backup_files[@]} ]; then
            break
        elif [ "$REPLY" -eq $((${#backup_files[@]}+1)) ]; then
            log "Восстановление отменено." "INFO"
            return 0
        else
            log "Неверный выбор." "ERROR"
        fi
    done

    local backup_subdir="$backup_dir/$file_to_restore"
    local backups=($(ls -t "$backup_subdir"))
    if [ ${#backups[@]} -eq 0 ]; then
        log "Для файла $file_to_restore нет бэкапов." "ERROR"
        return 1
    fi

    echo -e "\n${CYAN}Выберите бэкап:${NC}"
    PS3="Введите номер бэкапа: "
    select backup_name in "${backups[@]}" "Отмена"; do
        if [ "$REPLY" -ge 1 ] && [ "$REPLY" -le ${#backups[@]} ]; then
            local backup_path="$backup_subdir/$backup_name"
            break
        elif [ "$REPLY" -eq $((${#backups[@]}+1)) ]; then
            log "Восстановление отменено." "INFO"
            return 0
        else
            log "Неверный выбор." "ERROR"
        fi
    done

    local target_path="$config_dir/$file_to_restore"

    # Если файл существует, спрашиваем действие
    if [ -f "$target_path" ]; then
        echo -e "\n${YELLOW}Файл $target_path уже существует.${NC}"
        echo "1. Перезаписать (создав бэкап текущего состояния)"
        echo "2. Восстановить как новый файл"
        echo "3. Отмена"
        read -p "Выберите действие: " action_choice

        case $action_choice in
            1)
                # Создаем бэкап текущего файла
                backup_config "$target_path" "before_restore"
                # Заменяем файл
                cp "$backup_path" "$target_path" || {
                    log "Ошибка при восстановлении бэкапа." "ERROR"
                    return 1
                }
                ;;
            2)
                local new_name
                while true; do
                    read -p "Введите новое имя файла: " new_name
                    if [ -z "$new_name" ]; then
                        log "Имя файла не может быть пустым." "ERROR"
                        continue
                    fi
                    target_path="$config_dir/$new_name"
                    if [ -f "$target_path" ]; then
                        read -p "Файл $new_name уже существует. Перезаписать? (y/n): " overwrite
                        [[ "$overwrite" =~ ^[Yy]$ ]] && break
                    else
                        break
                    fi
                done
                cp "$backup_path" "$target_path" || {
                    log "Ошибка при создании нового файла из бэкапа." "ERROR"
                    return 1
                }
                ;;
            3)
                log "Восстановление отменено." "INFO"
                return 0
                ;;
            *)
                log "Неверный выбор. Восстановление отменено." "ERROR"
                return 1
                ;;
        esac
    else
        # Файл не существует, просто копируем
        cp "$backup_path" "$target_path" || {
            log "Ошибка при восстановлении бэкапа." "ERROR"
            return 1
        }
    fi

    log "Файл $target_path успешно восстановлен из бэкапа $backup_name." "INFO"
    
    # Если восстановленный файл - pgbackrest.conf, обновляем глобальные переменные
    if [ "$file_to_restore" == "pgbackrest.conf" ]; then
        global_section=$(grep -A 10 "^\[global\]" "$target_path")
        segment_sections=$(sed -n '/^\[.*\]/,/^$/p' "$target_path" | grep -v "^\[global\]")
        log "Глобальные секции обновлены." "DEBUG"
    fi

    # Создаем бэкап восстановленного файла
    backup_config "$target_path"

    # Предлагаем отредактировать восстановленный файл
    read -p "Хотите отредактировать восстановленный файл? (y/n): " edit_choice
    if [[ "$edit_choice" =~ ^[Yy]$ ]]; then
        ${EDITOR:-vi} "$target_path"
        log "Файл $target_path отредактирован." "INFO"
        backup_config "$target_path"
    fi

    return 0
}

# Функция для редактирования конфигурационных файлов
function edit_config() {
    echo -e "\n${YELLOW}=== РЕДАКТИРОВАНИЕ КОНФИГУРАЦИОННЫХ ФАЙЛОВ ===${NC}"
    
    # Основные файлы для редактирования
    local main_files=("$config_dir/pgbackrest.conf" "$config_dir/$host_list_file")
    local host_configs=($(ls "$config_dir"/pgbackrest-*.conf 2>/dev/null | grep -v "$config_dir/pgbackrest.conf"))
    
    # Собираем все файлы в один массив
    local config_files=("${main_files[@]}" "${host_configs[@]}")
    
    if [ ${#config_files[@]} -eq 0 ]; then
        log "Нет доступных конфигурационных файлов в директории $config_dir" "ERROR"
        return 1
    fi
    
    echo -e "\n${CYAN}Доступные конфигурационные файлы:${NC}"
    PS3="Выберите файл для редактирования: "
    select config_file in "${config_files[@]}" "Отмена"; do
        if [ "$REPLY" -le ${#config_files[@]} ]; then
            # Создаем бэкап перед редактированием
            backup_config "$config_file"
            
            log_command "${EDITOR:-vi} \"$config_file\""
            ${EDITOR:-vi} "$config_file"
            log "Конфиг отредактирован: $config_file" "INFO"
            
            # Создаем бэкап после редактирования
            backup_config "$config_file"
            
            # Обновляем конфиг в памяти, если это основной конфиг
            if [ "$(basename "$config_file")" == "pgbackrest.conf" ]; then
                global_section=$(grep -A 10 "^\[global\]" "$config_file")
                segment_sections=$(sed -n '/^\[.*\]/,/^$/p' "$config_file" | grep -v "^\[global\]")
            fi
            
            return 0
        elif [ "$REPLY" -eq $((${#config_files[@]}+1)) ]; then
            log "Редактирование отменено" "INFO"
            return 0
        else
            log "Неверный выбор, попробуйте снова" "ERROR"
        fi
    done
}

# Функция для настройки директории конфигурации
function setup_config_dir() {
    echo -e "\n${YELLOW}=== НАСТРОЙКА ДИРЕКТОРИИ КОНФИГУРАЦИИ ===${NC}"
    local default_dir="/home/gpadmin/seg_configs"
    read -p "Введите путь для сохранения конфигов (default: $default_dir): " config_dir
    config_dir=${config_dir:-$default_dir}
    
    if [ ! -d "$config_dir" ]; then
        read -p "Директория $config_dir не существует. Создать? (y/n) " create_dir
        if [[ "$create_dir" =~ ^[Yy]$ ]]; then
            log_command "mkdir -p \"$config_dir\""
            mkdir -p "$config_dir" || {
                log "Не удалось создать директорию $config_dir" "ERROR"
                return 1
            }
            log "Директория $config_dir создана" "INFO"
        else
            log "Использование несуществующей директории может привести к ошибкам" "WARN"
            return 1
        fi
    fi
    
    log "Директория конфигурации установлена: $config_dir" "INFO"
}

# Функция для настройки хоста хранилища
function setup_storage_host() {
    echo -e "\n${YELLOW}=== НАСТРОЙКА ХОСТА ХРАНИЛИЩА ===${NC}"
    while true; do
        read -p "Введите имя хоста хранилища (например backup-server) или оставьте пустым для локального режима: " storage_host
        
        if [ -z "$storage_host" ]; then
            log "Режим локального хранилища: каждый хост будет хранить бэкапы локально" "INFO"
            return 0
        fi
        
        if ! [[ "$storage_host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            log "Некорректное имя хоста!" "ERROR"
            continue
        fi
        
        log "Проверяем доступность хоста $storage_host..." "INFO"
        log_command "ping -c 1 \"$storage_host\""
        if ping -c 1 "$storage_host" &>> "$cmd_log_file"; then
            log "Хост $storage_host доступен" "INFO"
            break
        else
            log "Хост $storage_host недоступен по ping" "WARN"
            read -p "Продолжить без проверки доступности? (y/n) " choice
            [[ "$choice" =~ ^[Yy]$ ]] && break
        fi
    done
    
    log "Хост хранилища установлен: $storage_host" "INFO"
}

# Функция для настройки глобальных параметров с проверками
function setup_global_params() {
    echo -e "\n${YELLOW}=== НАСТРОЙКА ГЛОБАЛЬНЫХ ПАРАМЕТРОВ ===${NC}"
    echo -e "${CYAN}Примечание: Вы можете отредактировать конфиг вручную в пункте 3 главного меню"
    echo -e "Подробную информацию по конфигурации можно найти на сайте: https://pgbackrest.org/${NC}"
    
    local log_level_file="info"
    local log_level_console="info"
    local archive_copy="y"
    local archive_check="n"
    local fork="GPDB"
    local process_max="3"
    local repo1_path="/backup_storage/local/pgbackrest/"
    local repo1_retention_full="2"
    local log_path="/tmp/backup/log"
    local start_fast="y"

    # Список допустимых уровней логгирования
    local valid_log_levels=("off" "error" "warn" "info" "detail" "debug" "trace")
    
    # Проверка для archive-copy
    while true; do
        read -p "archive-copy (y/n) (default: $archive_copy): " input
        if [ -n "$input" ]; then
            if [[ "$input" != "y" && "$input" != "n" ]]; then
                log "Недопустимое значение! Допустимы только 'y' или 'n'." "ERROR"
            else
                archive_copy="$input"
                break
            fi
        else
            break
        fi
    done
    
    # Проверка для archive-check
    while true; do
        read -p "archive-check (y/n) (default: $archive_check): " input
        if [ -n "$input" ]; then
            if [[ "$input" != "y" && "$input" != "n" ]]; then
                log "Недопустимое значение! Допустимы только 'y' или 'n'." "ERROR"
            else
                archive_check="$input"
                break
            fi
        else
            break
        fi
    done
    
    # Проверка для log-level-file
    while true; do
        read -p "log-level-file (off|error|warn|info|detail|debug|trace) (default: $log_level_file): " input
        if [ -n "$input" ]; then
            if [[ ! " ${valid_log_levels[*]} " =~ " ${input} " ]]; then
                log "Недопустимое значение! Допустимые значения: ${valid_log_levels[*]}" "ERROR"
            else
                log_level_file="$input"
                break
            fi
        else
            break
        fi
    done
    
    # Проверка для log-level-console
    while true; do
        read -p "log-level-console (off|error|warn|info|detail|debug|trace) (default: $log_level_console): " input
        if [ -n "$input" ]; then
            if [[ ! " ${valid_log_levels[*]} " =~ " ${input} " ]]; then
                log "Недопустимое значение! Допустимые значения: ${valid_log_levels[*]}" "ERROR"
            else
                log_level_console="$input"
                break
            fi
        else
            break
        fi
    done
    
    # Проверка для process-max
    while true; do
        read -p "process-max (1-999) (default: $process_max): " input
        if [ -n "$input" ]; then
            if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 || "$input" -gt 999 ]]; then
                log "Недопустимое значение! Допустимы числа от 1 до 999." "ERROR"
            else
                process_max="$input"
                break
            fi
        else
            break
        fi
    done
    
    # Проверка для repo1-retention-full
    while true; do
        read -p "repo1-retention-full (1-10) (default: $repo1_retention_full): " input
        if [ -n "$input" ]; then
            if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 || "$input" -gt 10 ]]; then
                log "Недопустимое значение! Допустимы числа от 1 до 10." "ERROR"
            else
                repo1_retention_full="$input"
                break
            fi
        else
            break
        fi
    done
    
    read -p "fork (default: $fork): " input
    [ -n "$input" ] && fork="$input"
    
    read -p "repo1-path (default: $repo1_path): " input
    [ -n "$input" ] && repo1_path="$input"
    
    read -p "log-path (default: $log_path): " input
    [ -n "$input" ] && log_path="$input"
    
    # Для start-fast всегда ставим 'y'
    start_fast="y"
    log "start-fast установлен в 'y' по умолчанию" "INFO"

    global_section="[global]
  log-level-file = $log_level_file
  log-level-console = $log_level_console
  archive-copy = $archive_copy
  archive-check = $archive_check
  fork = $fork
  process-max = $process_max
  repo1-path = $repo1_path
  repo1-retention-full = $repo1_retention_full
  log-path = $log_path"
  
  host_global_section="[global]
  repo1-path = $repo1_path
  log-path = $log_path
  start-fast = $start_fast
  fork = $fork"
  
  export start_fast repo1_path log_path fork host_global_section
  log "Глобальные параметры успешно настроены" "INFO"
}

# Функция для составления списка хостов
function generate_hosts_list() {
    echo -e "\n${YELLOW}=== СОСТАВЛЕНИЕ СПИСКА ХОСТОВ ===${NC}"
    
    if [ -z "$config_dir" ]; then
        setup_config_dir
    fi
    
    log "Получение списка хостов из Greenplum..." "INFO"
    log_command "psql -d postgres -Atc \"SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;\""
    local db_hosts=$(psql -d postgres -Atc "SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;" 2>> "$cmd_log_file")
    
    backup_config "$config_dir/$host_list_file"
    
    echo "# Список хостов Greenplum" > "$config_dir/$host_list_file"
    echo "# Сгенерировано $(date)" >> "$config_dir/$host_list_file"
    echo "" >> "$config_dir/$host_list_file"
    echo "# Хосты сегментов:" >> "$config_dir/$host_list_file"
    for host in $db_hosts; do
        echo "$host" >> "$config_dir/$host_list_file"
    done
    
    log "Список хостов сохранён в $config_dir/$host_list_file" "INFO"
}

# Функция для создания основного файла конфигурации
function create_main_config() {
    echo -e "\n${YELLOW}=== СОЗДАНИЕ ОСНОВНОГО КОНФИГА ===${NC}"
    
    if [ -z "$global_section" ]; then
        log "Ошибка: сначала выполните настройку глобальных параметров!" "ERROR"
        return 1
    fi

    if [ -z "$config_dir" ]; then
        setup_config_dir
    fi

    log "Получение информации о сегментах..." "INFO"
    log_command "psql -d postgres -Atc \"SHOW unix_socket_directories;\""
    local socket_path=$(psql -d postgres -Atc "SHOW unix_socket_directories;" | head -n1 | tr -d ' ' 2>> "$cmd_log_file")
    
    log_command "psql -d postgres -Atc \"SELECT port, hostname, datadir, (regexp_matches(datadir, '[^/]+$'))[1] as seg_name FROM gp_segment_configuration WHERE role != 'm' ORDER BY CASE WHEN content = -1 THEN 0 ELSE 1 END, content;\""
    segments_info=$(psql -d postgres -Atc "
        SELECT port, hostname, datadir, 
               (regexp_matches(datadir, '[^/]+$'))[1] as seg_name
        FROM gp_segment_configuration
        WHERE role != 'm'
        ORDER BY 
            CASE WHEN content = -1 THEN 0 ELSE 1 END,
            content;" 2>> "$cmd_log_file")

    segment_sections=""
    while read -r line; do
        IFS='|' read -r port hostname datadir seg_name <<< "$line"
        
        # Определяем режим работы (централизованный или локальный)
        local host_params=""
        if [ -n "$storage_host" ]; then
            # Централизованный режим: добавляем параметры хоста
            host_params="  pg1-host = $hostname\n  pg1-host-user = $current_user\n"
        fi
        
        section="[$seg_name]
  pg1-path = $datadir
  pg1-port = $port
${host_params}  pg1-user = $current_user
  pg1-socket-path = $socket_path\n"
        
        segment_sections+="$section"
        
        # Формируем конфиг для каждого хоста
        local segment_config="[$seg_name]
  pg1-path = $datadir
  pg1-port = $port\n"
        
        if [ -n "$storage_host" ]; then
            segment_config+="  repo1-host = $storage_host\n  repo1-host-user = $current_user\n\n"
        else
            segment_config+="\n"
        fi
        
        host_segments[$hostname]+="$segment_config"
    done <<< "$segments_info"

    mkdir -p "$config_dir"
    log_command "mkdir -p \"$config_dir\""
    local main_config="$config_dir/pgbackrest.conf"
    backup_config "$main_config"
    
    echo -e "$global_section\n\n$segment_sections" > "$main_config"
    log "Основной конфиг создан: $main_config" "INFO"
}

# Функция для создания файлов для хостов
function create_host_configs() {
    echo -e "\n${YELLOW}=== СОЗДАНИЕ КОНФИГОВ ДЛЯ ХОСТОВ ===${NC}"
    
    if [ ${#host_segments[@]} -eq 0 ]; then
        log "Ошибка: сначала создайте основной конфиг!" "ERROR"
        return 1
    fi

    if [ -z "$config_dir" ]; then
        setup_config_dir
    fi

    for hostname in "${!host_segments[@]}"; do
        # Определяем глобальную секцию для конфига хоста
        local global_section_to_use
        if [ -z "$storage_host" ]; then
            # Локальный режим: используем полную глобальную секцию
            global_section_to_use="$global_section"
        else
            # Централизованный режим: используем сокращенную глобальную секцию
            global_section_to_use="$host_global_section"
        fi
        
        # Для хранилища в централизованном режиме не создаем отдельный конфиг
        if [ "$hostname" == "$storage_host" ]; then
            continue
        fi
        
        local host_config="${global_section_to_use}\n\n${host_segments[$hostname]}"
        local config_file="$config_dir/pgbackrest-$hostname.conf"
        
        backup_config "$config_file"
        log_command "echo -e \"$host_config\" > \"$config_file\""
        echo -e "$host_config" > "$config_file"
        log "Создан конфиг для $hostname: $config_file" "INFO"
    done
}

# Функция для проверки подключения к хостам
function check_host_connectivity() {
    local host=$1
    log_command "ping -c 1 \"$host\""
    if ! ping -c 1 "$host" &>> "$cmd_log_file"; then
        log "Хост $host недоступен по ping" "WARN"
        return 1
    fi
    
    log_command "ssh -o ConnectTimeout=5 \"$host\" exit"
    if ! ssh -o ConnectTimeout=5 "$host" exit &>> "$cmd_log_file"; then
        log "Не удалось подключиться по SSH к хосту $host" "ERROR"
        return 1
    fi
    
    return 0
}

# Функция для проверки и добавления строки в .bashrc
function manage_bashrc() {
    local host=$1
    local action=$2
    local bashrc_line="export PGOPTIONS=\"-c gp_session_role=utility\""
    
    # Не добавляем строку на мастер-хост
    if [ "$host" == "$current_host" ]; then
        log "Пропускаем добавление строки в .bashrc на мастер-хосте ($host)" "DEBUG"
        return 0
    fi
    
    if [ "$action" == "add" ]; then
        # Проверяем, есть ли уже такая строка
        log_command "ssh \"$host\" \"grep -qF \\\"$bashrc_line\\\" ~/.bashrc\""
        if ! ssh "$host" "grep -qF \"$bashrc_line\" ~/.bashrc" 2>> "$cmd_log_file"; then
            # Проверяем, есть ли похожие строки
            log_command "ssh \"$host\" \"grep -i 'PGOPTIONS' ~/.bashrc\""
            local similar_lines=$(ssh "$host" "grep -i 'PGOPTIONS' ~/.bashrc" 2>/dev/null)
            
            if [ -n "$similar_lines" ]; then
                log "Найдены похожие строки в .bashrc на хосте $host:" "WARN"
                echo "$similar_lines"
                read -p "Вы уверены, что хотите добавить новую строку? (y/n): " confirm
                if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
                    log "Добавление строки отменено пользователем" "INFO"
                    return 0
                fi
            fi
            
            log_command "ssh \"$host\" \"echo 'export PGOPTIONS=\\\"-c gp_session_role=utility\\\"' >> ~/.bashrc; source ~/.bashrc\""
            ssh "$host" "echo 'export PGOPTIONS=\"-c gp_session_role=utility\"' >> ~/.bashrc; source ~/.bashrc" &>> "$cmd_log_file"
            log "Добавлена строка в .bashrc на хосте $host" "INFO"
        else
            log "Строка уже присутствует в .bashrc на хосте $host" "DEBUG"
        fi
    else
        # Удаляем только точное совпадение строки
        log_command "ssh \"$host\" \"sed -i '/^export PGOPTIONS=\\\"-c gp_session_role=utility\\\"/d' ~/.bashrc\""
        ssh "$host" "sed -i '/^export PGOPTIONS=\"-c gp_session_role=utility\"/d' ~/.bashrc" &>> "$cmd_log_file"
        log "Удалена строка из .bashrc на хосте $host" "INFO"
    fi
}

# Функция для отправки файла со списком хостов на хранилище
function deploy_hosts_list() {
    if [ -z "$storage_host" ]; then
        log "Хост хранилища не установлен, пропускаем отправку списка хостов" "INFO"
        return 0
    fi

    local hosts_list_file="$config_dir/$host_list_file"
    if [ ! -f "$hosts_list_file" ]; then
        log "Файл списка хостов $hosts_list_file не найден!" "ERROR"
        return 1
    fi

    log "Отправка файла списка хостов на хост хранилища ($storage_host)..." "INFO"
    log_command "scp \"$hosts_list_file\" \"$storage_host:~/\""
    scp "$hosts_list_file" "$storage_host:~/"
    if [ $? -eq 0 ]; then
        log "Файл списка хостов успешно отправлен на хост хранилища" "INFO"
        return 0
    else
        log "Ошибка при отправке файла списка хостов на хост хранилища" "ERROR"
        return 1
    fi
}

# Функция для доставки конфигов на хосты
function deploy_configs() {
    echo -e "\n${YELLOW}=== ДОСТАВКА КОНФИГОВ НА ХОСТЫ ===${NC}"
    
    if [ -z "$config_dir" ]; then
        log "Директория конфигурации не установлена!" "ERROR"
        return 1
    fi
    
    log "Получение списка хостов из Greenplum..." "INFO"
    log_command "psql -d postgres -Atc \"SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;\""
    local db_hosts=$(psql -d postgres -Atc "SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;" 2>> "$cmd_log_file")
    
    # Добавляем хост хранилища в список (если задан)
    if [ -n "$storage_host" ]; then
        db_hosts+=" $storage_host"
    fi
    
    # Добавляем текущий хост (мастер) в список
    db_hosts+=" $current_host"
    # Удаляем дубликаты
    db_hosts=$(echo "$db_hosts" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    
    # Создаем временный каталог для копирования
    local temp_dir="$log_dir/temp_deploy"
    mkdir -p "$temp_dir"
    log_command "mkdir -p \"$temp_dir\""
    
    echo -e "\n${CYAN}Будут отправлены следующие файлы:${NC}"
    for host in $db_hosts; do
        # Для каждого хоста определяем правильный конфиг
        local config_file
        if [ -z "$storage_host" ]; then
            # Локальный режим: используем host-specific конфиг
            config_file="$config_dir/pgbackrest-$host.conf"
        elif [ "$host" == "$storage_host" ]; then
            # Централизованный режим: основной конфиг для хранилища
            config_file="$config_dir/pgbackrest.conf"
        elif [ "$host" == "$current_host" ]; then
            # Конфиг для мастера
            config_file="$config_dir/pgbackrest-$host.conf"
        else
            # Конфиг для сегментов
            config_file="$config_dir/pgbackrest-$host.conf"
        fi
        
        if [ -f "$config_file" ]; then
            if [ "$host" == "$current_host" ]; then
                # Для локального хоста просто копируем файл
                echo -e "${GREEN}$config_file ${YELLOW}=> ${BLUE}локальный хост (~/pgbackrest.conf)${NC}"
                cp "$config_file" ~/pgbackrest.conf
                chmod 600 ~/pgbackrest.conf
                log "Конфиг скопирован на локальный хост: ~/pgbackrest.conf" "INFO"
            else
                echo -e "${GREEN}$config_file ${YELLOW}=> ${BLUE}$host:~/pgbackrest.conf${NC}"
                cp "$config_file" "$temp_dir/pgbackrest.conf.$host"
                log_command "cp \"$config_file\" \"$temp_dir/pgbackrest.conf.$host\""
            fi
        else
            log "Конфиг для хоста $host не найден: $config_file" "ERROR"
            continue
        fi
    done
    
    read -p $'\n'"Вы уверены, что хотите отправить эти файлы? (y/n) " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "Отправка файлов отменена пользователем" "INFO"
        rm -rf "$temp_dir"
        log_command "rm -rf \"$temp_dir\""
        return 0
    fi
    
    # Копируем файлы на все хосты (кроме локального)
    log "Копирование конфигов на хосты..." "INFO"
    for host in $db_hosts; do
        if [ "$host" == "$current_host" ]; then
            continue
        fi
        
        if [ -f "$temp_dir/pgbackrest.conf.$host" ]; then
            log_command "scp \"$temp_dir/pgbackrest.conf.$host\" \"$host:~/pgbackrest.conf\""
            scp "$temp_dir/pgbackrest.conf.$host" "$host:~/pgbackrest.conf" &>> "$cmd_log_file"
            log_command "ssh \"$host\" \"chmod 600 ~/pgbackrest.conf\""
            ssh "$host" "chmod 600 ~/pgbackrest.conf" &>> "$cmd_log_file"
            log "Конфиг доставлен на хост $host" "INFO"
        fi
    done
    
    # Проверяем результат
    local success=0
    local fail=0
    for host in $db_hosts; do
        if [ "$host" == "$current_host" ]; then
            # Проверка для локального хоста
            if [ -f ~/pgbackrest.conf ]; then
                log "Конфиг успешно доставлен на локальный хост" "INFO"
                ((success++))
            else
                log "Ошибка при копировании конфига на локальный хост" "ERROR"
                ((fail++))
            fi
        else
            log_command "ssh \"$host\" \"[ -f ~/pgbackrest.conf ]\""
            if ssh "$host" "[ -f ~/pgbackrest.conf ]" &>> "$cmd_log_file"; then
                log "Конфиг успешно доставлен на хост $host" "INFO"
                ((success++))
            else
                log "Ошибка при доставке конфига на хост $host" "ERROR"
                ((fail++))
            fi
        fi
    done
    
    echo -e "\n${GREEN}Успешно: $success ${NC}| ${RED}Ошибки: $fail${NC}"
    
    # Отправляем файл со списком хостов на хранилище (если задано)
    deploy_hosts_list
    
    rm -rf "$temp_dir"
    log_command "rm -rf \"$temp_dir\""
}

# Функция для удаления конфигов с хостов
function remove_configs() {
    echo -e "\n${YELLOW}=== УДАЛЕНИЕ КОНФИГОВ С ХОСТОВ ===${NC}"
    
    log "Получение списка хостов из Greenplum..." "INFO"
    log_command "psql -d postgres -Atc \"SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;\""
    local db_hosts=$(psql -d postgres -Atc "SELECT DISTinct hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;" 2>> "$cmd_log_file")
    
    # Добавляем хост хранилища в список (если задан)
    if [ -n "$storage_host" ]; then
        db_hosts+=" $storage_host"
    fi
    
    # Добавляем текущий хост (мастер) в список
    db_hosts+=" $current_host"
    
    log "Удаление конфигов..." "INFO"
    # Обработка локального хоста
    if [ -f ~/pgbackrest.conf ]; then
        rm -f ~/pgbackrest.conf
        log "Конфиг удален с локального хоста" "INFO"
    fi
    
    # Обработка удаленных хостов
    for host in $db_hosts; do
        if [ "$host" != "$current_host" ]; then
            log_command "ssh \"$host\" \"rm -f ~/pgbackrest.conf\""
            ssh "$host" "rm -f ~/pgbackrest.conf" &>> "$cmd_log_file"
        fi
    done
    
    local success=0
    local fail=0
    for host in $db_hosts; do
        if [ "$host" == "$current_host" ]; then
            if [ ! -f ~/pgbackrest.conf ]; then
                log "Конфиг успешно удален с локального хоста" "INFO"
                ((success++))
            else
                log "Ошибка при удалении конфига с локального хоста" "ERROR"
                ((fail++))
            fi
        else
            log_command "ssh \"$host\" \"[ ! -f ~/pgbackrest.conf ]\""
            if ssh "$host" "[ ! -f ~/pgbackrest.conf ]" &>> "$cmd_log_file"; then
                log "Конфиг успешно удален с хоста $host" "INFO"
                ((success++))
            else
                log "Ошибка при удалении конфига с хоста $host" "ERROR"
                ((fail++))
            fi
        fi
    done
    
    echo -e "\n${GREEN}Успешно: $success ${NC}| ${RED}Ошибки: $fail${NC}"
}

# Функция отката изменений
function rollback_changes() {
    while true; do
        echo -e "\n${YELLOW}=== ОТКАТ ИЗМЕНЕНИЙ ===${NC}"
        
        local options=(
            "Удалить строку из .bashrc на всех хостах"
            "Удалить доставленные конфиги с хостов"
            "Полный откат (все вышеперечисленное)"
            "Вернуться в меню"
        )
        
        PS3="Выберите действие: "
        select opt in "${options[@]}"; do
            case $REPLY in
                1)
                    log "Удаление строки из .bashrc..." "INFO"
                    log_command "psql -d postgres -Atc \"SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;\""
                    local db_hosts=$(psql -d postgres -Atc "SELECT DISTinct hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;" 2>> "$cmd_log_file")
                    for host in $db_hosts; do
                        manage_bashrc "$host" "remove"
                    done
                    break
                    ;;
                2)
                    remove_configs
                    break
                    ;;
                3)
                    log "Выполнение полного отката..." "INFO"
                    log_command "psql -d postgres -Atc \"SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;\""
                    local db_hosts=$(psql -d postgres -Atc "SELECT DISTinct hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;" 2>> "$cmd_log_file")
                    for host in $db_hosts; do
                        manage_bashrc "$host" "remove"
                    done
                    remove_configs
                    log "Полный откат изменений завершен" "INFO"
                    break
                    ;;
                4)
                    return 0
                    ;;
                *)
                    log "Неверный выбор" "ERROR"
                    ;;
            esac
        done
    done
}

# Функция подготовки хостов
function prepare_hosts() {
    echo -e "\n${YELLOW}=== ПОДГОТОВКА ХОСТОВ ===${NC}"
    
    log "Получение списка хостов..." "INFO"
    log_command "psql -d postgres -Atc \"SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;\""
    local db_hosts=$(psql -d postgres -Atc "SELECT DISTinct hostname FROM gp_segment_configuration WHERE role != 'm' ORDER BY hostname;" 2>> "$cmd_log_file")
    
    for host in $db_hosts; do
        if check_host_connectivity "$host"; then
            manage_bashrc "$host" "add"
        fi
    done
    
    log "Подготовка хостов завершена" "INFO"
}

# Функция для просмотра конфигов
function view_configs() {
    echo -e "\n${YELLOW}=== ПРОСМОТР КОНФИГУРАЦИОННЫХ ФАЙЛОВ ===${NC}"
    
    # Основные файлы для просмотра
    local main_files=("$config_dir/pgbackrest.conf" "$config_dir/$host_list_file")
    local host_configs=($(ls "$config_dir"/pgbackrest-*.conf 2>/dev/null | grep -v "$config_dir/pgbackrest.conf"))
    
    echo -e "\n${CYAN}Основные конфигурационные файлы:${NC}"
    for file in "${main_files[@]}"; do
        if [ -f "$file" ]; then
            echo -e "\n${YELLOW}Файл: $file${NC}"
            cat "$file"
        else
            log "Файл $file не найден" "WARN"
        fi
    done
    
    if [ ${#host_configs[@]} -gt 0 ]; then
        echo -e "\n${CYAN}Конфиги для хостов:${NC}"
        read -p "Показать конфиги для хостов? (y/n): " show_host_configs
        if [[ "$show_host_configs" =~ ^[Yy]$ ]]; then
            for file in "${host_configs[@]}"; do
                echo -e "\n${YELLOW}Файл: $file${NC}"
                cat "$file"
            done
        fi
    fi
}

# Меню настроек
function config_menu() {
    while true; do
        echo -e "\n${YELLOW}=== НАСТРОЙКИ ===${NC}"
        echo "1. Настроить глобальные параметры"
        echo "2. Настроить хост хранилища"
        echo "3. Настроить директорию конфигурации"
        echo "4. Вернуться в главное меню"
        
        read -p "Выберите действие: " choice
        
        case $choice in
            1) setup_global_params ;;
            2) setup_storage_host ;;
            3) setup_config_dir ;;
            4) break ;;
            *) log "Неверный выбор" "ERROR" ;;
        esac
    done
}

# Меню генерации конфигурации
function generation_menu() {
    while true; do
        echo -e "\n${YELLOW}=== ГЕНЕРАЦИЯ КОНФИГУРАЦИИ ===${NC}"
        echo "1. Создать основной конфиг"
        echo "2. Создать конфиги для хостов"
        echo "3. Сгенерировать список хостов"
        echo "4. Вернуться в главное меню"
        
        read -p "Выберите действие: " choice
        
        case $choice in
            1) create_main_config ;;
            2) create_host_configs ;;
            3) generate_hosts_list ;;
            4) break ;;
            *) log "Неверный выбор" "ERROR" ;;
        esac
    done
}

# Главное меню
function main_menu() {
    # Проверка зависимостей
    if ! check_dependencies; then
        exit 1
    fi
    
    # Проверка доступности Greenplum
    if ! check_greenplum_availability; then
        exit 1
    fi
    
    # Создаем директории для логов
    mkdir -p "$log_dir" "$backup_dir" "$config_dir"
    log_command "mkdir -p \"$log_dir\" \"$backup_dir\" \"$config_dir\""
    > "$cmd_log_file"
    
    log "Скрипт запущен. Логи будут сохранены в $log_file" "INFO"
    log "Команды логируются в $cmd_log_file" "DEBUG"
    
    while true; do
        echo -e "\n${YELLOW}=== ГЛАВНОЕ МЕНЮ ===${NC}"
        echo "Текущая директория конфигов: $config_dir"
        echo "Директория бэкапов: $backup_dir"
        echo "1. Настройки"
        echo "2. Генерация конфигурации"
        echo "3. Редактировать конфиг"
        echo "4. Восстановить из бэкапа"
        echo "5. Просмотр конфигов"
        echo "6. Подготовка хостов"
        echo "7. Доставка конфигов"
        echo "8. Откат изменений"
        echo "9. Выполнить все этапы"
        echo "10. Выход"
        
        read -p "Выберите действие: " choice
        
        case $choice in
            1) config_menu ;;
            2) generation_menu ;;
            3) edit_config ;;
            4) restore_from_backup ;;
            5) view_configs ;;
            6) prepare_hosts ;;
            7) deploy_configs ;;
            8) rollback_changes ;;
            9) 
                setup_global_params 
                setup_storage_host
                create_main_config
                create_host_configs
                generate_hosts_list
                prepare_hosts
                deploy_configs
                ;;
            10) 
                echo -e "\n${GREEN}Лог-файл: ${YELLOW}$log_file${NC}"
                echo -e "${GREEN}Лог команд: ${YELLOW}$cmd_log_file${NC}\n"
                exit 0 
                ;;
            *) log "Неверный выбор" "ERROR" ;;
        esac
    done
}

# Запуск программы
main_menu
