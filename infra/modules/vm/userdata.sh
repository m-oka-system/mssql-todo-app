#!/usr/bin/env bash

# Install nginx
sudo apt-get update && sudo apt-get install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
