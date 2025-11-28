#!/bin/bash

#################### x-ui-pro v2.4.3 @ github.com/GFW4Fun ##############################################

if [[ $EUID -ne 0 ]]; then
    echo "not root!"
    sudo su -
fi

############################## INFO #####################################################################

msg_ok() { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }

msg_inf ""
msg_inf '  ___       _   _   _            _ '
msg_inf '  \/ __ | | |  __  |_)  |_)  / \ '
msg_inf '  /\ |_| _|_ | |  \ \_/ '
msg_inf ""

################################## Variables ############################################################

XUIDB="/etc/x-ui/x-ui.db"
domain=""
UNINSTALL="x"
INSTALL="n"
PNLNUM=1
CFALLOW="n"
CLASH=0
CUSTOMWEBSUB=0
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

############################## Cleanup #################################################################

cleanup_previous_install() {
    systemctl stop x-ui
    rm -rf /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui
    rm -rf /etc/x-ui
    rm -rf /etc/nginx/sites-enabled/*
    rm -rf /etc/nginx/sites-available/*
    rm -rf /etc/nginx/stream-enabled/*
}

############################## Generate Ports and Paths ###############################################

get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' /dev/null < /dev/urandom | head -c "$length")
    echo "$random_string"
}

check_free() {
    local PORT="$1"
    if lsof -i :"$PORT" >/dev/null; then
        return 1
    else
        return 0
    fi
}

make_port() {
    while true; do
        local PORT=$(get_port)
        if check_free "$PORT"; then
            echo "$PORT"
            break
        fi
    done
}

gen_random_path() {
    echo "$(gen_random_string 10)"
}

############################## User Input ##############################################################

echo -en "Install x-ui-pro? (y/n): " && read INSTALL
if [[ ${INSTALL} == *"n"* ]]; then
    exit 1
fi

echo -en "Uninstall previous version? (y/n): " && read UNINSTALL
if [[ ${UNINSTALL} == *"y"* ]]; then
    cleanup_previous_install
fi

while true; do
    if [[ -n "$domain" ]]; then
        break
    fi
    echo -en "Enter available domain (domain.tld): " && read domain
done

domain=$(echo "$domain" 2>&1 | tr -d '[:space:]' )
SubDomain=$(echo "$domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
MainDomain=$(echo "$domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] ; then
    MainDomain=${domain}
fi

while true; do
    if [[ -n "$reality_domain" ]]; then
        break
    fi
    echo -en "Enter available subdomain for REALITY (sub.domain.tld): " && read reality_domain
done

reality_domain=$(echo "$reality_domain" 2>&1 | tr -d '[:space:]' )
RealitySubDomain=$(echo "$reality_domain" 2>&1 | sed 's/^[^ ]* \|\..*//g')
RealityMainDomain=$(echo "$reality_domain" 2>&1 | sed 's/.*\.\([^.]*\..*\)$/\1/')

if [[ "${RealitySubDomain}.${RealityMainDomain}" != "${reality_domain}" ]] ; then
    RealityMainDomain=${reality_domain}
fi

###############################Install Packages#########################################################

ufw disable

if [[ ${INSTALL} == *"y"* ]]; then
    version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
    if [[ "$version" == "20" || "$version" == "22" ]]; then
        echo "System Version: Ubuntu $version"
    fi
    $Pak -y update
    $Pak -y install curl wget jq bash sudo certbot python3-certbot-nginx sqlite3 ufw
    systemctl daemon-reload && systemctl enable --now nginx
fi

systemctl stop nginx
fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null

##################################GET SERVER IPv4-6#####################################################

IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com);
[[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -s ipv6.icanhazip.com);

##############################Install SSL###############################################################

certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"
if [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
    systemctl start nginx >/dev/null 2>&1
    msg_err "$domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi

certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$reality_domain"
if [[ ! -d "/etc/letsencrypt/live/${reality_domain}/" ]]; then
    systemctl start nginx >/dev/null 2>&1
    msg_err "$reality_domain SSL could not be generated! Check Domain/IP Or Enter new domain!" && exit 1
fi

################################# Access to configs only with cloudflare#################################

rm -f "/etc/nginx/cloudflareips.sh"
cat << 'EOF' >> /etc/nginx/cloudflareips.sh
#!/bin/bash
rm -f "/etc/nginx/conf.d/cloudflare_real_ips.conf" "/etc/nginx/conf.d/cloudflare_whitelist.conf"
CLOUDFLARE_REAL_IPS_PATH=/etc/nginx/conf.d/cloudflare_real_ips.conf
CLOUDFLARE_WHITELIST_PATH=/etc/nginx/conf.d/cloudflare_whitelist.conf
echo "geo \$realip_remote_addr \$cloudflare_ip {
default 0;" >> $CLOUDFLARE_WHITELIST_PATH
for type in v4 v6; do
echo "# IP$type"
for ip in `curl https://www.cloudflare.com/ips-$type`; do
echo "set_real_ip_from $ip;" >> $CLOUDFLARE_REAL_IPS_PATH;
echo " $ip 1;" >> $CLOUDFLARE_WHITELIST_PATH;
done
done
echo "real_ip_header X-Forwarded-For;" >> $CLOUDFLARE_REAL_IPS_PATH
echo "}" >> $CLOUDFLARE_WHITELIST_PATH
EOF

sudo bash "/etc/nginx/cloudflareips.sh" > /dev/null 2>&1;

if [[ ${CFALLOW} == *"y"* ]]; then
    CF_IP="";
else
    CF_IP="#";
fi

############################## Random Params ###########################################################

panel_port=$(make_port)
sub_port=$(make_port)

panel_path=$(gen_random_path)
sub_path=$(gen_random_path)
json_path=$(gen_random_path)
web_path=$(gen_random_path)
sub2singbox_path=$(gen_random_path)
xhttp_path=$(gen_random_path)

config_username=$(gen_random_string 8)
config_password=$(gen_random_string 8)

############################## Install X-UI ############################################################

bash <(curl -Ls https://raw.githubusercontent.com/GFW4Fun/x-ui-pro/master/install.sh)

###################################Get Installed XUI Port/Path##########################################

if [[ -f $XUIDB ]]; then

    # Create stream.conf
    mkdir -p /etc/nginx/stream-enabled
    cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}                       xray;
    ${domain}                               www;
    sun6-21.userapi.com                     xray_1;
    eh.vk.com                               xray_2;
    io.ozone.ru                             xray_3;
    avatars.mds.yandex.net                  xray_4;
    tradingview.com                         xray_5;
    default                                 xray;
}

upstream xray {
    server 127.0.0.1:8443;
}

upstream www {
    server 127.0.0.1:7443;
}

upstream xray_1 {
    server 127.0.0.1:8444;
}

upstream xray_2 {
    server 127.0.0.1:8445;
}

upstream xray_3 {
    server 127.0.0.1:8446;
}

upstream xray_4 {
    server 127.0.0.1:8447;
}

upstream xray_5 {
    server 127.0.0.1:8448;
}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen          443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
}
EOF

    grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
    grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
    sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

    cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain};
    return 301 https://\$host\$request_uri;
}
EOF

    cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl http2 proxy_protocol;
    listen [::]:7443 ssl http2 proxy_protocol;
    index index.html index.htm index.php index.nginx-debian.html;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    if (\$host !~* ^(.+\.)?$domain\$ ){return 444;}
    if (\$scheme ~* https) {set \$safe 1;}
    if (\$ssl_server_name !~* ^(.+\.)?$domain\$ ) {set \$safe "\${safe}0"; }
    if (\$safe = 10){return 444;}

    if (\$request_uri ~ "(\"|'|\`|~|,|:|--|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    #X-UI Admin Panel
    location /${panel_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
        break;
    }

    location /${panel_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
        break;
    }

    #sub2sing-box
    location /${sub2singbox_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:8080/;
    }

    # Path to open clash.yaml and generate YAML
    location ~ ^/${web_path}/clashmeta/(.+)$ {
        default_type text/plain;
        ssi on;
        ssi_types text/plain;
        set \$subid \$1;
        root /var/www/subpage;
        try_files /clash.yaml =404;
    }

    # web
    location ~ ^/${web_path} {
        root /var/www/subpage;
        index index.html;
        try_files \$uri \$uri/ /index.html =404;
    }

    #Subscription Path (simple/encode)
    location /${sub_path} {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }
    location /${sub_path}/ {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }
    
    location /assets/ {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }
    location /assets {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }

    #Subscription Path (json/fragment)
    location /${json_path} {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }
    location /${json_path}/ {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }
    
    #XHTTP
    location /${xhttp_path} {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Connection "";
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Port \$server_port;
        grpc_set_header Host \$host;
        grpc_set_header X-Forwarded-Host \$host;
    }

    #Xray Config Path
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
        $CF_IP if (\$cloudflare_ip != 1) {return 404;}
        if (\$hack = 1) {return 404;}
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$request_method ~* ^(PUT|POST|GET)\$) {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
    }
    
    location / { try_files \$uri \$uri/ =404; }
}
EOF

    cat > "/etc/nginx/sites-available/${reality_domain}" << EOF
server {
    server_tokens off;
    server_name ${reality_domain};
    listen 9443 ssl http2;
    listen [::]:9443 ssl http2;
    index index.html index.htm index.php index.nginx-debian.html;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate /etc/letsencrypt/live/$reality_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$reality_domain/privkey.pem;

    if (\$host !~* ^(.+\.)?${reality_domain}\$ ){return 444;}
    if (\$scheme ~* https) {set \$safe 1;}
    if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$ ) {set \$safe "\${safe}0"; }
    if (\$safe = 10){return 444;}

    if (\$request_uri ~ "(\"|'|\`|~|,|:|--|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)"){set \$hack 1;}
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    #X-UI Admin Panel
    location /${panel_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
        break;
    }

    location /$panel_path {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
        break;
    }

    #sub2sing-box
    location /${sub2singbox_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:8080/;
    }

    # Path to open clash.yaml and generate YAML
    location ~ ^/${web_path}/clashmeta/(.+)$ {
        default_type text/plain;
        ssi on;
        ssi_types text/plain;
        set \$subid \$1;
        root /var/www/subpage;
        try_files /clash.yaml =404;
    }

    # web
    location ~ ^/${web_path} {
        root /var/www/subpage;
        index index.html;
        try_files \$uri \$uri/ /index.html =404;
    }

    #Subscription Path (simple/encode)
    location /${sub_path} {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }
    location /${sub_path}/ {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }

    #Subscription Path (json/fragment)
    location /${json_path} {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }
    location /${json_path}/ {
        if (\$hack = 1) {return 404;}
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${sub_port};
        break;
    }

    #XHTTP
    location /${xhttp_path} {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_buffer_size 16k;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_set_header Connection "";
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Port \$server_port;
        grpc_set_header Host \$host;
        grpc_set_header X-Forwarded-Host \$host;
    }

    #Xray Config Path
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
        $CF_IP if (\$cloudflare_ip != 1) {return 404;}
        if (\$hack = 1) {return 404;}
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$request_method ~* ^(PUT|POST|GET)\$) {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
    }
    location / { try_files \$uri \$uri/ =404; }
}
EOF

    ##################################Check Nginx status####################################################

    if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
        unlink "/etc/nginx/sites-enabled/default" >/dev/null 2>&1
        rm -f "/etc/nginx/sites-enabled/default" "/etc/nginx/sites-available/default"
        ln -s "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
        ln -s "/etc/nginx/sites-available/${reality_domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
        ln -s "/etc/nginx/sites-available/80.conf" "/etc/nginx/sites-enabled/" 2>/dev/null
    else
        msg_err "${domain} nginx config not exist!" && exit 1
    fi

    if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
        msg_err "nginx config is not ok!" && exit 1
    else
        systemctl start nginx
    fi

    ##############################generate uri's###########################################################
    sub_uri=https://${domain}/${sub_path}/
    json_uri=https://${domain}/${web_path}?name=

    ########################################Update X-UI Port/Path for first INSTALL#########################

    UPDATE_XUIDB(){
        if [[ -f $XUIDB ]]; then
            x-ui stop
            
            # Clear existing data to avoid conflicts
            sqlite3 $XUIDB "DELETE FROM inbounds;"
            sqlite3 $XUIDB "DELETE FROM client_traffics;"
            sqlite3 $XUIDB "DELETE FROM settings;"

            # Perform the huge insert transaction
            sqlite3 $XUIDB <<EOF
BEGIN TRANSACTION;

INSERT INTO "settings" ("key", "value") VALUES ("webPort", '${panel_port}');
INSERT INTO "settings" ("key", "value") VALUES ("webBasePath", '/${panel_path}/');
INSERT INTO "settings" ("key", "value") VALUES ("username", '${config_username}');
INSERT INTO "settings" ("key", "value") VALUES ("password", '${config_password}');

INSERT INTO "settings" ("key", "value") VALUES ("subPort", '${sub_port}');
INSERT INTO "settings" ("key", "value") VALUES ("subPath", '/${sub_path}/');
INSERT INTO "settings" ("key", "value") VALUES ("subURI", '${sub_uri}');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonPath", '${json_path}');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonURI", '${json_uri}');
INSERT INTO "settings" ("key", "value") VALUES ("subEnable", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("webListen", '');
INSERT INTO "settings" ("key", "value") VALUES ("webDomain", '');
INSERT INTO "settings" ("key", "value") VALUES ("webCertFile", '');
INSERT INTO "settings" ("key", "value") VALUES ("webKeyFile", '');
INSERT INTO "settings" ("key", "value") VALUES ("sessionMaxAge", '60');
INSERT INTO "settings" ("key", "value") VALUES ("pageSize", '50');
INSERT INTO "settings" ("key", "value") VALUES ("expireDiff", '0');
INSERT INTO "settings" ("key", "value") VALUES ("trafficDiff", '0');
INSERT INTO "settings" ("key", "value") VALUES ("remarkModel", '-ieo');
INSERT INTO "settings" ("key", "value") VALUES ("tgBotEnable", 'false');
INSERT INTO "settings" ("key", "value") VALUES ("tgBotToken", '');
INSERT INTO "settings" ("key", "value") VALUES ("tgBotProxy", '');
INSERT INTO "settings" ("key", "value") VALUES ("tgBotAPIServer", '');
INSERT INTO "settings" ("key", "value") VALUES ("tgBotChatId", '');
INSERT INTO "settings" ("key", "value") VALUES ("tgRunTime", '@daily');
INSERT INTO "settings" ("key", "value") VALUES ("tgBotBackup", 'false');
INSERT INTO "settings" ("key", "value") VALUES ("tgBotLoginNotify", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("tgCpu", '80');
INSERT INTO "settings" ("key", "value") VALUES ("tgLang", 'en-US');
INSERT INTO "settings" ("key", "value") VALUES ("timeLocation", 'Europe/Moscow');
INSERT INTO "settings" ("key", "value") VALUES ("secretEnable", 'false');
INSERT INTO "settings" ("key", "value") VALUES ("subDomain", '');
INSERT INTO "settings" ("key", "value") VALUES ("subCertFile", '');
INSERT INTO "settings" ("key", "value") VALUES ("subKeyFile", '');
INSERT INTO "settings" ("key", "value") VALUES ("subUpdates", '12');
INSERT INTO "settings" ("key", "value") VALUES ("subEncrypt", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subShowInfo", 'true');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonFragment", '');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonNoises", '');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonMux", '');
INSERT INTO "settings" ("key", "value") VALUES ("subJsonRules", '');
INSERT INTO "settings" ("key", "value") VALUES ("datepicker", 'gregorian');

INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-8443', '1', '0', '', '8443', 'vless', '{"clients":[{"email":"Admin_1","flow":"xtls-rprx-vision","id":"bec3c72f-9846-467c-8b1a-bfffe961c4a0"},{"email":"Kolyan_1","flow":"xtls-rprx-vision","id":"b76bf60b-6bc4-4883-be94-3ff5806026dd"},{"email":"Polina_1","flow":"xtls-rprx-vision","id":"1781a6fd-6b23-4b62-a50f-a6b6472f1740"},{"email":"Mama_1","flow":"xtls-rprx-vision","id":"c3709fca-683a-4681-b6b4-9cf470ebea86"},{"email":"Vanya_1","flow":"xtls-rprx-vision","id":"75d508ef-6b10-474b-9886-58a232eac491"}],"decryption":"none","encryption":"none"}', '{"network":"tcp","realitySettings":{"maxClientVer":"","maxTimediff":0,"minClientVer":"","mldsa65Seed":"","privateKey":"wB0antknN9Mbsstl3FiX-qCDhME-zkel0-_jvLRJ-E0","serverNames":["${reality_domain}"],"shortIds":["b5c7d4e9ca6293b7","43571c735623caee","dba02c0b91612955","d8758ccd155f8368","98b22ddda1e29378","ddc7b4fa97d7fc30","8b79281105ebc70b","dd28bbd9b1ab4d8a"],"show":false,"target":"${reality_domain}:9443","xver":0},"security":"reality","tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}}}', 'inbound-8443', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','Admin_1','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','Kolyan_1','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','Polina_1','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','Mama_1','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('1','1','Vanya_1','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-17616', '1', '0', '', '17616', 'vless', '{"clients":[{"email":"Admin_2","flow":"","id":"e5f44bda-466d-4eb0-b125-5f775901510b"},{"email":"Kolyan_2","flow":"","id":"621701f7-98a0-432d-af27-6b4ead45fc2d"},{"email":"Polina_2","flow":"","id":"06ac05b7-1a48-4863-bee3-24bf4d55e641"},{"email":"Mama_2","flow":"","id":"a46f7b4f-a40a-4d59-923a-6e15df191b5c"},{"email":"Vanya_2","flow":"","id":"9f93e5d4-ba88-4410-819e-30fe73d00e70"}],"decryption":"none","encryption":"none"}', '{"network":"ws","security":"none","wsSettings":{"acceptProxyProtocol":false,"headers":{},"heartbeatPeriod":0,"host":"${domain}","path":"/17616/RNF5hpsooF7web_path"}}', 'inbound-17616', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','Admin_2','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','Kolyan_2','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','Polina_2','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','Mama_2','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('2','1','Vanya_2','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-/dev/shm/uds2023.sock,0666:0', '1', '0', '/dev/shm/uds2023.sock,0666', '0', 'vless', '{"clients":[{"email":"Admin_3","flow":"","id":"2ea4d8f7-04d7-4a3b-903b-2018b3372219"},{"email":"Kolyan_3","flow":"","id":"9fd05b20-8f8a-426f-8071-df7ed025e877"},{"email":"Polina_3","flow":"","id":"b3526cd2-eae0-4f07-98f1-7c0e24b3ba0f"},{"email":"Mama_3","flow":"","id":"2ce19df9-a7c1-4501-95d4-a33cd7a7569e"},{"email":"Vanya_3","flow":"","id":"5de5e90f-cdd4-43a0-b549-a111aa535fad"}],"decryption":"none","encryption":"none"}', '{"network":"xhttp","security":"none","sockopt":{"V6Only":false,"acceptProxyProtocol":false,"dialerProxy":"","domainStrategy":"UseIP","interface":"","mark":0,"penetrate":false,"tcpFastOpen":true,"tcpKeepAliveIdle":300,"tcpKeepAliveInterval":0,"tcpMaxSeg":1440,"tcpMptcp":true,"tcpUserTimeout":10000,"tcpWindowClamp":600,"tcpcongestion":"bbr","tproxy":"off"},"xhttpSettings":{"headers":{},"host":"","mode":"packet-up","noSSEHeader":false,"path":"/hmYZwdpd45","scMaxBufferedPosts":30,"scMaxEachPostBytes":"1000000","scStreamUpServerSecs":"20-80","xPaddingBytes":"100-1000"}}', 'inbound-/dev/shm/uds2023.sock,0666:0', '{"destOverride":["http","tls","quic","fakedns"],"enabled":true,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('3','1','Admin_3','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('3','1','Kolyan_3','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('3','1','Polina_3','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('3','1','Mama_3','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('3','1','Vanya_3','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-8444', '1', '0', '', '8444', 'vless', '{"clients":[{"email":"Admin_4","flow":"xtls-rprx-vision","id":"0522469d-e244-4fcd-9310-bfcbca47620b"},{"email":"Kolyan_4","flow":"xtls-rprx-vision","id":"123d7a49-6d1c-4dfb-b736-ffb51722c851"},{"email":"Polina_4","flow":"xtls-rprx-vision","id":"59b3c666-49d9-457c-8f86-65c91b1e7a72"},{"email":"Mama_4","flow":"xtls-rprx-vision","id":"9722f800-9b77-4043-ad64-a436cad3c527"},{"email":"Vanya_4","flow":"xtls-rprx-vision","id":"5d7a3c2b-ee0c-4c1c-89f3-447b971c352a"}],"decryption":"none","encryption":"none"}', '{"network":"tcp","realitySettings":{"maxClientVer":"","maxTimediff":0,"minClientVer":"","mldsa65Seed":"","privateKey":"qHoExob0BOkIv3AUSmOgd_fjb7szG2kriN-EddQm80I","serverNames":["sun6-21.userapi.com"],"shortIds":["068ef6be447c","2447768c6ae786","2b334d","e0","d9a6d938","222f","1c5e3d9245f83776","809687b385"],"show":false,"target":"sun6-21.userapi.com:443","xver":0},"security":"reality","tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}}}', 'inbound-8444', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('4','1','Admin_4','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('4','1','Kolyan_4','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('4','1','Polina_4','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('4','1','Mama_4','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('4','1','Vanya_4','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-8445', '1', '0', '', '8445', 'vless', '{"clients":[{"email":"Admin_5","flow":"xtls-rprx-vision","id":"04b23e24-6605-4aeb-bedd-41d924adcb99"},{"email":"Kolyan_5","flow":"xtls-rprx-vision","id":"24023601-e410-4f10-bc7b-7b0280f2aab9"},{"email":"Polina_5","flow":"xtls-rprx-vision","id":"7811c474-7ac1-4cba-a724-ca687cf4cf55"},{"email":"Mama_5","flow":"xtls-rprx-vision","id":"0f7ed7bc-44e2-481b-9e79-774ba215329e"},{"email":"Vanya_5","flow":"xtls-rprx-vision","id":"68dcd31b-8ebf-4e13-9ca4-1d30e0c00f05"}],"decryption":"none","encryption":"none"}', '{"network":"tcp","realitySettings":{"maxClientVer":"","maxTimediff":0,"minClientVer":"","mldsa65Seed":"","privateKey":"MINyqVBoSrFXvysVCXOZGDqRP_OtnhyQesN7x5xMikM","serverNames":["eh.vk.com"],"shortIds":["56e8","ed19cac27e10ba","51b067c0e5f7","9b","4e8dffb8","2.820627027606243e+15","a5412a","425ff8530c"],"show":false,"target":"eh.vk.com:443","xver":0},"security":"reality","tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}}}', 'inbound-8445', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('5','1','Admin_5','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('5','1','Kolyan_5','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('5','1','Polina_5','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('5','1','Mama_5','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('5','1','Vanya_5','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-8446', '1', '0', '', '8446', 'vless', '{"clients":[{"email":"Admin_6","flow":"xtls-rprx-vision","id":"c31cb996-8d50-4873-827a-9ef76492cea1"},{"email":"Kolyan_6","flow":"xtls-rprx-vision","id":"1621501f-6166-42ea-9dd1-3c8ff01192dd"},{"email":"Polina_6","flow":"xtls-rprx-vision","id":"56bd268a-2810-4dc4-933e-1f86125e052e"},{"email":"Mama_6","flow":"xtls-rprx-vision","id":"d40f9d60-80e9-4ae8-ab21-318a394f8720"},{"email":"Vanya_6","flow":"xtls-rprx-vision","id":"fb0768cc-3721-4164-8edd-8562e3ec85d4"}],"decryption":"none","encryption":"none"}', '{"network":"tcp","realitySettings":{"maxClientVer":"","maxTimediff":0,"minClientVer":"","mldsa65Seed":"","privateKey":"UMf7le8rrKd9Xc_lq1jLciXDn5F6Q8Z3BrXzsGUCxEM","serverNames":["io.ozone.ru"],"shortIds":["88","3d57","b7f86d372f23","f8e9ed","4756e375fb1f96a8","56e8733817d898","9aedcec1","2ee5eac5c4"],"show":false,"target":"io.ozone.ru:443","xver":0},"security":"reality","tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}}}', 'inbound-8446', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('6','1','Admin_6','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('6','1','Kolyan_6','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('6','1','Polina_6','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('6','1','Mama_6','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('6','1','Vanya_6','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-8447', '1', '0', '', '8447', 'vless', '{"clients":[{"email":"Admin_7","flow":"xtls-rprx-vision","id":"84ae4353-8864-45d9-a2bc-f0459086f3aa"},{"email":"Kolyan_7","flow":"xtls-rprx-vision","id":"44a0e4a9-171b-4ac3-9fdb-8622f9ee8d65"},{"email":"Polina_7","flow":"xtls-rprx-vision","id":"d8472e45-d0cf-4d6f-b88b-b3c82b24abe4"},{"email":"Mama_7","flow":"xtls-rprx-vision","id":"d77dd650-9ae8-4e31-9136-cafdf05f2630"},{"email":"Vanya_7","flow":"xtls-rprx-vision","id":"b5735b1b-8307-43c4-b278-7e66f2c29ca4"}],"decryption":"none","encryption":"none"}', '{"network":"tcp","realitySettings":{"maxClientVer":"","maxTimediff":0,"minClientVer":"","mldsa65Seed":"","privateKey":"gDAxlGMbmzvNJ7cHDTpvPqlnHvQU01cWLeYFLl9H6XQ","serverNames":["avatars.mds.yandex.net"],"shortIds":["96","779e","ce297cbd0a24f0","c7aa7e23bf1b9992","79435c","e963bd9ed1","25aae424cdc9","bf1cb599"],"show":false,"target":"avatars.mds.yandex.net:443","xver":0},"security":"reality","tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}}}', 'inbound-8447', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('7','1','Admin_7','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('7','1','Kolyan_7','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('7','1','Polina_7','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('7','1','Mama_7','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('7','1','Vanya_7','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-8448', '1', '0', '', '8448', 'vless', '{"clients":[{"email":"Admin_8","flow":"xtls-rprx-vision","id":"3fdf7d77-f0bd-4cd0-b261-154224a7dbd2"},{"email":"Kolyan_8","flow":"xtls-rprx-vision","id":"9738274a-0f04-4d89-a2ce-645d77e4e1e9"},{"email":"Mama_8","flow":"xtls-rprx-vision","id":"21476848-dcc0-402a-b98f-8f32f706b4b1"},{"email":"Polina_8","flow":"xtls-rprx-vision","id":"853513aa-088b-4589-aa3d-c040add6528a"},{"email":"Vanya_8","flow":"xtls-rprx-vision","id":"91529497-d971-42b6-af97-145f524a0153"}],"decryption":"none","encryption":"none"}', '{"network":"tcp","realitySettings":{"maxClientVer":"","maxTimediff":0,"minClientVer":"","mldsa65Seed":"","privateKey":"4P5jrTTTyDRUr2t45yW10hcIzo5VYemp5zn6SWgnbXI","serverNames":["tradingview.com"],"shortIds":["946b92fc","559e44","30ad","55fc5d6d32","aae375cc9050","df00ec5d1783328c","7834ad13021126","80"],"show":false,"target":"tradingview.com:443","xver":0},"security":"reality","tcpSettings":{"acceptProxyProtocol":true,"header":{"type":"none"}}}', 'inbound-8448', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('8','1','Admin_8','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('8','1','Kolyan_8','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('8','1','Mama_8','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('8','1','Polina_8','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('8','1','Vanya_8','0','0','0','0','0');
INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing") VALUES ( 
'1', '0', '0', '0', 'inbound-12620', '1', '0', '', '12620', 'trojan', '{"clients":[{"email":"Admin_9","flow":"","id":"","password":"BWWmfmIGda"},{"email":"Kolyan_9","password":"3jVgkveK2K"},{"email":"Mama_9","password":"lVRIawJgok"},{"email":"Polina_9","password":"kayohE4SDc"},{"email":"Vanya_9","password":"XQI1gVbuqh"}],"fallbacks":[]}', '{"grpcSettings":{"authority":"${domain}","multiMode":false,"serviceName":"/12620/asdAfAswdvbha"},"network":"grpc","security":"none"}', 'inbound-12620', '{"destOverride":["http","tls","quic","fakedns"],"enabled":false,"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('9','1','Admin_9','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('9','1','Kolyan_9','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('9','1','Mama_9','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('9','1','Polina_9','0','0','0','0','0');
INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset") VALUES ('9','1','Vanya_9','0','0','0','0','0');

COMMIT;
EOF
            
            echo "kill sub2sing-box..."
            pkill -x "sub2sing-box"
        fi

        if [ -f "/usr/bin/sub2sing-box" ]; then
            echo "delete sub2sing-box..."
            rm -f /usr/bin/sub2sing-box
        fi
        
        wget -P /root/ https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_amd64.tar.gz
        tar -xvzf /root/sub2sing-box_0.0.9_linux_amd64.tar.gz -C /root/ --strip-components=1 sub2sing-box_0.0.9_linux_amd64/sub2sing-box
        mv /root/sub2sing-box /usr/bin/
        chmod +x /usr/bin/sub2sing-box
        rm /root/sub2sing-box_0.0.9_linux_amd64.tar.gz
        su -c "/usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 & disown" root
    }

    UPDATE_XUIDB

    ######################install_fake_site#################################################################
    
    sudo su -c "bash <(wget -qO- https://raw.githubusercontent.com/mozaroc/x-ui-pro/refs/heads/master/randomfakehtml.sh)"

    ######################install_web_sub_page##############################################################
    
    URL_SUB_PAGE=( "https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui.html"
    "https://github.com/legiz-ru/x-ui-pro/raw/master/sub-3x-ui-classical.html" )

    URL_CLASH_SUB=( "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash.yaml"
    "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_skrepysh.yaml"
    "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_fullproxy_without_ru.yaml"
    "https://github.com/legiz-ru/x-ui-pro/raw/master/clash/clash_refilter_ech.yaml" )

    DEST_DIR_SUB_PAGE="/var/www/subpage"
    DEST_FILE_SUB_PAGE="$DEST_DIR_SUB_PAGE/index.html"
    DEST_FILE_CLASH_SUB="$DEST_DIR_SUB_PAGE/clash.yaml"

    sudo mkdir -p "$DEST_DIR_SUB_PAGE"

    sudo curl -L "${URL_CLASH_SUB[$CLASH]}" -o "$DEST_FILE_CLASH_SUB"
    sudo curl -L "${URL_SUB_PAGE[$CUSTOMWEBSUB]}" -o "$DEST_FILE_SUB_PAGE"

    sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_SUB_PAGE"
    sed -i "s/\${DOMAIN}/$domain/g" "$DEST_FILE_CLASH_SUB"
    sed -i "s#\${SUB_JSON_PATH}#$json_path#g" "$DEST_FILE_SUB_PAGE"
    sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_SUB_PAGE"
    sed -i "s#\${SUB_PATH}#$sub_path#g" "$DEST_FILE_CLASH_SUB"
    sed -i "s|sub.legiz.ru|$domain/$sub2singbox_path|g" "$DEST_FILE_SUB_PAGE"

    ######################cronjob for ssl/reload service/cloudflareips######################################

    crontab -l | grep -v "certbot\|x-ui\|cloudflareips" | crontab -
    (crontab -l 2>/dev/null; echo '@reboot /usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 > /dev/null 2>&1') | crontab -
    (crontab -l 2>/dev/null; echo '@daily x-ui restart > /dev/null 2>&1 && nginx -s reload;') | crontab -
    (crontab -l 2>/dev/null; echo '@weekly bash /etc/nginx/cloudflareips.sh > /dev/null 2>&1;') | crontab -
    (crontab -l 2>/dev/null; echo '@monthly certbot renew --nginx --non-interactive --post-hook "nginx -s reload" > /dev/null 2>&1;') | crontab -

    ##################################ufw###################################################################

    ufw disable
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable

    ##################################Show Details##########################################################

    if systemctl is-active --quiet x-ui; then clear
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
        nginx -T | grep -i 'ssl_certificate\|ssl_certificate_key'
        msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
        certbot certificates | grep -i 'Path:\|Domains:\|Expiry Date:'
        msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
        msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/\n"
        echo -e "Username: ${config_username} \n"
        echo -e "Password: ${config_password} \n"
        msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
        msg_inf "Web Sub Page your first client: https://${domain}/${web_path}?name=first\n"
        msg_inf "Your local sub2sing-box instance: https://${domain}/$sub2singbox_path/\n"
        msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
        msg_inf "Please Save this Screen!!"
    else
        nginx -t && printf '0\n' | x-ui | grep --color=never -i ':'
        msg_err "sqlite and x-ui to be checked, try on a new clean linux! "
    fi
fi

#################################################N-joy##################################################
