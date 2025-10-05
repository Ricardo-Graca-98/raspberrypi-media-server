#!/usr/bin/env bash
set -e

# ---------------------------
# Load environment
# ---------------------------
: "${QBIT_USERNAME:=admin}"
: "${QBIT_PASSWORD:=adminadmin}"
: "${MEDIA_PATH:=./media}"
: "${DOWNLOADS_PATH:=${MEDIA_PATH}/downloads}"
: "${MOVIES_PATH:=${MEDIA_PATH}/movies}"
: "${SHOWS_PATH:=${MEDIA_PATH}/shows}"
: "${JELLYFIN_PORT:=8096}"
: "${QBIT_WEBUI_PORT:=8080}"
: "${SONARR_PORT:=8989}"
: "${RADARR_PORT:=7878}"
: "${MOVIES_CATEGORY:=radarr}"
: "${SHOWS_CATEGORY:=sonarr}"
: "${JACKETT_PORT:=9117}"
: "${OVERSEERR_PORT:=5055}"
: "${OVERSEERR_API_KEY:=}"

QBIT_CATEGORIES=("$MOVIES_CATEGORY" "$SHOWS_CATEGORY")
MEDIA_SUBDIRS=("movies" "shows")

# ---------------------------
# Check / Install Docker & Compose
# ---------------------------
echo "🔍 Checking for Docker..."
if ! command -v docker >/dev/null 2>&1; then
    echo "⚠️ Docker not found. Installing..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "✅ Docker installed. You may need to log out/in for group changes to take effect."
else
    echo "✅ Docker is already installed."
fi

echo "🔍 Checking for Docker Compose..."
if ! command -v docker-compose >/dev/null 2>&1; then
    echo "⚠️ Docker Compose not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
    echo "✅ Docker Compose installed."
else
    echo "✅ Docker Compose is already installed."
fi

# ---------------------------
# Create media folders
# ---------------------------
echo "📁 Creating media folders..."
mkdir -p "$MEDIA_PATH"
for dir in "${MEDIA_SUBDIRS[@]}"; do
    mkdir -p "${!dir^^}_PATH"  # Creates $MOVIES_PATH, $SHOWS_PATH
done
chmod -R 775 "$MEDIA_PATH"

# Create download category folders
for category in "${QBIT_CATEGORIES[@]}"; do
    mkdir -p "$DOWNLOADS_PATH/$category"
done

# ---------------------------
# Start Docker stack
# ---------------------------
echo "🚀 Starting Docker stack..."
docker compose up -d

# ---------------------------
# Wait for Jellyfin
# ---------------------------
MAX_RETRIES=60
SLEEP_SEC=2

echo "⏳ Waiting for Jellyfin to become ready..."
for i in $(seq 1 $MAX_RETRIES); do
    if curl -s -f "http://localhost:${JELLYFIN_PORT}/System/Info/Public" >/dev/null 2>&1; then
        echo "✅ Jellyfin is ready!"
        break
    fi
    echo "⏳ Jellyfin not ready yet... ($i/$MAX_RETRIES)"
    sleep $SLEEP_SEC
done

# ---------------------------
# Wait for qBittorrent & extract temporary password
# ---------------------------
echo "⏳ Waiting for qBittorrent WebUI..."
QBIT_TEMP_PASS=""
for i in $(seq 1 $MAX_RETRIES); do
    if docker logs qbittorrent 2>&1 | grep -q "temporary password is provided"; then
        QBIT_TEMP_PASS=$(docker logs qbittorrent 2>&1 | grep "temporary password is provided" | tail -n1 | awk -F': ' '{print $2}' | tr -d '[:space:]')
        echo "🔑 Found temporary qBittorrent password: $QBIT_TEMP_PASS"
    fi

    if curl -s -u "$QBIT_USERNAME:$QBIT_TEMP_PASS" "http://localhost:${QBIT_WEBUI_PORT}/api/v2/app/preferences" >/dev/null 2>&1; then
        echo "✅ qBittorrent API is responsive!"
        break
    fi

    echo "⏳ qBittorrent not ready yet... ($i/$MAX_RETRIES)"
    sleep $SLEEP_SEC
done

if [[ -z "$QBIT_TEMP_PASS" ]]; then
    echo "⚠️ Could not detect qBittorrent temporary password from logs. Exiting."
    exit 1
fi

# Login to qBittorrent to get SID cookie
echo "🔐 Logging in to qBittorrent WebUI..."
LOGIN_RESPONSE=$(curl -i \
  --header "Referer: http://localhost:${QBIT_WEBUI_PORT}" \
  --data "username=$QBIT_USERNAME&password=$QBIT_TEMP_PASS" \
  http://localhost:${QBIT_WEBUI_PORT}/api/v2/auth/login)

SID=$(echo "$LOGIN_RESPONSE" | grep -i "Set-Cookie: SID=" | sed -n 's/.*SID=\([^;]*\).*/\1/p')
if [ -z "$SID" ]; then
  echo "⚠️ Could not obtain SID cookie from login response"
  exit 1
fi
echo "✅ Obtained SID: $SID"
sleep 5

# Set qBittorrent preferences
echo "🏷️ Setting qBittorrent preferences (username/password & default save_path)..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --cookie "SID=$SID" \
  --header "Referer: http://localhost:${QBIT_WEBUI_PORT}" \
  -X POST http://localhost:${QBIT_WEBUI_PORT}/api/v2/app/setPreferences \
  --data-urlencode "json={
    \"web_ui_username\": \"$QBIT_USERNAME\",
    \"web_ui_password\": \"$QBIT_PASSWORD\",
    \"save_path\": \"$DOWNLOADS_PATH\"
  }")

if [ "$STATUS" -eq 200 ]; then
  echo "✅ qBittorrent preferences updated successfully"
else
  echo "⚠️ Failed to update qBittorrent preferences (HTTP $STATUS)"
fi

# Create qBittorrent categories
for category in "${QBIT_CATEGORIES[@]}"; do
  echo "🏷️ Creating qBittorrent category: $category → $DOWNLOADS_PATH/$category"
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --cookie "SID=$SID" \
    --header "Referer: http://localhost:${QBIT_WEBUI_PORT}" \
    -X POST "http://localhost:${QBIT_WEBUI_PORT}/api/v2/torrents/createCategory" \
    --data "category=$category&savePath=$DOWNLOADS_PATH/$category")

  if [ "$STATUS" -eq 200 ]; then
    echo "✅ Category '$category' created successfully"
  else
    echo "⚠️ Failed to create category '$category' (HTTP $STATUS)"
  fi
done

# ---------------------------
# Done
# ---------------------------
echo ""
echo "✨ Setup complete!"
echo "Access via:"
echo "  Jellyfin → http://localhost:${JELLYFIN_PORT}"
echo "  qBittorrent → http://localhost:${QBIT_WEBUI_PORT} (user: $QBIT_USERNAME / pass: $QBIT_PASSWORD)"
echo "  Radarr → http://localhost:${RADARR_PORT} (category: $MOVIES_CATEGORY)"
echo "  Sonarr → http://localhost:${SONARR_PORT} (category: $SHOWS_CATEGORY)"
echo "  Jackett → http://localhost:${JACKETT_PORT}"
echo ""
echo "🔗 Please complete the Jellyfin setup wizard in your browser."
echo "   Libraries should point to:"
echo "     $MOVIES_PATH"
echo "     $SHOWS_PATH"