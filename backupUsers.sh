#!/bin/bash
SERVER="lta1"
REMOTE_IP="94.182.62.84"
DATE=$(date +%Y-%m-%d)
KEEP_DAYS=7

echo "Ziping files..."
zip -r "openvpn_${DATE}.zip" /etc/openvpn

echo "Checking/creating directory on $SERVER..."
ssh root@$REMOTE_IP "mkdir -p /root/userbackup/${SERVER}"

echo "Cleaning backups older than $KEEP_DAYS days on $SERVER..."
ssh root@$REMOTE_IP "find /root/userbackup/${SERVER}/ -name 'openvpn_*.zip' -mtime +$KEEP_DAYS -exec rm -f {} \;"

echo "Uploading to $SERVER..."
scp "openvpn_${DATE}.zip" root@$REMOTE_IP:/root/userbackup/${SERVER}/
if [ $? -eq 0 ]; then
    echo "Upload successful!"
    echo "Removing local zip file..."
    rm -f "openvpn_${DATE}.zip"
else
    echo "Upload failed!"
    exit 1
fi

COUNT=$(ssh root@$REMOTE_IP "ls -1 /root/userbackup/${SERVER}/openvpn_*.zip | wc -l")
echo "Backup completed! $COUNT backup files remain."
