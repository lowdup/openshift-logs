#!/bin/bash

CONFIG_FILE="clusters.conf"
ERROR_LOG="error_log.txt"
DEBUG=1

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
        echo "$i) $(echo "$line" | cut -d' ' -f1)"
        ((i++))
    done < "$CONFIG_FILE"
    
    read -rp "Введите номер кластера: " cluster_number
    local index=$((cluster_number - 1))

    if [[ -z "${clusters[index]}" ]]; then
        echo_color "Неверный выбор кластера. Попробуйте снова."
        select_cluster
    else
        local cluster_info=(${clusters[index]})
        local SERVER_URL="${cluster_info[0]}"
        local TOKEN="${cluster_info[1]}"

        if [[ -z "$TOKEN" ]] || ! oc_command "oc login --token='$TOKEN' --server='$SERVER_URL' --insecure-skip-tls-verify=true"; then
            echo_color "Авторизация по токену не удалась или токен отсутствует. Попробуйте логин и пароль."
            read -rp "Введите ваш логин: " username
            read -rsp "Введите ваш пароль: " password
            echo
            if oc_command "oc login -u '$username' -p '$password' --server='$SERVER_URL' --insecure-skip-tls-verify=true"; then
                new_token=$(oc_command "oc whoami -t")
                if [[ -n "$new_token" ]]; then
                    echo_color "Токен успешно получен и обновлен."
                    clusters[index]="$SERVER_URL $new_token"
                    printf "%s\n" "${clusters[@]}" > "$CONFIG_FILE"
                    echo_color "Токен успешно обновлен в конфигурационном файле."
                else
                    echo_color "Не удалось получить новый токен."
                    exit 1
                fi
            else
                echo_color "Авторизация не удалась. Проверьте логин и пароль и попробуйте снова."
                exit 1
            fi
        fi
    fi
}


select_namespace() {
    echo_color "Доступные проекты:"
    local projects=$(oc_command "oc projects -q" | awk '{print $1}')
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
        echo_color "\e[1;36mРаботаем в namespace: $ns\e[0m"
        local pods
        mapfile -t pods < <(oc get pods -n $ns --no-headers | awk '{print $1}')
        
        if [ ${#pods[@]} -eq 0 ]; then
            echo_color "\e[1;31mВ namespace $ns не найдено подов.\e[0m"
            continue
        fi
        
        echo "Доступные поды:"
        printf '%s\n' "${pods[@]}" | nl -w1 -s') '
        
        echo "Введите номера подов (разделенных запятыми) или 0 для всех:"
        read -rp "Ваш выбор: " pod_choices
        local selected_pods=()
        if [[ "$pod_choices" == "0" ]]; then
            selected_pods=("${pods[@]}")
        else
            IFS=',' read -ra chosen_indices <<< "$pod_choices"
            for index in "${chosen_indices[@]}"; do
                ((index--))  # Adjust index to be zero-based
                if [[ index -ge 0 && index -lt ${#pods[@]} ]]; then
                    selected_pods+=("${pods[index]}")
                else
                    echo_color "\e[1;31mНекорректный индекс: $((index + 1)). Под не найден.\e[0m"
                fi
            done
        fi

        request_log_time

        for pod in "${selected_pods[@]}"; do
            echo_color "\e[1;33mЗагружаем список контейнеров в поде $pod...\e[0m"
            local containers
            containers=$(oc get pod $pod -n $ns -o jsonpath='{.spec.containers[*].name}')
            if [ -z "$containers" ]; then
                echo_color "\e[1;31mВ поде $pod не найдено контейнеров.\e[0m"
                continue
            fi
            echo_color "\e[1;32mНайдены контейнеры в поде $pod: $containers\e[0m"
            
            for container in $containers; do
                local timestamp=$(date "+%Y%m%d-%H%M%S")
                local log_path="./logs/$ns/$pod/$container-$timestamp.log"
                mkdir -p "$(dirname "$log_path")"
                echo_color "\e[1;34mЗагрузка логов для $container...\e[0m"
                if oc logs $pod -c $container -n $ns $SINCE_TIME > "$log_path"; then
                    echo_color "\e[1;32mЛоги сохранены: $log_path\e[0m"
                else
                    echo_color "\e[1;31mОшибка при загрузке логов для $container в $pod.\e[0m"
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
