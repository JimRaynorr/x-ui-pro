#!/bin/bash

# Путь к базе данных
DB_PATH="/etc/x-ui/x-ui.db"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root!"
  exit 1
fi

# Проверка зависимостей
for cmd in sqlite3 jq; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed. Please run: apt update && apt install -y $cmd"
    exit 1
  fi
done

# --- 1. Сбор данных у пользователя ---
echo "============================================="
echo " X-UI Multi-Inbound User Generator"
echo "============================================="
read -p "Enter Client Name (e.g. 'alex'): " CLIENT_NAME

if [[ -z "$CLIENT_NAME" ]]; then
  echo "Error: Client name cannot be empty."
  exit 1
fi

read -p "Enter Subscription ID (subId) [Press Enter to use '$CLIENT_NAME']: " SUB_ID
if [[ -z "$SUB_ID" ]]; then
  SUB_ID="$CLIENT_NAME"
fi

# --- НОВОЕ: Запрос лимита IP ---
read -p "Enter IP Limit (0 for unlimited) [Default: 2]: " IP_LIMIT_INPUT

if [[ -z "$IP_LIMIT_INPUT" ]]; then
  IP_LIMIT=2
else
  # Проверяем, что введено число
  if ! [[ "$IP_LIMIT_INPUT" =~ ^[0-9]+$ ]]; then
    echo "Error: IP Limit must be a number."
    exit 1
  fi
  IP_LIMIT=$IP_LIMIT_INPUT
fi

echo "---------------------------------------------"
echo "Client Name Prefix: $CLIENT_NAME"
echo "Subscription ID: $SUB_ID"
echo "IP Limit: $IP_LIMIT"
echo "Target Inbounds: IDs 1 to 8"
echo "---------------------------------------------"
read -p "Is this correct? (y/n): " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# Функция генерации UUID
gen_uuid() {
  if [ -f "/usr/local/x-ui/bin/xray-linux-amd64" ]; then
    /usr/local/x-ui/bin/xray-linux-amd64 uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

# Текущее время (timestamp в мс)
NOW=$(date +%s%3N)

# --- 2. Цикл добавления в 8 инбаундов ---
echo ""
echo "Starting user generation..."

# ИЗМЕНЕНО: Диапазон увеличен до 8
for INBOUND_ID in {1..8}; do
  UUID=$(gen_uuid)
  
  # Формируем email: name_1, name_2 ... name_8
  EMAIL="${CLIENT_NAME}_${INBOUND_ID}"

  # Определяем flow
  FLOW=""
  # ИЗМЕНЕНО: Логика осталась прежней, ID 8 подпадает под условие >= 4
  if [[ "$INBOUND_ID" == "1" || "$INBOUND_ID" -ge 4 ]]; then
    FLOW="xtls-rprx-vision"
  fi

  echo "Processing Inbound $INBOUND_ID..."

  CURRENT_SETTINGS=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id=$INBOUND_ID;")

  if [[ -z "$CURRENT_SETTINGS" ]]; then
    echo " [SKIP] Inbound ID $INBOUND_ID not found in database."
    continue
  fi

  NEW_CLIENT_JSON=$(jq -n \
    --arg id "$UUID" \
    --arg flow "$FLOW" \
    --arg email "$EMAIL" \
    --arg subId "$SUB_ID" \
    --argjson limitIp "$IP_LIMIT" \
    --argjson now "$NOW" \
    '{
      id: $id,
      flow: $flow,
      email: $email,
      limitIp: $limitIp,
      totalGB: 0,
      expiryTime: 0,
      enable: true,
      tgId: "",
      subId: $subId,
      reset: 0,
      created_at: $now,
      updated_at: $now
    }')

  UPDATED_SETTINGS=$(echo "$CURRENT_SETTINGS" | jq --argjson new "$NEW_CLIENT_JSON" '.clients += [$new]')

  if [[ $? -ne 0 ]]; then
    echo " [ERROR] Failed to parse JSON for Inbound $INBOUND_ID."
    continue
  fi

  SAFE_SETTINGS=$(echo "$UPDATED_SETTINGS" | sed "s/'/''/g")
  
  sqlite3 "$DB_PATH" "UPDATE inbounds SET settings='$SAFE_SETTINGS' WHERE id=$INBOUND_ID;"
  
  # Добавляем статистику
  sqlite3 "$DB_PATH" "INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES ($INBOUND_ID, 1, '$EMAIL', 0, 0, 0, 0, 0);"

  echo " [OK] Added user $EMAIL (Limit: $IP_LIMIT)"

done

# --- 3. Перезапуск панели ---
echo ""
echo "All done. Restarting x-ui panel..."

if systemctl is-active --quiet x-ui; then
  systemctl restart x-ui
  echo "x-ui restarted successfully."
else
  x-ui restart
  echo "x-ui restarted."
fi

echo "============================================="
echo "User '$CLIENT_NAME' added with IP Limit: $IP_LIMIT"
