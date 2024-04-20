#!/bin/bash

CONFIG_FILE="clusters.conf"
ERROR_LOG="error_log.txt"
DEBUG=0

printf_color() {
    printf "\e[1;34m%s\e[0m\n" "$1"
}

log_error() {
    printf "%s\n" "$1" >> "$ERROR_LOG"
}

oc_command() {
    local command="$1"
    eval "$command" 2>&1 | tee -a "$ERROR_LOG"
}

select_cluster() {
    printf_color "Выберите кластер:"
    local i=1
    local clusters=()
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        clusters+=("$line")
        printf "%d) %s\n" "$i" "$(echo "$line" | cut -d' ' -f1)"
        ((i++))
    done < "$CONFIG_FILE"
    
    local cluster_number index
    read -rp "Введите номер кластера: " cluster_number
    index=$((cluster_number - 1))

    if [[ -z "${clusters[index]}" ]]; then
        printf_color "Неверный выбор кластера. Попробуйте снова."
        select_cluster
    else
        local cluster_info=(${clusters[index]})
        local server_url="${cluster_info[0]}"
        local token="${cluster_info[1]}"

        if [[ -z "$token" ]] || ! oc_command "oc login --token='$token' --server='$server_url' --insecure-skip-tls-verify=true"; then
            printf_color "Авторизация по токену не удалась или токен отсутствует. Попробуйте логин и пароль."
            local username password
            read -rp "Введите ваш логин: " username
            read -rsp "Введите ваш пароль: " password
            echo
            if oc_command "oc login -u '$username' -p '$password' --server='$server_url' --insecure-skip-tls-verify=true"; then
                local new_token=$(oc_command "oc whoami -t")
                if [[ -n "$new_token" ]]; then
                    printf_color "Токен успешно получен и обновлен."
                    clusters[index]="$server_url $new_token"
                    printf "%s\n" "${clusters[@]}" > "$CONFIG_FILE"
                    printf_color "Токен успешно обновлен в конфигурационном файле."
                else
                    printf_color "Не удалось получить новый токен."
                    return 1
                fi
            else
                printf_color "Авторизация не удалась. Проверьте логин и пароль и попробуйте снова."
                return 1
            fi
        fi
    fi
}

select_namespace() {
    printf_color "Доступные проекты:"
    local projects=$(oc_command "oc projects -q")
    local project_list=($projects)
    [[ ${#project_list[@]} -eq 0 ]] && { printf_color "Проекты не найдены."; return 1; }

    local i=1
    for project in "${project_list[@]}"; do
        printf "%d) %s\n" "$i" "$project"
        ((i++))
    done
    local project_number
    read -rp "Введите номер проекта: " project_number
    NAMESPACES=${project_list[$((project_number-1))]}

    [[ -z "$NAMESPACES" ]] && { printf_color "Неверный выбор проекта. Попробуйте снова."; select_namespace; }
}

request_log_time() {
    printf "Введите временной интервал (например, '1h' или '30m') или оставьте пустым для всех логов:\n"
    read -rp "Временной интервал: " time_interval
    [[ "$time_interval" =~ ^[0-9]+[hm]$ ]] && SINCE_TIME="--since=$time_interval" || SINCE_TIME=""
}

fetch_logs() {
    for ns in $NAMESPACES; do
        printf_color "Работаем в namespace: $ns"
        local pods
        mapfile -t pods < <(oc get pods -n "$ns" --no-headers | awk '{print $1}')
        
        [[ ${#pods[@]} -eq 0 ]] && { printf_color "В namespace $ns не найдено подов."; continue; }
        printf "Доступные поды:\n"
        printf '%s\n' "${pods[@]}" | nl -w1 -s') '
        
        printf "Введите номера подов (разделенных запятыми) или 0 для всех:\n"
        local pod_choices selected_pods chosen_indices
        read -rp "Ваш выбор: " pod_choices
        if [[ "$pod_choices" == "0" ]]; then
            selected_pods=("${pods[@]}")
        else
            IFS=',' read -ra chosen_indices <<< "$pod_choices"
            for index in "${chosen_indices[@]}"; do
                ((index--))  # Adjust index to be zero-based
                if [[ index -ge 0 && index -lt ${#pods[@]} ]]; then
                    selected_pods+=("${pods[index]}")
                else
                    printf_color "\e[1;31mНекорректный индекс: $((index + 1)). Под не найден.\e[0m"
                fi
            done
        fi

        request_log_time

        for pod in "${selected_pods[@]}"; do
            printf_color "\e[1;33mЗагружаем список контейнеров в поде $pod...\e[0m"
            local containers
            containers=$(oc get pod "$pod" -n "$ns" -o jsonpath='{.spec.containers[*].name}')
            [[ -z "$containers" ]] && { printf_color "\e[1;31mВ поде $pod не найдено контейнеров.\e[0m"; continue; }
            printf_color "\e[1;32mНайдены контейнеры в поде $pod: $containers\e[0m"
            
            for container in $containers; do
                local timestamp log_path
                timestamp=$(date "+%Y%m%d-%H%M%S")
                log_path="./logs/$ns/$pod/$container-$timestamp.log"
                mkdir -p "$(dirname "$log_path")"
                printf_color "\e[1;34mЗагрузка логов для $container...\e[0m"
                if oc logs "$pod" -c "$container" -n "$ns" $SINCE_TIME > "$log_path"; then
                    printf_color "\e[1;32mЛоги сохранены: $log_path\e[0m"
                else
                    printf_color "\e[1;31mОшибка при загрузке логов для $container в $pod.\e[0m"
                    log_error "Ошибка при загрузке логов для $container в $pod."
                fi
            done
        done
    done
}

main() {
    printf_color "Начало работы скрипта OpenShift Tools"
    if ! select_cluster || ! select_namespace; then
        printf_color "Ошибка инициализации скрипта. Останавливаем выполнение."
        return 1
    fi
    fetch_logs
    printf_color "Завершение работы скрипта OpenShift Tools"
}

main
