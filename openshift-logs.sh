#!/bin/bash

# Цвета для вывода текста
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
log() {
  echo -e "${BLUE}[$(date +"%Y-%m-%d %H:%M:%S")]${NC} $1"
}

# Проверка наличия необходимого файла
CONFIG_FILE="clusters.txt"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo -e "${RED}Файл с кластерами $CONFIG_FILE не найден!${NC}"
  exit 1
fi

# Функция для получения списка namespace со всех кластеров
get_all_namespaces() {
  log "Получение списка namespace со всех кластеров"
  while IFS=: read -r cluster token; do
    if [[ -n "$token" ]]; then
      oc login --token="$token" --server="$cluster" &> /dev/null
    else
      echo -e "${YELLOW}Для кластера $cluster отсутствует токен.${NC}"
    fi
    oc get namespaces --no-headers -o custom-columns=NAME:.metadata.name
  done < "$CONFIG_FILE"
}

# Функция для выбора кластера
choose_cluster() {
  log "Выбор кластера"
  clusters=()
  while IFS= read -r line; do
    clusters+=("$line")
  done < "$CONFIG_FILE"
  
  for i in "${!clusters[@]}"; do
    echo "$((i+1)). ${clusters[$i]}"
  done

  read -rp "Введите номер кластера или 'a' для получения списка всех namespace: " choice
  if [[ "$choice" == "a" ]]; then
    get_all_namespaces
    exit 0
  fi

  if [[ "$choice" -le "${#clusters[@]}" && "$choice" -gt 0 ]]; then
    selected_cluster=${clusters[$((choice-1))]}
  else
    echo -e "${RED}Некорректный выбор!${NC}"
    exit 1
  fi

  token=$(echo "$selected_cluster" | cut -d: -f2-)
  selected_cluster=$(echo "$selected_cluster" | cut -d: -f1)
  
  if [[ -n "$token" ]]; then
    oc login --token="$token" --server="$selected_cluster" &> /dev/null
    if [[ $? -ne 0 ]]; then
      echo -e "${YELLOW}Токен недействителен или истек.${NC}"
      login_with_credentials "$selected_cluster"
    fi
  else
    login_with_credentials "$selected_cluster"
  fi
}

# Функция для логина с учетными данными
login_with_credentials() {
  local cluster=$1
  read -rp "Введите логин: " login
  read -rsp "Введите пароль: " password
  echo
  oc login --server="$cluster" -u "$login" -p "$password" &> /dev/null
  if [[ $? -eq 0 ]]; then
    token=$(oc whoami -t)
    sed -i "s|^$cluster:.*|$cluster:$token|g" "$CONFIG_FILE"
    echo -e "${GREEN}Авторизация успешна! Токен обновлен.${NC}"
  else
    echo -e "${RED}Ошибка авторизации!${NC}"
    exit 1
  fi
}

# Функция для выбора namespace
choose_namespace() {
  log "Выбор namespace"
  mapfile -t namespaces < <(oc get namespaces --no-headers -o custom-columns=NAME:.metadata.name)
  for i in "${!namespaces[@]}"; do
    echo "$((i+1)). ${namespaces[$i]}"
  done

  read -rp "Введите номер namespace: " ns_choice
  if [[ "$ns_choice" -le "${#namespaces[@]}" && "$ns_choice" -gt 0 ]]; then
    selected_namespace=${namespaces[$((ns_choice-1))]}
  else
    echo -e "${RED}Некорректный выбор!${NC}"
    exit 1
  fi
}

# Функция для вывода меню действий
actions_menu() {
  log "Меню действий"
  echo "1. Выгрузить логи"
  echo "2. Скачать файлы конфигурации"
  echo "3. Восстановить конфигурации из backup"
  echo "4. Очистить namespace"
  echo "5. Вернуться к выбору кластера"
  read -rp "Выберите действие: " action_choice

  case "$action_choice" in
    1) export_logs ;;
    2) download_configs ;;
    3) restore_configs ;;
    4) clean_namespace ;;
    5) choose_cluster ;;
    *) echo -e "${RED}Некорректный выбор!${NC}"; actions_menu ;;
  esac
}

# Функция для выгрузки логов
export_logs() {
  log "Выгрузка логов"
  mapfile -t pods < <(oc get pods -n "$selected_namespace" --no-headers -o custom-columns=NAME:.metadata.name)
  for i in "${!pods[@]}"; do
    echo "$((i+1)). ${pods[$i]}"
  done

  read -rp "Введите номер пода: " pod_choice
  if [[ "$pod_choice" -le "${#pods[@]}" && "$pod_choice" -gt 0 ]]; then
    selected_pod=${pods[$((pod_choice-1))]}
  else
    echo -e "${RED}Некорректный выбор!${NC}"
    actions_menu
  fi

  mapfile -t containers < <(oc get pod "$selected_pod" -n "$selected_namespace" -o jsonpath='{.spec.containers[*].name}')
  for i in "${!containers[@]}"; do
    echo "$((i+1)). ${containers[$i]}"
  done

  read -rp "Введите номер контейнера: " container_choice
  if [[ "$container_choice" -le "${#containers[@]}" && "$container_choice" -gt 0 ]]; then
    selected_container=${containers[$((container_choice-1))]}
  else
    echo -е "${RED}Некорректный выбор!${NC}"
    actions_menu
  fi

  read -rp "Введите время для логов (например, 10m, 30m, 1h, 2d или all): " log_time
  if [[ "$log_time" == "all" ]]; then
    time_opt=""
  else
    time_opt="--since=$log_time"
  fi

  log_dir="$selected_cluster/$selected_namespace/log/$(date +"%Y%m%d_%H%M%S")"
  mkdir -p "$log_dir"
  oc logs "$selected_pod" -n "$selected_namespace" -c "$selected_container" $time_opt > "$log_dir/$selected_pod_$selected_container.log"
  echo -е "${GREEN}Логи сохранены в $log_dir/${NC}"
  actions_menu
}

# Функция для скачивания конфигураций
download_configs() {
  log "Скачивание конфигураций"
  config_dir="$selected_cluster/$selected_namespace/backup/$(date +"%Y%m%d_%H%M%S")"
  mkdir -p "$config_dir"
  oc get all -n "$selected_namespace" -o yaml > "$config_dir/config.yaml"
  echo -е "${GREEN}Конфигурации сохранены в $config_dir/${NC}"
  actions_menu
}

# Функция для восстановления конфигураций
restore_configs() {
  log "Восстановление конфигураций"
  read -rp "Введите путь к файлу конфигураций: " config_file
  if [[ -f "$config_file" ]]; then
    oc apply -f "$config_file" -n "$selected_namespace"
    echo -е "${GREEN}Конфигурации восстановлены из $config_file${NC}"
  else
    echo -е "${RED}Файл $config_file не найден!${NC}"
  fi
  actions_menu
}

# Функция для очистки namespace
clean_namespace() {
  log "Очистка namespace"
  oc delete all --all -n "$selected_namespace"
  echo -е "${GREEN}Namespace очищен.${NC}"
  actions_menu
}

# Запуск скрипта
choose_cluster
choose_namespace
actions_menu
