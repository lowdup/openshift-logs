#!/bin/bash

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Файл с кластерными данными
CLUSTER_FILE="clusters.txt"

# Функция для отображения меню
show_menu() {
    echo -e "${BLUE}Выберите действие:${NC}"
    echo "1) Получить список namespace со всех кластеров"
    echo "2) Выбрать кластер для работы"
    echo "3) Выход"
}

# Функция для загрузки кластеров из файла
load_clusters() {
    clusters=()
    while IFS= read -r line; do
        clusters+=("$line")
    done < "$CLUSTER_FILE"
}

# Функция для выбора кластера
select_cluster() {
    echo -e "${BLUE}Выберите кластер для работы:${NC}"
    for i in "${!clusters[@]}"; do
        echo "$((i+1))) ${clusters[$i]}"
    done
    read -p "Введите номер кластера: " cluster_index
    selected_cluster="${clusters[$((cluster_index-1))]}"
}

# Функция для получения списка namespace со всех кластеров
list_all_namespaces() {
    echo -e "${GREEN}Получаем список namespace со всех кластеров...${NC}"
    for cluster in "${clusters[@]}"; do
        cluster_url=$(echo "$cluster" | awk '{print $1}')
        token=$(echo "$cluster" | awk '{print $2}')
        if [ -n "$token" ]; then
            oc login "$cluster_url" --token="$token" --insecure-skip-tls-verify &>/dev/null
        else
            echo -e "${RED}Нет токена для кластера $cluster_url${NC}"
            continue
        fi
        oc get namespaces --no-headers -o custom-columns=NAME:.metadata.name
    done
}

# Функция для авторизации в кластере
authenticate_cluster() {
    cluster_url=$(echo "$selected_cluster" | awk '{print $1}')
    token=$(echo "$selected_cluster" | awk '{print $2}')
    if [ -n "$token" ]; then
        if ! oc login "$cluster_url" --token="$token" --insecure-skip-tls-verify &>/dev/null; then
            echo -e "${YELLOW}Токен недействителен или истек. Пожалуйста, авторизуйтесь с помощью логина и пароля.${NC}"
            oc login "$cluster_url" --insecure-skip-tls-verify
            new_token=$(oc whoami -t)
            sed -i "s|$selected_cluster|$cluster_url $new_token|" "$CLUSTER_FILE"
        fi
    else
        oc login "$cluster_url" --insecure-skip-tls-verify
        new_token=$(oc whoami -t)
        sed -i "s|$selected_cluster|$cluster_url $new_token|" "$CLUSTER_FILE"
    fi
}

# Функция для получения списка namespace в выбранном кластере
select_namespace() {
    namespaces=($(oc get namespaces --no-headers -o custom-columns=NAME:.metadata.name))
    echo -e "${BLUE}Выберите namespace для работы:${NC}"
    for i in "${!namespaces[@]}"; do
        echo "$((i+1))) ${namespaces[$i]}"
    done
    read -p "Введите номер namespace: " namespace_index
    selected_namespace="${namespaces[$((namespace_index-1))]}"
}

# Функция для получения списка подов и контейнеров и выгрузки логов
export_logs() {
    pods=($(oc get pods -n "$selected_namespace" --no-headers -o custom-columns=NAME:.metadata.name))
    echo -e "${BLUE}Выберите под для выгрузки логов:${NC}"
    for i in "${!pods[@]}"; do
        echo "$((i+1))) ${pods[$i]}"
    done
    read -p "Введите номер пода: " pod_index
    selected_pod="${pods[$((pod_index-1))]}"

    containers=($(oc get pods "$selected_pod" -n "$selected_namespace" -o jsonpath='{.spec.containers[*].name}'))
    echo -e "${BLUE}Выберите контейнер для выгрузки логов:${NC}"
    for i in "${!containers[@]}"; do
        echo "$((i+1))) ${containers[$i]}"
    done
    read -p "Введите номер контейнера: " container_index
    selected_container="${containers[$((container_index-1))]}"

    echo -e "${BLUE}За какое время нужны логи?${NC}"
    echo "1) За последние 10 минут"
    echo "2) За последние 30 минут"
    echo "3) За последние 60 минут"
    echo "4) Все логи"
    read -p "Введите номер: " time_choice

    case $time_choice in
        1) since_time="10m" ;;
        2) since_time="30m" ;;
        3) since_time="60m" ;;
        4) since_time="" ;;
        *) echo -e "${RED}Неверный выбор${NC}"; return ;;
    esac

    log_dir="${cluster_url//[:\/]/_}/${selected_namespace}/log/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$log_dir"
    if [ -n "$since_time" ]; then
        oc logs "$selected_pod" -c "$selected_container" -n "$selected_namespace" --since="$since_time" > "$log_dir/${selected_pod}_${selected_container}.log"
    else
        oc logs "$selected_pod" -c "$selected_container" -n "$selected_namespace" > "$log_dir/${selected_pod}_${selected_container}.log"
    fi
    echo -e "${GREEN}Логи сохранены в $log_dir/${selected_pod}_${selected_container}.log${NC}"
}

# Функция для скачивания конфигураций
backup_configs() {
    config_dir="${cluster_url//[:\/]/_}/${selected_namespace}/backup/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$config_dir"
    resources=("configmaps" "deployments" "services" "routes" "secrets")
    for resource in "${resources[@]}"; do
        oc get "$resource" -n "$selected_namespace" -o yaml > "$config_dir/$resource.yaml"
    done
    echo -e "${GREEN}Конфигурации сохранены в $config_dir${NC}"
}

# Функция для восстановления конфигураций
restore_configs() {
    echo -e "${BLUE}Введите путь к директории с бэкапом:${NC}"
    read -p "Путь: " backup_dir
    for file in "$backup_dir"/*.yaml; do
        oc apply -f "$file" -n "$selected_namespace"
    done
    echo -e "${GREEN}Конфигурации восстановлены из $backup_dir${NC}"
}

# Функция для очистки namespace
clear_namespace() {
    echo -e "${YELLOW}Очистка namespace $selected_namespace...${NC}"
    resources=("dc" "gw" "svc" "route" "deploy" "se" "vs" "dr" "ef" "cm")
    for resource in "${resources[@]}"; do
        oc delete "$resource" --all -n "$selected_namespace"
    done
    echo -e "${GREEN}Namespace $selected_namespace очищен${NC}"
}

# Основная логика скрипта
main() {
    load_clusters
    while true; do
        show_menu
        read -p "Введите номер действия: " action
        case $action in
            1) list_all_namespaces ;;
            2)
                select_cluster
                authenticate_cluster
                select_namespace
                while true; do
                    echo -e "${BLUE}Выберите действие для namespace ${selected_namespace}:${NC}"
                    echo "1) Выгрузить логи"
                    echo "2) Скачать конфигурации"
                    echo "3) Восстановить конфигурации"
                    echo "4) Очистить namespace"
                    echo "5) Вернуться к выбору кластера"
                    read -p "Введите номер действия: " ns_action
                    case $ns_action in
                        1) export_logs ;;
                        2) backup_configs ;;
                        3) restore_configs ;;
                        4) clear_namespace ;;
                        5) break ;;
                        *) echo -e "${RED}Неверный выбор${NC}" ;;
                    esac
                done
                ;;
            3) exit 0 ;;
            *) echo -e "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

main
