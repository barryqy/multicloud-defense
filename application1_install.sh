#!/bin/bash
sudo apt-get update
sudo apt-get install -y w3m
sudo apt-get install -y apache2
sudo systemctl start apache2
sudo systemctl enable apache2
cd ../../var/www/html/
sudo cp /home/ubuntu/aws-app.png /var/www/html/aws-app.png
sudo cp /home/ubuntu/index.html /var/www/html/index.html
sudo cp /home/ubuntu/status /var/www/html/status