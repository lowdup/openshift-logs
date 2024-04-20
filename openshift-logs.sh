#!/bin/bash

CONFIG_FILE="clusters.conf"
ERROR_LOG="error_log.txt"
DEBUG=${DEBUG:-0}

echo_color() {
    echo -e "\e[1;34m$1\e[0m"
}

log_error() {
    echo "$1" >> $ERROR_LOG
}

oc_command() {
    local command=$1
    if [ "$DEBUG" -eq 1 ]; then
        eval "$command"
    else
        eval "$command" 2>&1 | tee -a $ERROR_LOG >/dev/null
    fi
}

select_cluster() {
    echo_color "Выберите кластер:"
    local i=1
    local clusters=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^# ]]; then
            continue
        fi
        clusters+=("$line")
        echo "$i) $(echo $line | cut -d' ' -f1)"
        ((i++))
    done < "$CONFIG_FILE"
    read -rp "Введите номер кластера: " cluster_number
    if [ -z "${clusters[$((cluster_number-1))]}" ]; then
        echo_color "Неверный выбор кластера. Попробуйте снова."
        select_cluster
    else
        SERVER_URL=$(echo "${clusters[$((cluster_number-1))]}" | cut -d' ' -f1)
        TOKEN=$(echo "${clusters[$((cluster_number-1))]}" | cut -d' ' -f2)
        if ! oc_command "oc login --token='$TOKEN' --server='$SERVER_URL' --insecure-skip-tls-verify=true"; then
            echo_color "Авторизация не удалась. Попробуйте снова."
            exit 1
        fi
    fi
}

select_namespace() {
    echo_color "Доступные проекты:"
    local projects=$(oc_command "oc projects -q")
    local project_list=($projects)
    if [ ${#project_list[@]} -eq 0 ]; then
        echo_color "Проекты не найдены."
        exit 1
    fi
    local i=1
    for project in "${project_list[@]}"; do
        echo "$i) $project"
        ((i++))
    done
    read -rp "Введите номер проекта: " project_number
    NAMESPACES=${project_list[$((project_number-1))]}
    if [ -z "$NAMESPACES" ]; then
        echo_color "Неверный выбор проекта. Попробуйте снова."
        select_namespace
    fi
}

request_log_time() {
    echo "Введите временной интервал (например, '1h' или '30m') или оставьте пустым для всех логов:"
    read -rp "Временной интервал: " time_interval
    if [[ "$time_interval" =~ ^[0-9]+[hm]$ ]]; then
        SINCE_TIME="--since=$time_interval"
    else
        SINCE_TIME=""
    fi
}

fetch_logs() {
    for ns in $NAMESPACES; do
        echo_color "Работаем в namespace: $ns"
        local pods=$(oc_command "oc get pods -n $ns --no-headers | awk '{print $1}'")
        echo "$pods" | nl -w1 -s') '
        echo "Введите номера подов (разделенных запятыми) или 0 для всех:"
        read -rp "Ваш выбор: " pod_choices
        local selected_pods=()
        if [[ "$pod_choices" == "0" ]]; then
            selected_pods=($pods)
        else
            IFS=',' read -ra chosen_indices <<< "$pod_choices"
            for index in "${chosen_indices[@]}"; do
                selected_pods+=("${pods[index-1]}")
            done
        fi

        request_log_time

        for pod in "${selected_pods[@]}"; do
            local containers=$(oc_command "oc get pod $pod -n $ns -o jsonpath='{.spec.containers[*].name}'")
            for container in $containers; do
                local timestamp=$(date "+%Y%m%d-%H%M%S")
                local log_path="./logs/$ns/$pod/$container-$timestamp.log"
                mkdir -p "$(dirname "$log_path")"
                if oc_command "oc logs $pod -c $container -n $ns $SINCE_TIME > $log_path"; then
                    echo_color "Логи сохранены: $log_path"
                else
                    log_error "Ошибка при загрузке логов для $container в $pod."
                fi
            done
        done
    done
}

echo_color "Начало работы скрипта OpenShift Tools"
select_cluster
select_namespace
fetch_logs
echo_color "Завершение работы скрипта OpenShift Tools"
