#!/bin/bash

# Файл со списком кластеров
CLUSTERS_FILE="clusters.txt"

# Функция для окрашивания текста
color_text() {
    case $1 in
        "red") echo -e "\e[31m$2\e[0m" ;;
        "green") echo -e "\e[32m$2\e[0m" ;;
        "yellow") echo -e "\e[33m$2\e[0m" ;;
        "blue") echo -e "\e[34m$2\e[0m" ;;
        *) echo "$2" ;;
    esac
}

# Функция для выбора кластера
choose_cluster() {
    color_text "yellow" "Выберите кластер из списка или введите 'all' для получения списка namespace со всех кластеров:"
    mapfile -t clusters < "$CLUSTERS_FILE"
    for i in "${!clusters[@]}"; do
        index=$((i+1))
        color_text "green" "$index) ${clusters[$i]}"
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
            login_to_cluster "$cluster_url"
        else
            oc login --token="$token" --server="$cluster_url" &>/dev/null
            if [[ $? -ne 0 ]]; then
                color_text "red" "Токен недействителен. Пожалуйста, авторизуйтесь."
                login_to_cluster "$cluster_url"
            fi
        fi
        choose_namespace "$cluster_url"
    fi
}

# Функция для получения списка namespace со всех кластеров
get_all_namespaces() {
    color_text "blue" "Получение списка namespace со всех кластеров..."
    while IFS= read -r line; do
        IFS='=' read -r cluster_url token <<< "$line"
        oc login --token="$token" --server="$cluster_url" &>/dev/null
        if [[ $? -eq 0 ]]; then
            oc get ns
        else
            color_text "red" "Не удалось подключиться к $cluster_url"
        fi
    done < "$CLUSTERS_FILE"
    exit 0
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
        exit 1
    fi
}

# Функция для обновления токена в файле
update_cluster_token() {
    cluster_url="$1"
    token="$2"
    if grep -q "^$cluster_url=" "$CLUSTERS_FILE"; then
        sed -i "s|^$cluster_url=.*|$cluster_url=$token|" "$CLUSTERS_FILE"
    else
        echo "$cluster_url=$token" >> "$CLUSTERS_FILE"
    fi
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
                4) clear_namespace "$namespace"; break ;;
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
    read -p "Введите номера подов через запятую: " pod_indices
    IFS=',' read -ra pod_indices_array <<< "$pod_indices"
    selected_pods=()
    for pod_index in "${pod_indices_array[@]}"; do
        pod_index=$((pod_index-1))
        selected_pods+=("${pods[$pod_index]}")
    done

    for pod in "${selected_pods[@]}"; do
        mapfile -t containers < <(oc get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n')
        for i in "${!containers[@]}"; do
            index=$((i+1))
            color_text "green" "$index) ${containers[$i]}"
        done
        read -p "Введите номера контейнеров через запятую для пода $pod: " container_indices
        IFS=',' read -ra container_indices_array <<< "$container_indices"
        selected_containers=()
        for container_index in "${container_indices_array[@]}"; do
            container_index=$((container_index-1))
            selected_containers+=("${containers[$container_index]}")
        done

        read -p "Введите время для логов (например 30m, 1h): " since_time
        log_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/log/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$log_dir"
        for container in "${selected_containers[@]}"; do
            oc logs "$pod" -c "$container" -n "$namespace" --since="$since_time" > "$log_dir/${pod}_${container}.log"
            color_text "green" "Логи сохранены в $log_dir/${pod}_${container}.log"
        done
    done
}

# Функция для скачивания конфигураций
download_configs() {
    cluster_url="$1"
    namespace="$2"
    color_text "yellow" "Скачивание конфигураций..."
    backup_dir="$(echo "$cluster_url" | awk -F[/:] '{print $4}')/$namespace/backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    for resource in dc gw svc route deploy se vs dr cm EnvoyFilter secret; do
        oc get "$resource" -n "$namespace" -o yaml > "$backup_dir/${resource}.yaml"
    done
    color_text "green" "Конфигурации сохранены в $backup_dir"
}

# Функция для восстановления конфигураций
restore_configs() {
    cluster_url="$1"
    namespace="$2"
    color_text "yellow" "Восстановление конфигураций..."
    read -p "Введите путь к директории с бэкапом: " backup_dir
    for file in "$backup_dir"/*.yaml; do
        oc apply -f "$file" -n "$namespace"
    done
    color_text "green" "Конфигурации восстановлены из $backup_dir"
}

# Функция для очистки namespace
clear_namespace() {
    namespace="$1"
    color_text "yellow" "Очистка namespace $namespace..."
    for resource in dc gw svc route deploy se vs dr cm EnvoyFilter secret; do
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
