#!/bin/bash

SERVICE_NAME="leproxy-docker-compose-app.service"
SOURCE_PATH="./$SERVICE_NAME"
DEST_PATH="/etc/systemd/system/$SERVICE_NAME"

# 1. Check if the source file exists in the current directory
if [ ! -f "$SOURCE_PATH" ]; then
    echo "Error: $SOURCE_PATH not found in current directory."
    exit 1
fi

echo "Deploying $SERVICE_NAME..."

# 2. Copy the file to the systemd directory
sudo cp "$SOURCE_PATH" "$DEST_PATH"

# 3. Set standard permissions (root-owned, 644)
sudo chown root:root "$DEST_PATH"
sudo chmod 644 "$DEST_PATH"

# 4. Reload systemd to recognize the new/updated file
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# 5. Enable the service so it runs at boot
echo "Enabling service for boot..."
sudo systemctl enable "$SERVICE_NAME"

# 6. Start the service now
echo "Starting service (this may take a moment if it's looping)..."
sudo systemctl restart "$SERVICE_NAME"

echo "Done! You can check progress with: journalctl -u $SERVICE_NAME -f"