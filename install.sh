#!/usr/bin/env bash
set -e

DRIVE_LABEL="MEDIA"
DEFAULT_MOUNT="/mnt/media"
MEDIA_SUBDIRS=("movies" "shows")

echo "🔧 Updating system..."
sudo apt update && sudo apt upgrade -y

echo "🐳 Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

echo "🧩 Installing Docker Compose plugin..."
sudo apt install -y docker-compose-plugin

# --- Detect & Mount Drive ---
echo "🔍 Looking for external drive '$DRIVE_LABEL'..."
MOUNT_PATH=""
if [ -d "/media/pi/$DRIVE_LABEL" ]; then
  MOUNT_PATH="/media/pi/$DRIVE_LABEL"
elif [ -d "/media/$DRIVE_LABEL" ]; then
  MOUNT_PATH="/media/$DRIVE_LABEL"
elif [ -d "$DEFAULT_MOUNT" ]; then
  MOUNT_PATH="$DEFAULT_MOUNT"
else
  UUID=$(blkid -L "$DRIVE_LABEL" || true)
  if [ -n "$UUID" ]; then
    sudo mkdir -p "$DEFAULT_MOUNT"
    sudo mount "$UUID" "$DEFAULT_MOUNT"
    MOUNT_PATH="$DEFAULT_MOUNT"
  fi
fi

if [ -z "$MOUNT_PATH" ]; then
  echo "⚠️ Could not find or mount drive '$DRIVE_LABEL'."
  echo "Proceeding without external drive."
  MOUNT_PATH="./media"
  mkdir -p "$MOUNT_PATH"
else
  echo "✅ Using drive mounted at: $MOUNT_PATH"
fi

# Ensure subfolders exist
for dir in "${MEDIA_SUBDIRS[@]}"; do
  sudo mkdir -p "$MOUNT_PATH/$dir"
done
sudo chown -R $USER:$USER "$MOUNT_PATH"
sudo chmod -R 775 "$MOUNT_PATH"

# --- Start containers ---
echo "🚀 Starting Docker stack..."
MEDIA_PATH=$MOUNT_PATH docker compose up -d

# --- Wait for services ---
echo "⏳ Waiting for Jellyfin to become available..."
for i in {1..30}; do
  if curl -s http://localhost:8096 >/dev/null; then
    echo "✅ Jellyfin is up!"
    break
  fi
  sleep 3
done

echo "⏳ Waiting for qBittorrent to become available..."
for i in {1..30}; do
  if curl -s http://localhost:8080 >/dev/null; then
    echo "✅ qBittorrent is up!"
    break
  fi
  sleep 3
done

# --- Configure Jellyfin libraries ---
echo "🎬 Adding default Jellyfin libraries..."
curl -s -X POST "http://localhost:8096/emby/Library/VirtualFolders" \
  -H "Content-Type: application/json" \
  -d "{\"Name\":\"Movies\",\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"/media/movies\"}]},\"CollectionType\":\"movies\"}" || true
curl -s -X POST "http://localhost:8096/emby/Library/VirtualFolders" \
  -H "Content-Type: application/json" \
  -d "{\"Name\":\"Shows\",\"LibraryOptions\":{\"PathInfos\":[{\"Path\":\"/media/shows\"}]},\"CollectionType\":\"tvshows\"}" || true

# --- Configure qBittorrent categories ---
echo "🏷️ Creating qBittorrent categories..."
curl -s -X POST "http://localhost:8080/api/v2/app/setPreferences" \
  --data-urlencode "json={
    \"save_path\": \"/media\",
    \"categories\": {
      \"movies\": {\"savePath\": \"/media/movies\"},
      \"shows\": {\"savePath\": \"/media/shows\"}
    },
    \"run_external_program\": true,
    \"run_program\": \"/media/qb_complete.sh %F\"
  }" || true

# --- Create Jellyfin refresh script for qBittorrent ---
echo "📝 Creating Jellyfin auto-refresh script..."
cat <<'EOF' > "$MOUNT_PATH/qb_complete.sh"
#!/usr/bin/env bash
# $1 = full path to finished torrent file/folder
curl -s -X POST "http://localhost:8096/Library/Refresh" || true
EOF

chmod +x "$MOUNT_PATH/qb_complete.sh"

echo ""
echo "✨ Setup complete!"
echo "Access via:"
echo "  Jellyfin → http://$(hostname -I | awk '{print $1}'):8096"
echo "  qBittorrent → http://$(hostname -I | awk '{print $1}'):8080"
echo ""
echo "New downloads will automatically trigger a Jellyfin library refresh."