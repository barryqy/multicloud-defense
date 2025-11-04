#!/bin/bash
# Update package list and install required packages
sudo apt-get update -y
sudo apt-get install -y w3m apache2

# Start and enable Apache
sudo systemctl start apache2
sudo systemctl enable apache2

# Create status file directly (don't depend on file provisioners)
echo "This is application 2" | sudo tee /var/www/html/status > /dev/null

# Copy other files if they exist (uploaded by provisioners)
if [ -f /home/ubuntu/aws-app.png ]; then
    sudo cp /home/ubuntu/aws-app.png /var/www/html/aws-app.png
fi

if [ -f /home/ubuntu/index.html ]; then
    sudo cp /home/ubuntu/index.html /var/www/html/index.html
fi

# Ensure proper permissions
sudo chown -R www-data:www-data /var/www/html/
sudo chmod -R 755 /var/www/html/