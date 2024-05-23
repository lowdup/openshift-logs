#!/bin/bash

# Файл со списком кластеров
CLUSTERS_FILE="clusters.txt"

# Список ресурсов для работы
RESOURCES=(dc gw svc route deploy se vs dr cm EnvoyFilter secret)

# Функция для окрашивания текста
color_text() {
    case $1 in
        "red") echo -e "\e[31m$2\e[0m" ;;
        "green") echo -e "\e[32m$2\e[0m" ;;
        "yellow") echo -e "\e[33m$2\e[0m" ;;
        "light_blue") echo -e "\e[96m$2\e[0m" ;;
        "cyan") echo -e "\e[36m$2\e[0m" ;;
        "magenta") echo -e "\e[35m$2\e[0m" ;;
        "white") echo -e "\e[97m$2\e[0m" ;;
        "bold") echo -e "\e[1m$2\e[0m" ;;
        *) echo "$2" ;;
    esac
}

# Функция для выбора кластера
choose_cluster() {
    color_text "light_blue" "Выберите кластер из списка или введите 'all' для получения списка namespaces со всех кластеров:"
    mapfile -t clusters < "$CLUSTERS_FILE"
    for i in "${!clusters[@]}"; do
        index=$((i+1))
        cluster="${clusters[$i]}"
        cluster_url=$(echo "$cluster" | cut -d'=' -f1)
        color_text "green" "$index) $(color_text "cyan" "$cluster_url")"
    done
    read -p "Введите номер кластера или 'all': " cluster_index

    if [[ "$cluster_index" == "all" ]]; then
        get_all_namespaces
    else
        cluster_index=$((cluster_index-1))
        cluster="${clusters[$cluster_index]}"
        IFS='=' read -r cluster_url token <<< "$cluster"
        if [[ -z "$token" ]]; then
            color_text "light_blue" "Токен для $(color_text "cyan" "$cluster_url") не найден. Пожалуйста, авторизуйтесь."
            login_to_cluster "$cluster_url" "$cluster_index"
        else
            oc login --token="$token" --server="$cluster_url" &>/dev/null
            if [[ $? -ne 0 ]]; then
                color_text "red" "Токен недействителен. Пожалуйста, авторизуйтесь."
                login_to_cluster "$cluster_url" "$cluster_index"
            fi
        fi
        choose_namespace "$cluster_url"
    fi
}

# Функция для получения списка namespaces со всех кластеров
get_all_namespaces() {
    color_text "light_blue" "Получение списка namespaces со всех кластеров..."
    namespaces=()
    login_required=false
    while IFS= read -r line; do
        IFS='=' read -r cluster_url token <<< "$line"
        if [[ -z "$token" || "$(oc login --token="$token" --server="$cluster_url" &>/dev/null; echo $?)" -ne 0 ]]; then
            login_required=true
        fi
    done < "$CLUSTERS_FILE"

    if [[ "$login_required" == true ]]; then
        read -p "Введите логин: " username
        read -sp "Введите пароль: " password
        echo
    fi

    while IFS= read -r line; do
        IFS='=' read -r cluster_url token <<< "$line"
        if [[ -z "$token" || "$(oc login --token="$token" --server="$cluster_url" &>/dev/null; echo $?)" -ne 0 ]]; then
            oc login --username="$username" --password="$password" --server="$cluster_url" &>/dev/null
            if [[ $? -eq 0 ]]; then
                token=$(oc whoami -t)
                update_cluster_token "$cluster_url" "$token"
            else
                color_text "red" "Не удалось авторизоваться для $(color_text "cyan" "$cluster_url"). Пропуск..."
                continue
            fi
        fi

        cluster_namespaces=$(oc projects -q)
        for ns in $cluster_namespaces; do
            namespaces+=("${cluster_url}=${ns}")
        done
    done < "$CLUSTERS_FILE"

    color_text "light_blue" "Найдены namespaces:"
    for i in "${!namespaces[@]}"; do
        index=$((i+1))
        IFS='=' read -r cluster_url ns <<< "${namespaces[$i]}"
        cluster_url_clean=$(echo "$cluster_url" | sed 's|https://||')
        color_text "green" "$index) $(color_text "magenta" "$ns") (Кластер: $(color_text "cyan" "$cluster_url_clean"))"
    done
    read -p "Введите номер namespace для подключения или 'back' для возврата к выбору кластера: " ns_index

    if [[ "$ns_index" == "back" ]]; then
        choose_cluster
    else
        ns_index=$((ns_index-1))
        IFS='=' read -r cluster_url namespace <<< "${namespaces[$ns_index]}"
        authorize_and_choose_action "$cluster_url" "$namespace"
    fi
}

# Функция для авторизации в кластере
login_to_cluster() {
    cluster_url="$1"
    read -p "Введите логин: " username
    read -sp "Введите пароль: " password
    echo
    oc login --username="$username" --password="$password" --server="$cluster_url" &>/dev/null
    if [[ $? -eq 0 ]]; then
        token=$(oc whoami -t)
        update_cluster_token "$cluster_url" "$token"
        color_text "green" "Успешная авторизация."
    else
        color_text "red" "Не удалось авторизоваться."
    fi
}

# Функция для обновления токена в файле
update_cluster_token() {
    cluster_url="$1"
    token="$2"
    clusters=($(cat "$CLUSTERS_FILE"))
    for i in "${!clusters[@]}"; do
        if [[ "${clusters[$i]}" == "$cluster_url"* ]]; then
            clusters[$i]="$cluster_url=$token"
        fi
    done
    printf "%s\n" "${clusters[@]}" > "$CLUSTERS_FILE"
}

# Функция для выбора namespace
choose_namespace() {
    cluster_url="$1"
    color_text "light_blue" "Получение списка проектов..."
    mapfile -t namespaces < <(oc projects -q)
    for i in "${!namespaces[@]}"; do
        index=$((i+1))
        color_text "green" "$index) $(color_text "magenta" "${namespaces[$i]}")"
    done
    read -p "Введите номер проекта: " namespace_index
    namespace_index=$((namespace_index-1))
    namespace="${namespaces[$namespace_index]}"
    choose_action "$cluster_url" "$namespace"
}

# Функция для авторизации и выбора действия с namespace
authorize_and_choose_action() {
    cluster_url="$1"
    namespace="$2"
    cluster_line=$(grep "$cluster_url" "$CLUSTERS_FILE")
    IFS='=' read -r _ token <<< "$cluster_line"
    if [[ -z "$token" ]]; then
        color_text "light_blue" "Токен для $(color_text "cyan" "$cluster_url") не найден. Пожалуйста, авторизуйтесь."
        login_to_cluster "$cluster_url"
    else
        oc login --token="$token" --server="$cluster_url" &>/dev/null
        if [[ $? -ne 0 ]]; then
            color_text "red" "Токен недействителен. Пожалуйста, авторизуйтесь."
            login_to_cluster "$cluster_url"
        fi
    fi
    choose_action "$cluster_url" "$namespace"
}

# Функция для выбора действия с namespace
choose_action() {
    cluster_url="$1"
    namespace="$2"
    while true; do
        color_text "light_blue" "Выберите действие для проекта $(color_text "magenta" "$namespace"):"
        options=("Выгрузить логи" "Скачать конфигурации" "Восстановить конфигурации" "Очистить namespace" "Вернуться к выбору кластера" "Выход")
        select opt in "${options[@]}"; do
            case $REPLY in
                1) export_logs "$cluster_url" "$namespace"; break ;;
                2) download_configs "$cluster_url" "$namespace"; break ;;
                3) restore_configs "$cluster_url" "$namespace"; break ;;
                4) confirm_clear_namespace "$cluster_url" "$namespace"; break ;;
                5) choose_cluster; break ;;
                6) exit 0 ;;
                *) color_text "red" "Неверный выбор." ;;
            esac
        done
    done
}

# Функция для выгрузки логов
export_logs() {
    cluster_url="$1"
    namespace="$2"
    color_text "light_blue" "Получение списка подов..."
    mapfile -t pods < <(oc get pods -n "$namespace" -o custom-columns=NAME:.metadata.name --no-headers)
    for i in "${!pods[@]}"; do
        index=$((i+1))
        color_text "green" "$index) $(color_text "magenta" "${pods[$i]}")"
    done
    read -p "Введите номера подов через запятую или 'all' для выбора всех подов: " pod_indices
    if [[ "$pod_indices" == "all" || -з "$pod_indices" ]]; то
        selected_pods=("${pods[@]}")
    еще
        IFS=',' read -ra pod_indices_array <<< "$pod_indices"
        selected_pods=()
        для pod_index в "${pod_indices_array[@]}"; сделать
            pod_index=$((pod_index-1))
            selected_pods+=("${pods[$pod_index]}")
        сделать
    fi

    selected_containers=()
    для pod в "${selected_pods[@]}"; сделать
        mapfile -t контейнеры < <(oc get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n')
        color_text "light_blue" "Контейнеры в поде $(color_text "cyan" "$pod"):"
        для i в "${containers[@]}"; сделать
            index=$((i+1))
            color_text "green" "$index) $(color_text "magenta" "${containers[$i]}")"
        сделать
        read -p "Введите номера контейнеров через запятую или 'all' для выбора всех контейнеров в поде $pod: " container_indices
        если [[ "$container_indices" == "all" или -z "$container_indices" ]]; затем
            для контейнера в "${containers[@]}"; сделать
                selected_containers+=("$pod:$container")
            сделать
        еще
            IFS=',' read -ra container_indices_array <<< "$container_indices"
            для container_index в "${container_indices_array[@]}"; сделать
                container_index=$((container_index-1))
                selected_containers+=("$pod:${containers[$container_index]}")
            сделать
        fi
    done

    read -p "Введите время для логов (например 30m, 1h или 'all' для всех логов): " since_time
    log_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/log/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$log_dir"
    для контейнера в "${selected_containers[@]}"; сделать
        IFS=':' read -r pod container_name <<< "$container"
        color_text "magenta" "Под: $(color_text "cyan" "$pod")"
        log_file="$log_dir/${pod}_${container_name}.txt"
        если [[ "$since_time" == "all" ]]; затем
            oc logs "$pod" -c "$container_name" -n "$namespace" > "$log_file"
        else
            oc logs "$pod" -c "$container_name" -n "$namespace" --since="$since_time" > "$log_file"
        fi
        log_size=$(du -h "$log_file" | cut -f1)
        color_text "green" "Логи $(color_text "magenta" "$container_name") сохранены в $(color_text "cyan" "$log_file") (${log_size})"
    done
}

# Функция для скачивания конфигураций
download_configs() {
    cluster_url="$1"
    namespace="$2"
    color_text "light_blue" "Скачивание конфигураций..."
    backup_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    для ресурса в "${RESOURCES[@]}"; сделать
        color_text "light_blue" "Скачивается $(color_text "magenta" "$resource")..."
        oc get "$resource" -n "$namespace" -o yaml > "$backup_dir/${resource}.yaml"
    done
    color_text "green" "Конфигурации сохранены в $(color_text "cyan" "$backup_dir")"
}

# Функция для восстановления конфигураций
restore_configs() {
    cluster_url="$1"
    namespace="$2"
    color_text "light_blue" "Восстановление конфигураций..."
    backup_base_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/backup"
    если [[ ! -d "$backup_base_dir" ]]; затем
        color_text "red" "Директория с бэкапами не найдена: $(color_text "cyan" "$backup_base_dir")"
        вернуть
    fi

    backups=($(ls -dt "$backup_base_dir"/* | head -n 10))
    если [[ ${#backups[@]} -eq 0 ]]; затем
        color_text "red" "Бэкапы не найдены в $(color_text "cyan" "$backup_base_dir")"
        вернуть
    fi

    color_text "light_blue" "Выберите бэкап для восстановления:"
    для i в "${!backups[@]}"; сделать
        index=$((i+1))
        color_text "green" "$index) $(color_text "cyan" "${backups[$i]}")"
    сделать
    read -p "Введите номер бэкапа для восстановления: " backup_index
    backup_index=$((backup_index-1))

    backup_dir="${backups[$backup_index]}"
    для файла в "$backup_dir"/*.yaml; сделать
        color_text "light_blue" "Восстановление $(color_text "magenta" "$file")..."
        oc apply -f "$file" -n "$namespace" 2>/dev/null
    done
    color_text "green" "Конфигурации восстановлены из $(color_text "cyan" "$backup_dir")"
}

# Функция для подтверждения очистки namespace
confirm_clear_namespace() {
    cluster_url="$1"
    namespace="$2"
    color_text "red" "Уверены ли вы, что хотите очистить namespace $(color_text "magenta" "$namespace") в кластере $(color_text "cyan" "$cluster_url")? [yes/no]"
    read -p "" подтвердить
    если [[ "$confirm" == "yes" ]]; затем
        backup_before_clear "$cluster_url" "$namespace"
        clear_namespace "$cluster_url" "$namespace"
    еще
        color_text "green" "Очистка namespace отменена."
    fi
}

# Функция для создания бэкапа перед очисткой namespace
backup_before_clear() {
    cluster_url="$1"
    namespace="$2"
    color_text "light_blue" "Создание бэкапа перед очисткой namespace..."
    backup_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/backup/delete_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    для ресурса в "${RESOURCES[@]}"; сделать
        oc get "$resource" -n "$namespace" -o yaml > "$backup_dir/${resource}.yaml"
    done
    color_text "green" "Бэкап сохранен в $(color_text "cyan" "$backup_dir")"
}

# Функция для очистки namespace
clear_namespace() {
    cluster_url="$1"
    namespace="$2"
    color_text "light_blue" "Очистка namespace $(color_text "magenta" "$namespace") в кластере $(color_text "cyan" "$cluster_url")..."
    для ресурса в "${RESOURCES[@]}"; сделать
        oc delete "$resource" -n "$namespace" --all
    done
    color_text "green" "Namespace $(color_text "magenta" "$namespace") очищен."
}

# Основная функция
main() {
    если [[ ! -f "$CLUSTERS_FILE" ]]; затем
        color_text "red" "Файл $(color_text "cyan" "$CLUSTERS_FILE") не найден."
        выход 1
    fi
    choose_cluster
}

main
