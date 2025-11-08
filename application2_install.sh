#!/bin/bash
# Update package list and install required packages
sudo apt-get update -y
sudo apt-get install -y w3m apache2

# Start and enable Apache
sudo systemctl start apache2
sudo systemctl enable apache2

# Create status file directly (don't depend on file provisioners)
echo "This is application 2" | sudo tee /var/www/html/status > /dev/null

# Create a default index.html (will be overwritten if provisioner succeeds)
cat <<'EOF' | sudo tee /var/www/html/index.html > /dev/null
<!DOCTYPE html>
<html>
<head>
    <title>Application 2 - Multicloud Defense Lab</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f0f0f0; }
        .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #1ba672; }
        .info { background: #e7f9f0; padding: 15px; border-left: 4px solid #1ba672; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Application 2</h1>
        <div class="info">
            <p><strong>Status:</strong> Running</p>
            <p><strong>Protected by:</strong> Cisco Multicloud Defense</p>
            <p><strong>Security:</strong> East-West Inspection Enabled</p>
        </div>
        <p>This application is protected by Cisco Multicloud Defense with east-west traffic inspection.</p>
        <p><a href="/status">Check Status</a></p>
    </div>
</body>
</html>
EOF

# Copy other files if they exist (uploaded by provisioners - will override defaults)
if [ -f /home/ubuntu/aws-app.png ]; then
    sudo cp /home/ubuntu/aws-app.png /var/www/html/aws-app.png
fi

if [ -f /home/ubuntu/index.html ]; then
    sudo cp /home/ubuntu/index.html /var/www/html/index.html
fi

# Ensure proper permissions
sudo chown -R www-data:www-data /var/www/html/
sudo chmod -R 755 /var/www/html/