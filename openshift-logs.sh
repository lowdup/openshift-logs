#!/bin/bash

# Путь к файлу конфигурации кластеров
CONFIG_FILE="clusters.conf"

# Функция для печати с цветом
echo_color() {
    echo -e "\e[1;34m$1\e[0m"
}

# Функция для входа в кластер
login_to_cluster() {
    SERVER_URL=$1
    TOKEN=$2
    if ! oc login --token="$TOKEN" --server="$SERVER_URL" --insecure-skip-tls-verify=true; then
        echo_color "Авторизация по токену не удалась. Попробуем логин и пароль."
        read -rp "Введите ваш логин: " username
        read -rsp "Введите ваш пароль: " password
        echo
        if ! oc login -u "$username" -p "$password" --server="$SERVER_URL" --insecure-skip-tls-verify=true; then
            echo_color "Авторизация не удалась. Проверьте логин и пароль и попробуйте снова."
            exit 1
        fi
    fi
}

# Функция для выбора кластера
select_cluster() {
    echo_color "Выберите кластер:"
    local i=1
    while read -r line; do
        echo "$i) $(echo $line | cut -d' ' -f1)"
        i=$((i+1))
    done < "$CONFIG_FILE"
    read -rp "Введите номер кластера: " cluster_number
    if ! [[ "$cluster_number" =~ ^[0-9]+$ ]] || [ "$(sed -n "$cluster_number p" "$CONFIG_FILE")" == "" ]; then
        echo_color "Неверный выбор кластера. Попробуйте снова."
        select_cluster
    else
        SERVER_URL=$(sed -n "${cluster_number}p" "$CONFIG_FILE" | cut -d' ' -f1)
        TOKEN=$(sed -n "${cluster_number}p" "$CONFIG_FILE" | cut -d' ' -f2)
        login_to_cluster "$SERVER_URL" "$TOKEN"
    fi
}

# Функция для выбора namespace
select_namespace() {
    echo_color "Доступные namespaces:"
    oc get namespaces --no-headers | awk '{print NR") "$1}'
    echo "Введите номер namespace или 0 для выбора всех:"
    read -rp "Ваш выбор: " ns_choice
    if ! [[ "$ns_choice" =~ ^[0-9]+$ ]] || [ "$ns_choice" -gt "$(oc get namespaces --no-headers | wc -l)" ]; then
        echo_color "Неверный выбор namespace. Попробуйте снова."
        select_namespace
    elif [[ "$ns_choice" == "0" ]]; then
        NAMESPACES=$(oc get namespaces -o=jsonpath='{.items[*].metadata.name}')
    else
        NAMESPACES=$(oc get namespaces --no-headers | awk "NR==$ns_choice {print \$1}")
    fi
}

# Функция для запроса временного интервала логов
request_log_time() {
    echo "Введите время в формате '1h' для 1 часа или '30m' для 30 минут, или оставьте пустым для всех логов:"
    read -rp "Временной интервал: " time_interval
    if [[ $time_interval =~ ^[0-9]+[hm]$ ]]; then
        SINCE_TIME="--since=$time_interval"
    else
        SINCE_TIME=""
    fi
}

# Функция для выбора и загрузки логов
fetch_logs() {
    request_log_time
    for ns in $NAMESPACES; do
        echo_color "Выбор подов в namespace $ns:"
        oc get pods -n "$ns" --no-headers | awk '{print NR") "$1}'
        echo "Введите номера подов, для которых загрузить логи, разделяя запятыми или 0 для всех:"
        read -rp "Ваш выбор: " pod_choices
        if [[ "$pod_choices" == "0" ]]; then
            pods=$(oc get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}')
        else
            pods=$(echo "$pod_choices" | tr ',' '\n' | while read number; do oc get pods -n "$ns" --no-headers | sed -n "${number}p" | awk '{print $1}'; done)
        fi

        for pod in $pods; do
            containers=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}')
            for container in $containers; do
                local timestamp=$(date "+%Y%m%d-%H%M%S")
                local log_path="./$ns/$pod/$container-$timestamp.log"
                mkdir -p "./$ns/$pod"
                oc logs "$pod" -c "$container" -n "$ns" $SINCE_TIME --timestamps > "$log_path"
                echo_color "Логи сохранены: $log_path"
            done
        done
    done
}

# Основной код скрипта
echo_color "Начало работы скрипта OpenShift Logs"
select_cluster
select_namespace
fetch_logs
echo_color "Завершение работы скрипта OpenShift Logs"
