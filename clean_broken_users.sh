#!/bin/bash
DB_PATH="/etc/x-ui/x-ui.db"

if [[ $EUID -ne 0 ]]; then
   echo "Run as root!" 
   exit 1
fi

read -p "Enter the BROKEN email to remove (e.g. 'alex'): " EMAIL_TO_REMOVE
if [[ -z "$EMAIL_TO_REMOVE" ]]; then
    echo "Empty email. Exit."
    exit 1
fi

echo "Removing client '$EMAIL_TO_REMOVE' from all inbounds..."

# Удаляем из таблицы статистики (это просто SQL)
sqlite3 "$DB_PATH" "DELETE FROM client_traffics WHERE email='$EMAIL_TO_REMOVE';"
echo "Removed from client_traffics."

# Удаляем из настроек инбаундов (нужно править JSON)
for INBOUND_ID in {1..7}; do
    CURRENT_SETTINGS=$(sqlite3 "$DB_PATH" "SELECT settings FROM inbounds WHERE id=$INBOUND_ID;")
    
    if [[ -z "$CURRENT_SETTINGS" ]]; then
        continue
    fi

    # Используем jq, чтобы найти массив clients и удалить оттуда объект, у которого email == EMAIL_TO_REMOVE
    # del(.clients[] | select(.email == "alex"))
    NEW_SETTINGS=$(echo "$CURRENT_SETTINGS" | jq "del(.clients[] | select(.email == \"$EMAIL_TO_REMOVE\"))")

    # Экранируем для SQL
    SAFE_SETTINGS=$(echo "$NEW_SETTINGS" | sed "s/'/''/g")
    
    sqlite3 "$DB_PATH" "UPDATE inbounds SET settings='$SAFE_SETTINGS' WHERE id=$INBOUND_ID;"
    echo "Cleaned Inbound $INBOUND_ID"
done

echo "Restarting x-ui..."
x-ui restart
echo "Done. Check the panel."
