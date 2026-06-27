#!/bin/bash
#
# Automated app configuration for Ethan's UGREEN DXP2800 arr-stack.
#
# Configures ONLY the trimmed stack:
#   - qBittorrent
#   - Sonarr
#   - Radarr
#   - Prowlarr
#   - FlareSolverr proxy in Prowlarr
#
# Intentionally does NOT configure:
#   - Bazarr
#   - Pi-hole
#   - SABnzbd
#   - Traefik
#   - Jellyfin / Seerr initial wizard steps
#
# Usage:
#   ./configure-apps.dxp2800.sh [OPTIONS]
#
# Options:
#   --dry-run       Preview what would be configured without making changes
#   --verbose, -v   Print curl response bodies on failure
#   --help, -h      Show help
#
# Prerequisites:
#   - Run this on the NAS after the Docker stack is up
#   - docker, curl, and python3 available
#   - This script and configure-helpers.dxp2800.sh in the same folder
#   - If qBittorrent password was changed, run like:
#       QBIT_PASSWORD='your-password' ./configure-apps.dxp2800.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/configure-helpers.dxp2800.sh"
if [[ ! -f "$HELPER" ]]; then
    echo "ERROR: Missing helper file: $HELPER"
    echo "Put configure-helpers.dxp2800.sh in the same folder as this script."
    exit 1
fi
source "$HELPER"

DRY_RUN=false
VERBOSE=false
NAS_IP=""
QBIT_COOKIE="/tmp/qbit_configure_cookie.txt"

CONFIGURED=0
SKIPPED=0
FAILED=0

SONARR_API_KEY=""
RADARR_API_KEY=""
PROWLARR_API_KEY=""
QBIT_USERNAME="${QBIT_USERNAME:-admin}"
QBIT_PASSWORD="${QBIT_PASSWORD:-}"

# Keep these false so the shared helper skips SABnzbd logic.
SABNZBD_RUNNING=false
SABNZBD_API_KEY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            sed -n '1,36p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--verbose|-v] [--help|-h]"
            exit 1
            ;;
    esac
done

echo "=== DXP2800 Arr-Stack App Configuration ==="
echo ""

for bin in docker curl python3; do
    if ! command -v "$bin" &>/dev/null; then
        echo "ERROR: $bin not found. Run this on the NAS and install/check prerequisites."
        exit 1
    fi
done

NAS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$NAS_IP" ]]; then
    echo "ERROR: Could not detect NAS IP"
    exit 1
fi
log "NAS IP: $NAS_IP"
if $DRY_RUN; then
    log "DRY RUN — no changes will be made"
fi
echo ""

REQUIRED_CONTAINERS="gluetun qbittorrent sonarr radarr prowlarr flaresolverr"
MISSING=""
for c in $REQUIRED_CONTAINERS; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        MISSING="$MISSING $c"
    fi
done
if [[ -n "$MISSING" ]]; then
    echo "ERROR: Required containers not running:$MISSING"
    echo "Start the stack first from /volume1/docker/arr-stack, for example:"
    echo "  docker compose -f docker-compose.dxp2800-arr-stack.yml up -d"
    exit 1
fi

GLUETUN_HEALTH=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' gluetun 2>/dev/null || echo unknown)
if [[ "$GLUETUN_HEALTH" != "healthy" && "$GLUETUN_HEALTH" != "no-healthcheck" ]]; then
    echo "ERROR: Gluetun is '$GLUETUN_HEALTH' (need 'healthy')."
    echo "       qBittorrent, Prowlarr, and FlareSolverr share Gluetun's network."
    echo "       Diagnose: docker logs gluetun --tail 50"
    exit 1
fi

log "Discovering API keys..."
SONARR_API_KEY=$(docker exec sonarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+' || true)
if [[ -z "$SONARR_API_KEY" ]]; then fail "Could not discover Sonarr API key"; else info "Sonarr API key: ${SONARR_API_KEY:0:8}..."; fi

RADARR_API_KEY=$(docker exec radarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+' || true)
if [[ -z "$RADARR_API_KEY" ]]; then fail "Could not discover Radarr API key"; else info "Radarr API key: ${RADARR_API_KEY:0:8}..."; fi

PROWLARR_API_KEY=$(docker exec prowlarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+' || true)
if [[ -z "$PROWLARR_API_KEY" ]]; then fail "Could not discover Prowlarr API key"; else info "Prowlarr API key: ${PROWLARR_API_KEY:0:8}..."; fi

# qBittorrent password: env var -> .env file -> docker logs temporary password
if [[ -z "$QBIT_PASSWORD" && -f .env ]]; then
    QBIT_PASSWORD=$(grep '^QBIT_PASSWORD=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
if [[ -z "$QBIT_PASSWORD" ]]; then
    QBIT_PASSWORD=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password is provided.*: \K\S+' | tail -1 || true)
fi
if [[ -z "$QBIT_PASSWORD" ]]; then
    echo ""
    echo "WARNING: Could not find qBittorrent password."
    echo "         If you changed it, run:"
    echo "         QBIT_PASSWORD='your-password' ./configure-apps.dxp2800.sh"
fi

echo ""

configure_qbittorrent() {
    log "Configuring qBittorrent..."

    local QBIT_URL="http://${NAS_IP}:8085"
    if ! wait_for_service "qBittorrent" "$QBIT_URL"; then return; fi

    if [[ -z "$QBIT_PASSWORD" ]]; then
        fail "qBittorrent: no password available, skipping"
        return
    fi

    if $DRY_RUN; then
        dry "Authenticate to qBittorrent"
        dry "Create category 'tv' → /data/torrents/tv"
        dry "Create category 'movies' → /data/torrents/movies"
        dry "Set preferences: auto TMM, UPnP off, encryption preferred, sane active limits"
        return
    fi

    local http_code
    if ! qbit_auth "$QBIT_URL" "$QBIT_USERNAME" "$QBIT_PASSWORD" "$QBIT_COOKIE"; then
        fail "qBittorrent: authentication failed (check QBIT_USERNAME/QBIT_PASSWORD)"
        return
    fi

    for cat_name in tv movies; do
        local save_path="/data/torrents/${cat_name}"
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -b "$QBIT_COOKIE" \
            --data-urlencode "category=${cat_name}" \
            --data-urlencode "savePath=${save_path}" \
            "${QBIT_URL}/api/v2/torrents/createCategory")

        if [[ "$http_code" == "200" ]]; then
            ok "qBittorrent: created category '${cat_name}' → ${save_path}"
        elif [[ "$http_code" == "409" ]]; then
            skip "qBittorrent: category '${cat_name}'"
        else
            fail "qBittorrent: create category '${cat_name}' (HTTP $http_code)"
        fi
    done

    local current_prefs
    current_prefs=$(curl -s -b "$QBIT_COOKIE" "${QBIT_URL}/api/v2/app/preferences" 2>/dev/null)

    if json_extract "$current_prefs" "
p = data
if not p.get('auto_tmm_enabled', False): sys.exit(1)
if p.get('upnp', True): sys.exit(1)
if p.get('encryption', 0) != 1: sys.exit(1)
if p.get('max_active_downloads', -1) != 5: sys.exit(1)
if p.get('max_active_torrents', -1) != 10: sys.exit(1)
if p.get('max_active_uploads', -1) != 5: sys.exit(1)
"; then
        skip "qBittorrent: preferences"
    else
        local prefs='{"auto_tmm_enabled":true,"upnp":false,"encryption":1,"max_active_downloads":5,"max_active_torrents":10,"max_active_uploads":5}'
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -b "$QBIT_COOKIE" \
            --data-urlencode "json=${prefs}" \
            "${QBIT_URL}/api/v2/app/setPreferences")

        if [[ "$http_code" == "200" ]]; then
            ok "qBittorrent: set preferences"
        else
            fail "qBittorrent: set preferences (HTTP $http_code)"
        fi
    fi

    rm -f "$QBIT_COOKIE"
}

SONARR_METADATA_FIELDS='[{"name":"seriesMetadata","value":true},{"name":"seriesMetadataEpisodeGuide","value":true},{"name":"seriesMetadataUrl","value":false},{"name":"episodeMetadata","value":true},{"name":"seriesImages","value":false},{"name":"seasonImages","value":false},{"name":"episodeImages","value":false}]'
SONARR_NAMING_PAYLOAD=$(cat <<'SONARR_EOF'
{"renameEpisodes":true,"replaceIllegalCharacters":true,"multiEpisodeStyle":5,"standardEpisodeFormat":"{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}","dailyEpisodeFormat":"{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}","animeEpisodeFormat":"{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels}{MediaInfo AudioLanguages}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec][ Mediainfo VideoBitDepth]bit}{-Release Group}","seasonFolderFormat":"Season {season:00}","seriesFolderFormat":"{Series TitleYear} [tvdbid-{TvdbId}]"}
SONARR_EOF
)

RADARR_METADATA_FIELDS='[{"name":"movieMetadata","value":true},{"name":"movieMetadataURL","value":false},{"name":"movieMetadataLanguage","value":1},{"name":"movieImages","value":false},{"name":"useMovieNfo","value":true}]'
RADARR_NAMING_PAYLOAD=$(cat <<'RADARR_EOF'
{"renameMovies":true,"replaceIllegalCharacters":true,"standardMovieFormat":"{Movie CleanTitle} {(Release Year)} {imdb-{ImdbId}} - {Edition Tags }{[Custom Formats]}{[Quality Full]}{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}","movieFolderFormat":"{Movie CleanTitle} ({Release Year})"}
RADARR_EOF
)

configure_prowlarr() {
    log "Configuring Prowlarr..."

    if [[ -z "$PROWLARR_API_KEY" ]]; then
        fail "Prowlarr: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:9696"
    local AUTH="X-Api-Key: ${PROWLARR_API_KEY}"

    if ! wait_for_service "Prowlarr" "${BASE}/api/v1/health"; then return; fi

    if $DRY_RUN; then
        dry "Add FlareSolverr proxy at http://localhost:8191"
        dry "Add Sonarr application: Prowlarr → http://sonarr:8989, Sonarr → http://gluetun:9696"
        dry "Add Radarr application: Prowlarr → http://radarr:7878, Radarr → http://gluetun:9696"
        return
    fi

    local proxies
    proxies=$(api_get "${BASE}/api/v1/indexerProxy" "$AUTH") || true
    if json_extract "$proxies" "sys.exit(0 if any(p.get('name','').lower() == 'flaresolverr' for p in data) else 1)"; then
        skip "Prowlarr: FlareSolverr proxy"
    else
        local fs_payload='{"name":"FlareSolverr","implementation":"FlareSolverr","configContract":"FlareSolverrSettings","fields":[{"name":"host","value":"http://localhost:8191"},{"name":"requestTimeout","value":60}],"tags":[]}'
        if api_post "${BASE}/api/v1/indexerProxy" "application/json" "$fs_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Prowlarr: added FlareSolverr proxy"
        else
            fail "Prowlarr: add FlareSolverr proxy"
        fi
    fi

    local apps
    apps=$(api_get "${BASE}/api/v1/applications" "$AUTH") || true

    local arr_name arr_port arr_categories arr_base
    for arr_name in Sonarr Radarr; do
        local key_var="${arr_name^^}_API_KEY"
        local arr_key="${!key_var}"
        if [[ "$arr_name" == "Sonarr" ]]; then
            arr_port=8989
            arr_base="http://sonarr:8989"
            arr_categories="[5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]"
        else
            arr_port=7878
            arr_base="http://radarr:7878"
            arr_categories="[2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]"
        fi

        local name_lower="${arr_name,,}"
        if json_extract "$apps" "sys.exit(0 if any(a.get('name','').lower() == '${name_lower}' for a in data) else 1)"; then
            skip "Prowlarr: ${arr_name} application"
        elif [[ -z "$arr_key" ]]; then
            fail "Prowlarr: add ${arr_name} (no ${arr_name} API key)"
        else
            local app_payload="{\"name\":\"${arr_name}\",\"syncLevel\":\"fullSync\",\"implementation\":\"${arr_name}\",\"configContract\":\"${arr_name}Settings\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://gluetun:9696\"},{\"name\":\"baseUrl\",\"value\":\"${arr_base}\"},{\"name\":\"apiKey\",\"value\":\"${arr_key}\"},{\"name\":\"syncCategories\",\"value\":${arr_categories}}],\"tags\":[]}"
            if api_post "${BASE}/api/v1/applications" "application/json" "$app_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Prowlarr: added ${arr_name} application"
            else
                fail "Prowlarr: add ${arr_name} application"
            fi
        fi
    done
}

configure_qbittorrent
echo ""
configure_arr_service "Sonarr" 8989 "$SONARR_API_KEY" "/data/media/tv" "tv" \
    "renameEpisodes" "$SONARR_METADATA_FIELDS" "$SONARR_NAMING_PAYLOAD"
echo ""
configure_arr_service "Radarr" 7878 "$RADARR_API_KEY" "/data/media/movies" "movies" \
    "renameMovies" "$RADARR_METADATA_FIELDS" "$RADARR_NAMING_PAYLOAD"
echo ""
configure_prowlarr

echo ""
echo "=========================================="
echo "Summary: ${CONFIGURED} configured, ${SKIPPED} skipped, ${FAILED} failed"
echo "=========================================="

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "Some steps failed. Re-run to retry, or configure that piece manually via the web UI."
fi

echo ""
echo "Remaining manual steps:"
echo "  1. Jellyfin: initial wizard, libraries, hardware transcoding"
echo "  2. Seerr: initial setup + Jellyfin/Sonarr/Radarr connections"
echo "  3. Prowlarr: add indexers with your own credentials/settings"
echo "  4. qBittorrent: change the default/temporary password in Tools → Options → Web UI"
echo ""
echo "Useful URLs:"
echo "  qBittorrent: http://${NAS_IP}:8085"
echo "  Prowlarr:    http://${NAS_IP}:9696"
echo "  Sonarr:      http://${NAS_IP}:8989"
echo "  Radarr:      http://${NAS_IP}:7878"
echo "  Jellyfin:    http://${NAS_IP}:8096"
echo "  Seerr:       http://${NAS_IP}:5055"

rm -f "$QBIT_COOKIE"
