#!/bin/bash

# Путь к файлу конфигурации кластеров
CONFIG_FILE="clusters.conf"
# Путь к файлу лога ошибок
ERROR_LOG="error_log.txt"

# Переменная для включения режима отладки
DEBUG=${DEBUG:-0}

# Функция для печати с цветом
echo_color() {
    echo -e "\e[1;34m$1\e[0m"
}

# Функция для выполнения команд с учетом режима отладки
execute_command() {
    if [ "$DEBUG" -eq 1 ]; then
        eval "$@"
    else
        eval "$@" > /dev/null 2>>$ERROR_LOG
    fi
}

# Функция для входа в кластер
login_to_cluster() {
    SERVER_URL=$1
    TOKEN=$2
    if ! execute_command "oc login --token='$TOKEN' --server='$SERVER_URL' --insecure-skip-tls-verify=true"; then
        echo_color "Авторизация по токену не удалась. Попробуем логин и пароль."
        read -rp "Введите ваш логин: " username
        read -rsp "Введите ваш пароль: " password
        echo
        if ! execute_command "oc login -u '$username' -p '$password' --server='$SERVER_URL' --insecure-skip-tls-verify=true"; then
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
        if [[ "$line" =~ ^# ]]; then
            continue
        fi
        echo "$i) $(echo $line | cut -d' ' -f1)"
        i=$((i+1))
    done < "$CONFIG_FILE"
    read -rp "Введите номер кластера: " cluster_number
    local selected_line=$(awk 'NF && $1 !~ /^#/ {print NR" "$0}' "$CONFIG_FILE" | awk -v num="$cluster_number" '$1 == num {print $2,$3}')
    if [ -z "$selected_line" ]; then
        echo_color "Неверный выбор кластера. Попробуйте снова."
        select_cluster
    else
        SERVER_URL=$(echo $selected_line | cut -d' ' -f1)
        TOKEN=$(echo $selected_line | cut -d' ' -f2)
        login_to_cluster "$SERVER_URL" "$TOKEN"
    fi
}

# Функция для выбора namespace, используя доступные проекты
select_namespace() {
    echo_color "Доступные проекты:"
    # Получаем список доступных проектов и обрабатываем его
    oc projects 2>>$ERROR_LOG | sed '1,2d' | sed '$d' | sed '$d' | sed 's/^  \* //' > available_projects.txt
    if [ ! -s available_projects.txt ]; then
        echo_color "Ошибка: Не удалось получить список проектов или список проектов пуст. Проверьте $ERROR_LOG для подробностей."
        exit 1
    fi
    cat available_projects.txt | nl -w1 -s') '

    echo "Введите номер проекта или 0 для выбора всех доступных проектов:"
    read -rp "Ваш выбор: " project_choice

    if [[ "$project_choice" == "0" ]]; then
        NAMESPACES=$(cat available_projects.txt)
    else
        NAMESPACES=$(awk "NR==$project_choice {print \$1}" available_projects.txt)
        if [ -z "$NAMESPACES" ]; then
            echo_color "Неверный выбор проекта. Попробуйте снова."
            select_namespace
        fi
    fi
    rm available_projects.txt
}


# Функция для запроса временного интервала логов
request_log_time() {
    echo "Введите время в формате '1h' для 1 часа или '30m' для 30 минут, или оставьте пустым для всех логов:"
    read -rp "Временной интервал: " time_interval
    if [[ $time_interval =~ ^[0-9]+[hm]$ ]]; then
        SINCE_TIME="--since=$time_interval"request_log_time
    else
        SINCE_TIME=""
    fi
}

# Функция для выбора и загрузки логов
fetch_logs() {
    for ns in $NAMESPACES; do
        echo_color "Работаем в namespace: $ns"
        echo "Загружаем список подов в namespace $ns..."
        
        # Получаем список подов и контейнеров сразу
        if ! pods=$(execute_command "oc get pods -n $ns --no-headers" | awk '{print NR") "$1}'); then
            echo_color "Ошибка при получении списка подов. Смотрите $ERROR_LOG для подробностей."
            continue
        fi

        if [ -z "$pods" ]; then
            echo_color "Нет доступных подов в namespace $ns."
            continue
        fi

        echo "$pods"
        echo "Введите номера подов, для которых загрузить логи, разделяя запятыми, или 0 для всех:"
        read -rp "Ваш выбор: " pod_choices

        if [[ "$pod_choices" == "0" ]]; then
            selected_pods=$(echo "$pods" | awk '{print $2}')
        else
            IFS=',' read -ra chosen_pods <<< "$pod_choices"
            selected_pods=$(for i in "${chosen_pods[@]}"; do echo "$pods" | awk -v num="$i" 'NR==num {print $2}'; done)
        fi

        for pod in $selected_pods; do
            echo "Загружаем список контейнеров в поде $pod..."
            containers=$(execute_command "oc get pod $pod -n $ns -o jsonpath='{.spec.containers[*].name}'")

            if [ -z "$containers" ]; then
                echo_color "Нет доступных контейнеров в поде $pod."
                continue
            fi

            echo "Контейнеры в поде $pod: $containers"
            echo "Загрузка логов для всех контейнеров в поде $pod..."

            for container in $containers; do
                local timestamp=$(date "+%Y%m%d-%H%M%S")
                local log_path="./logs/$ns/$pod/$container-$timestamp.log"
                mkdir -p "$(dirname "$log_path")"
                if ! execute_command "oc logs $pod -c $container -n $ns --timestamps" > "$log_path"; then
                    echo_color "Ошибка при загрузке логов для $container. Смотрите $ERROR_LOG для подробностей."
                else
                    echo_color "Логи сохранены: $log_path"
                fi
            done
        done
    done
}

# Основной код скрипта
echo_color "Начало работы скрипта OpenShift Tools"
select_cluster
select_namespace
fetch_logs
echo_color "Завершение работы скрипта OpenShift Tools"
