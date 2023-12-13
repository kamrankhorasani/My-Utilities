#!/bin/bash
echo "Ziping files..."
zip -r openvpn.zip /etc/openvpn
echo "Uploading..."
scp /etc/openvpn.zip root@65.109.187.151:/root/BackUps/SRV-1/
echo "Done!"
