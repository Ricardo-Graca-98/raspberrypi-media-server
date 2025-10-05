#!/usr/bin/env bash
set -e

# ---------------------------
# Load .env if it exists
# ---------------------------
if [ -f .env ]; then
    echo "📄 Loading .env file..."
    set -a
    [ -f .env ] && . .env
    set +a
    echo "✅ .env file loaded"
else
    echo "⚠️ No .env file found, using defaults"
fi

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

# Debug: Show all environment variables
echo "🔍 Environment variables after loading:"
echo "   MEDIA_PATH: '$MEDIA_PATH'"
echo "   DOWNLOADS_PATH: '$DOWNLOADS_PATH'"
echo "   MOVIES_PATH: '$MOVIES_PATH'"
echo "   SHOWS_PATH: '$SHOWS_PATH'"
echo "   PUID: '$PUID'"
echo "   PGID: '$PGID'"

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

# ---------------------------
# Create media subfolders
# ---------------------------
echo "📁 Creating media subfolders..."
echo "   MEDIA_PATH: $MEDIA_PATH"
echo "   DOWNLOADS_PATH: $MEDIA_PATH/$DOWNLOADS_PATH"
echo "   MOVIES_PATH: $MEDIA_PATH/$MOVIES_PATH"
echo "   SHOWS_PATH: $MEDIA_PATH/$SHOWS_PATH"

# Make sure MEDIA_PATH exists
if [ ! -d "$MEDIA_PATH" ]; then
    echo "⚠️ ERROR: MEDIA_PATH ($MEDIA_PATH) does not exist! Is your NVMe mounted?"
    exit 1
fi

# Create subfolders (temporarily override paths to ensure they're under MEDIA_PATH)
TEMP_DOWNLOADS_PATH="$MEDIA_PATH/$DOWNLOADS_PATH"
TEMP_MOVIES_PATH="$MEDIA_PATH/$MOVIES_PATH"
TEMP_SHOWS_PATH="$MEDIA_PATH/$SHOWS_PATH"

mkdir -p "$TEMP_DOWNLOADS_PATH" "$TEMP_MOVIES_PATH" "$TEMP_SHOWS_PATH"
chmod -R 775 "$MEDIA_PATH"
chown -R $USER:$USER "$MEDIA_PATH"

# Create download categories
for category in "${QBIT_CATEGORIES[@]}"; do
    mkdir -p "$TEMP_DOWNLOADS_PATH/$category"
done

echo "✅ Media subfolders created successfully"

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
HOSTNAME=$(hostname)
echo ""
echo "✨ Setup complete!"
echo "Access via:"
echo "  Jellyfin → http://${HOSTNAME}.local:${JELLYFIN_PORT}"
echo "  qBittorrent → http://${HOSTNAME}.local:${QBIT_WEBUI_PORT} (user: $QBIT_USERNAME / pass: $QBIT_PASSWORD)"
echo "  Radarr → http://${HOSTNAME}.local:${RADARR_PORT} (category: $MOVIES_CATEGORY)"
echo "  Sonarr → http://${HOSTNAME}.local:${SONARR_PORT} (category: $SHOWS_CATEGORY)"
echo "  Jackett → http://${HOSTNAME}.local:${JACKETT_PORT}"
echo ""
echo "🔗 Please complete the Jellyfin setup wizard in your browser."
echo "   Libraries should point to:"
echo "     $MOVIES_PATH"
echo "     $SHOWS_PATH"