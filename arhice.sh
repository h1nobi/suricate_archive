#!/bin/sh

LOG_DIR="/var/log/suricata"
ARCHIVE_BASE="/var/log/suricata/archives"
DRY_RUN=false  # Установите true для тестирования без реального удаления

echo "=== Архивация логов Suricata с портами ==="

# Создаем базовую директорию для архивов
mkdir -p "$ARCHIVE_BASE" 2>/dev/null

# Функция для получения недели из даты
get_week_info() {
    local date_str="$1"
    local year month day
    
    case "$date_str" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9])
            year=$(echo "$date_str" | cut -c1-4)
            month=$(echo "$date_str" | cut -c5-6)
            day=$(echo "$date_str" | cut -c7-8)
            ;;
        [0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9])
            year=$(echo "$date_str" | cut -c1-4)
            month=$(echo "$date_str" | cut -c6-7)
            day=$(echo "$date_str" | cut -c8-9)
            ;;
        *)
            echo ""
            return
            ;;
    esac
    
    week_num=$(date -jf "%Y%m%d" "${year}${month}${day}" "+%V" 2>/dev/null || echo "0")
    
    monday=$(date -jf "%Y%m%d" "${year}${month}${day}" "+%u" 2>/dev/null)
    if [ -n "$monday" ]; then
        if [ "$monday" = "1" ]; then
            monday_date=$(date -jf "%Y%m%d" "${year}${month}${day}" "+%d.%m.%Y" 2>/dev/null)
        else
            days_back=$((monday - 1))
            monday_date=$(date -jv-${days_back}d -f "%Y%m%d" "${year}${month}${day}" "+%d.%m.%Y" 2>/dev/null)
        fi
    fi
    
    if [ -n "$week_num" ] && [ -n "$monday_date" ]; then
        echo "${week_num}-${monday_date}"
    else
        echo ""
    fi
}

total_archives=0
total_files=0
total_deleted=0

# Создаем временный каталог для списков файлов
TMP_DIR=$(mktemp -d -t suricata_archive.XXXXXX) 2>/dev/null
FILES_TO_DELETE="$TMP_DIR/files_to_delete.list"

# Функция для безопасного удаления
safe_delete() {
    local file="$1"
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Удалить $file"
    else
        rm -f "$file" 2>/dev/null && {
            echo "Удалено: $file"
            return 0
        } || {
            echo "Ошибка удаления: $file"
            return 1
        }
    fi
}

# Обрабатываем только подпапки (порты)
for port_dir in "$LOG_DIR"/*/; do
    # Проверяем, что это директория
    [ -d "$port_dir" ] || continue
    
    # Пропускаем папку архивов, если она уже существует
    if [ "$port_dir" = "$ARCHIVE_BASE/" ]; then
        continue
    fi
    
    port_name=$(basename "$port_dir" 2>/dev/null)
    
    # Создаем папку для архивов этого порта
    port_archive_dir="$ARCHIVE_BASE/$port_name"
    mkdir -p "$port_archive_dir" 2>/dev/null
    
    # Переходим в папку порта
    if cd "$port_dir" 2>/dev/null; then
        # Ищем файлы с датами в имени
        for file in *.*[0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9]*; do
            # Проверяем, что файл существует (не шаблон)
            [ -f "$file" ] || continue
            
            # Пропускаем архивы
            case "$file" in
                *.tar.gz|*.gz|*.xz|*.bz2)
                    continue
                    ;;
            esac
            
            # Извлекаем дату из имени файла
            date_part=$(echo "$file" | sed -E 's/.*\.([0-9].*)/\1/' 2>/dev/null)
            
            # Получаем информацию о неделе
            week_info=$(get_week_info "$date_part")
            if [ -z "$week_info" ]; then
                continue
            fi
            
            # Получаем базовое имя файла (без даты)
            base_name=$(echo "$file" | sed 's/\.[0-9].*//' 2>/dev/null)
            week_num=$(echo "$week_info" | cut -d'-' -f1)
            monday_date=$(echo "$week_info" | cut -d'-' -f2)
            
            # Создаем уникальный ключ для группы файлов
            archive_key="${base_name}-${week_num}-${monday_date}"
            total_files=$((total_files + 1))
            
            # Добавляем файл в список для этой группы
            list_file="$TMP_DIR/${port_name}_${archive_key}.list"
            echo "$file" >> "$list_file" 2>/dev/null
            
            # Добавляем файл в список на удаление
            echo "$(pwd)/$file" >> "$FILES_TO_DELETE" 2>/dev/null
        done
        
        # Создаем архивы для этого порта
        for list_file in "$TMP_DIR"/${port_name}_*.list; do
            [ -f "$list_file" ] || continue
            
            # Извлекаем ключ архива из имени файла
            archive_key=$(basename "$list_file" 2>/dev/null | sed "s/^${port_name}_//; s/\.list$//")
            
            # Создаем имя архива
            archive_name="${archive_key}.tar.gz"
            archive_path="$port_archive_dir/$archive_name"
            
            # Создаем архив со всеми файлами из списка
            if [ "$DRY_RUN" = true ]; then
                echo "DRY RUN: Создать архив $archive_path из файлов в $list_file"
            else
                tar -czf "$archive_path" -T "$list_file" 2>/dev/null
            fi
            
            if [ "$DRY_RUN" != true ] && [ -f "$archive_path" ]; then
                total_archives=$((total_archives + 1))
            fi
            
            # Удаляем временный файл списка
            rm -f "$list_file" 2>/dev/null
        done
    fi
done

echo ""
echo "=== Удаление заархивированных файлов ==="

# Удаляем файлы, которые были успешно заархивированы
if [ -f "$FILES_TO_DELETE" ]; then
    while IFS= read -r file_to_delete; do
        if [ -f "$file_to_delete" ]; then
            safe_delete "$file_to_delete"
            if [ $? -eq 0 ] && [ "$DRY_RUN" != true ]; then
                total_deleted=$((total_deleted + 1))
            fi
        fi
    done < "$FILES_TO_DELETE"
    
    # Удаляем сам список файлов
    rm -f "$FILES_TO_DELETE" 2>/dev/null
fi

echo ""
echo "=== Удаление временных файлов в /tmp/ ==="

# Удаляем временные файлы в /tmp/ с похожими именами
tmp_files_to_delete=0
for tmp_file in /tmp/suricata_archive.* /tmp/*suricata* 2>/dev/null; do
    [ -e "$tmp_file" ] || continue
    
    # Пропускаем каталоги (хотя в /tmp/ не должно быть каталогов с таким именем)
    [ -d "$tmp_file" ] && continue
    
    # Проверяем, что файл создан нашим скриптом (по шаблону имени)
    case "$(basename "$tmp_file")" in
        suricata_archive.*|*suricata*)
            safe_delete "$tmp_file"
            if [ $? -eq 0 ] && [ "$DRY_RUN" != true ]; then
                tmp_files_to_delete=$((tmp_files_to_delete + 1))
            fi
            ;;
    esac
done

# Удаляем временный каталог
if [ -d "$TMP_DIR" ]; then
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Удалить временный каталог $TMP_DIR"
    else
        rm -rf "$TMP_DIR" 2>/dev/null && echo "Удален временный каталог: $TMP_DIR"
    fi
fi


if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "ВНИМАНИЕ: Режим тестирования (DRY RUN). Файлы не были изменены."
fi

echo "=== Завершено ==="