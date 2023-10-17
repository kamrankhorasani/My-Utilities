#!/bin/bash

ufw allow 22

ufw allow 443

ufw allow 8000

ufw allow 8001

ufw deny out from any to 141.101.78.0/23

ufw deny out from any to 173.245.48.0/20

ufw deny out from any to 173.245.0.0/16

ufw deny out from any to 141.101.0.0/16

ufw enable

ufw status
