#!/bin/sh

[ -n "$(ls /etc/pre_install)" ] && opkg install /etc/pre_install/*.ipk --force-depends
rm -rf /etc/pre_install

exit 0
