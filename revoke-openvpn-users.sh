#!/bin/bash
SCRIPT_PATH="./openvpn-install.sh"
export MENU_OPTION="2"
echo -e '\n'
read -p "Please enter first account ID that you wan't to delete: " first_index
echo -e '\n'
read -p "Please enter last account ID that you wan't to delete: " last_index
echo -e '\n'
range=$((last_index-first_index))
read -p "You want to delete ${range} number of accounts: " user_resp

str2="y"

if [ "$user_resp" == "$str2" ]; then
	for i in $( seq 0 $range )
        do
        	export CLIENTNUMBER="${first_index}"
        	(exec "$SCRIPT_PATH")
        	sleep 0.7
        done
else
	exit
fi
