#! /usr/bin/env bash

odin build . -debug -out:bin/fastcgi
sudo -u www-data ./bin/fastcgi --config="config.ini"
