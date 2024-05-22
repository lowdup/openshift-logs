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
        "light_blue") echo -e "\e[36m$2\e[0m" ;;
        "magenta") echo -e "\e[35m$2\e[0m" ;;
        "white") echo -e "\e[97m$2\e[0m" ;;
        *) echo "$2" ;;
    esac
}

# Функция для выбора кластера
choose_cluster() {
    color_text "yellow" "Выберите кластер из списка или введите 'all' для получения списка namespaces со всех кластеров:"
    mapfile -t clusters < "$CLUSTERS_FILE"
    for i in "${!clusters[@]}"; do
        index=$((i+1))
        cluster="${clusters[$i]}"
        cluster_url=$(echo "$cluster" | cut -d'=' -f1)
        color_text "green" "$index) $cluster_url"
    done
    read -p "Введите номер кластера или 'all': " cluster_index

    if [[ "$cluster_index" == "all" ]]; then
        get_all_namespaces
    else
        cluster_index=$((cluster_index-1))
        cluster="${clusters[$cluster_index]}"
        IFS='=' read -r cluster_url token <<< "$cluster"
        if [[ -z "$token" ]]; then
            color_text "yellow" "Токен для $cluster_url не найден. Пожалуйста, авторизуйтесь."
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
    while IFS= read -r line; do
        IFS='=' read -r cluster_url token <<< "$line"
        oc login --token="$token" --server="$cluster_url" &>/dev/null
        if [[ $? -eq 0 ]]; then
            cluster_namespaces=$(oc projects -q)
            for ns in $cluster_namespaces; do
                namespaces+=("$cluster_url:$ns")
            done
        else
            color_text "red" "Не удалось подключиться к $cluster_url"
        fi
    done < "$CLUSTERS_FILE"

    color_text "yellow" "Найдены namespaces:"
    for i in "${!namespaces[@]}"; do
        index=$((i+1))
        IFS=':' read -r cluster_url ns <<< "${namespaces[$i]}"
        cluster_url_clean=$(echo "$cluster_url" | sed 's|https://||')
        color_text "green" "$index) $ns (Кластер: $cluster_url_clean)"
    done
    read -p "Введите номер namespace для подключения или 'back' для возврата к выбору кластера: " ns_index

    if [[ "$ns_index" == "back" ]]; then
        choose_cluster
    else
        ns_index=$((ns_index-1))
        IFS=':' read -r cluster_url namespace <<< "${namespaces[$ns_index]}"
        choose_action "$cluster_url" "$namespace"
    fi
}

# Функция для авторизации в кластере
login_to_cluster() {
    cluster_url="$1"
    cluster_index="$2"
    read -p "Введите логин: " username
    read -sp "Введите пароль: " password
    echo
    oc login --username="$username" --password="$password" --server="$cluster_url" &>/dev/null
    if [[ $? -eq 0 ]]; then
        token=$(oc whoami -t)
        update_cluster_token "$cluster_url" "$token" "$cluster_index"
        color_text "green" "Успешная авторизация."
    else
        color_text "red" "Не удалось авторизоваться."
        exit 1
    fi
}

# Функция для обновления токена в файле
update_cluster_token() {
    cluster_url="$1"
    token="$2"
    cluster_index="$3"
    clusters=($(cat "$CLUSTERS_FILE"))
    clusters[$cluster_index]="$cluster_url=$token"
    printf "%s\n" "${clusters[@]}" > "$CLUSTERS_FILE"
}

# Функция для выбора namespace
choose_namespace() {
    cluster_url="$1"
    color_text "yellow" "Получение списка проектов..."
    mapfile -t namespaces < <(oc projects -q)
    for i in "${!namespaces[@]}"; do
        index=$((i+1))
        color_text "green" "$index) ${namespaces[$i]}"
    done
    read -p "Введите номер проекта: " namespace_index
    namespace_index=$((namespace_index-1))
    namespace="${namespaces[$namespace_index]}"
    choose_action "$cluster_url" "$namespace"
}

# Функция для выбора действия с namespace
choose_action() {
    cluster_url="$1"
    namespace="$2"
    while true; do
        color_text "yellow" "Выберите действие для проекта $namespace:"
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
    color_text "yellow" "Получение списка подов..."
    mapfile -t pods < <(oc get pods -n "$namespace" -o custom-columns=NAME:.metadata.name --no-headers)
    for i in "${!pods[@]}"; do
        index=$((i+1))
        color_text "green" "$index) ${pods[$i]}"
    done
    read -p "Введите номера подов через запятую или 'all' для выбора всех подов: " pod_indices
    if [[ "$pod_indices" == "all" || -z "$pod_indices" ]]; then
        selected_pods=("${pods[@]}")
    else
        IFS=',' read -ra pod_indices_array <<< "$pod_indices"
        selected_pods=()
        for pod_index in "${pod_indices_array[@]}"; do
            pod_index=$((pod_index-1))
            selected_pods+=("${pods[$pod_index]}")
        done
    fi

    selected_containers=()
    for pod in "${selected_pods[@]}"; do
        mapfile -t containers < <(oc get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n')
        color_text "yellow" "Контейнеры в поде $(color_text "cyan" "$pod"):"
        for i in "${!containers[@]}"; do
            index=$((i+1))
            color_text "green" "$index) ${containers[$i]}"
        done
        read -p "Введите номера контейнеров через запятую или 'all' для выбора всех контейнеров в поде $pod: " container_indices
        if [[ "$container_indices" == "all" || -z "$container_indices" ]]; then
            for container in "${containers[@]}"; do
                selected_containers+=("$pod:$container")
            done
        else
            IFS=',' read -ra container_indices_array <<< "$container_indices"
            for container_index in "${container_indices_array[@]}"; do
                container_index=$((container_index-1))
                selected_containers+=("$pod:${containers[$container_index]}")
            done
        fi
    done

    read -p "Введите время для логов (например 30m, 1h или 'all' для всех логов): " since_time
    log_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/log/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$log_dir"
    for container in "${selected_containers[@]}"; do
        IFS=':' read -r pod container_name <<< "$container"
        color_text "magenta" "Под: $(color_text "cyan" "$pod")"
        log_file="$log_dir/${pod}_${container_name}.txt"
        if [[ "$since_time" == "all" ]]; then
            oc logs "$pod" -c "$container_name" -n "$namespace" > "$log_file"
        else
            oc logs "$pod" -c "$container_name" -n "$namespace" --since="$since_time" > "$log_file"
        fi
        log_size=$(du -h "$log_file" | cut -f1)
        color_text "green" "Логи ${container_name} сохранены в $log_file (${log_size})"
    done
}

# Функция для скачивания конфигураций
download_configs() {
    cluster_url="$1"
    namespace="$2"
    color_text "yellow" "Скачивание конфигураций..."
    backup_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    for resource in "${RESOURCES[@]}"; do
        color_text "light_blue" "Скачивается $resource..."
        oc get "$resource" -n "$namespace" -o yaml > "$backup_dir/${resource}.yaml"
    done
    color_text "green" "Конфигурации сохранены в $backup_dir"
}

# Функция для восстановления конфигураций
restore_configs() {
    cluster_url="$1"
    namespace="$2"
    color_text "yellow" "Восстановление конфигураций..."
    backup_base_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/backup"
    if [[ ! -d "$backup_base_dir" ]]; then
        color_text "red" "Директория с бэкапами не найдена: $backup_base_dir"
        return
    fi

    backups=($(ls -dt "$backup_base_dir"/* | head -n 10))
    if [[ ${#backups[@]} -eq 0 ]]; then
        color_text "red" "Бэкапы не найдены в $backup_base_dir"
        return
    fi

    color_text "yellow" "Выберите бэкап для восстановления:"
    for i in "${!backups[@]}"; do
        index=$((i+1))
        color_text "green" "$index) ${backups[$i]}"
    done
    read -p "Введите номер бэкапа для восстановления: " backup_index
    backup_index=$((backup_index-1))

    backup_dir="${backups[$backup_index]}"
    for file in "$backup_dir"/*.yaml; do
        color_text "light_blue" "Восстановление $file..."
        oc apply -f "$file" -n "$namespace" 2>/dev/null
    done
    color_text "green" "Конфигурации восстановлены из $backup_dir"
}

# Функция для подтверждения очистки namespace
confirm_clear_namespace() {
    cluster_url="$1"
    namespace="$2"
    color_text "red" "Уверены ли вы, что хотите очистить namespace $namespace в кластере $cluster_url? [yes/no]"
    read -p "" confirm
    if [[ "$confirm" == "yes" ]]; then
        clear_namespace "$cluster_url" "$namespace"
    else
        color_text "green" "Очистка namespace отменена."
    fi
}

# Функция для очистки namespace
clear_namespace() {
    cluster_url="$1"
    namespace="$2"
    color_text "yellow" "Очистка namespace $namespace в кластере $cluster_url..."
    for resource in "${RESOURCES[@]}"; do
        oc delete "$resource" -n "$namespace" --all
    done
    color_text "green" "Namespace $namespace очищен."
}

# Основная функция
main() {
    if [[ ! -f "$CLUSTERS_FILE" ]]; then
        color_text "red" "Файл $CLUSTERS_FILE не найден."
        exit 1
    fi
    choose_cluster
}

main
