#!/usr/bin/env bash
# ==============================================================================
# AIDA - Docker Startup Script
# ==============================================================================
# Starts the AIDA platform. Smart detection: skips build if already done.
# ==============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}\n${BLUE}  $*${NC}\n${BLUE}══════════════════════════════════════${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Parse arguments
FORCE_BUILD=false
SKIP_CHECKS=false
INSTALL_EXEGOL=false
for arg in "$@"; do
    case $arg in
        --build|-b)       FORCE_BUILD=true ;;
        --fast|-f)        SKIP_CHECKS=true ;;
        --install-exegol) INSTALL_EXEGOL=true ;;
        --help|-h)
            echo "Usage: ./start.sh [OPTIONS]"
            echo "  --build, -b         Force rebuild Docker images"
            echo "  --fast, -f          Skip dependency checks (faster startup)"
            echo "  --install-exegol    Install Exegol CLI and image if missing"
            echo "  --help, -h          Show this help"
            exit 0
            ;;
    esac
done

section "AIDA - Starting Platform"

# ==============================================================================
# QUICK CHECKS
# ==============================================================================

# Docker check
if ! command -v docker &> /dev/null; then
    error "Docker not installed. Get it from: https://docker.com/products/docker-desktop"
    exit 1
fi

if ! docker info &> /dev/null; then
    error "Docker daemon not running. Start Docker Desktop first."
    exit 1
fi

# ==============================================================================
# CHECK PORT CONFLICTS
# ==============================================================================

check_port() {
    local port=$1
    local service=$2
    # Use lsof (macOS/Linux) or ss (Linux fallback)
    if command -v lsof &>/dev/null; then
        if lsof -iTCP:"$port" -sTCP:LISTEN -P -n 2>/dev/null | grep -q LISTEN; then
            local process=$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR==2 {print $1}')
            warn "Port $port ($service) is already in use by: $process"
            return 1
        fi
    elif command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            local process=$(ss -tlnp 2>/dev/null | grep ":$port " | sed 's/.*users:(("\([^"]*\)".*/\1/')
            warn "Port $port ($service) is already in use by: $process"
            return 1
        fi
    fi
    return 0
}

PORT_CONFLICT=false
check_port 5432 "PostgreSQL" || PORT_CONFLICT=true
check_port 8000 "Backend"    || PORT_CONFLICT=true
check_port 5173 "Frontend"   || PORT_CONFLICT=true

if [[ "$PORT_CONFLICT" == "true" ]]; then
    echo ""
    warn "Port conflict detected! Options:"
    warn "  1. Stop the conflicting process"
    warn "  2. Change ports in docker-compose.yml"
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "Aborted due to port conflict"
        exit 1
    fi
fi

# ==============================================================================
# CHECK IF ALREADY RUNNING
# ==============================================================================

CONTAINERS_RUNNING=$(docker compose ps --status running -q 2>/dev/null | wc -l | tr -d ' ')

if [[ "$CONTAINERS_RUNNING" -ge 3 ]] && [[ "$FORCE_BUILD" == "false" ]]; then
    log "AIDA is already running!"
    echo ""
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    log "Frontend: http://localhost:5173"
    log "Backend:  http://localhost:8000"
    echo ""
    warn "Use --build to force rebuild, or ./restart.sh to restart"
    exit 0
fi

# ==============================================================================
# ENVIRONMENT FILES (Quick)
# ==============================================================================

if [[ ! -f backend/.env ]]; then
    if [[ -f backend/.env.docker ]]; then
        cp backend/.env.docker backend/.env
        log "Created backend/.env"
    elif [[ -f backend/.env.example ]]; then
        cp backend/.env.example backend/.env
        log "Created backend/.env from example"
    fi
fi

if [[ ! -f frontend/.env ]]; then
    echo "VITE_API_URL=http://localhost:8000/api" > frontend/.env
    log "Created frontend/.env"
fi

# ==============================================================================
# PYTHON ENVIRONMENTS (Only if missing)
# ==============================================================================

if [[ "$SKIP_CHECKS" == "false" ]]; then
    # Find Python 3.10+
    PYTHON_CMD="python3"
    for py in python3.13 python3.12 python3.11 python3.10; do
        if command -v $py &> /dev/null; then
            PYTHON_CMD=$py
            break
        fi
    done

    # CLI venv
    if [[ ! -f ".venv/bin/python" ]]; then
        log "Creating CLI virtual environment..."
        $PYTHON_CMD -m venv .venv
        .venv/bin/pip install -q --upgrade pip
        [[ -f requirements.txt ]] && .venv/bin/pip install -q -r requirements.txt
        log "CLI environment ready"
    fi

    # Backend venv (for MCP server)
    if [[ ! -f "backend/venv/bin/python" ]]; then
        log "Creating backend virtual environment..."
        $PYTHON_CMD -m venv backend/venv
        backend/venv/bin/pip install -q --upgrade pip
        [[ -f backend/requirements.txt ]] && backend/venv/bin/pip install -q -r backend/requirements.txt
        log "Backend environment ready"
    fi
fi

# ==============================================================================
# DOCKER - Smart Build
# ==============================================================================

section "Docker Containers"

# Check for orphan containers from other projects with same names
ORPHAN_POSTGRES=$(docker ps -a --format "{{.Names}}" | grep "^aida_postgres$" || true)
ORPHAN_BACKEND=$(docker ps -a --format "{{.Names}}" | grep "^aida_backend$" || true)
ORPHAN_FRONTEND=$(docker ps -a --format "{{.Names}}" | grep "^aida_frontend$" || true)

# Check if these containers belong to our project
OUR_CONTAINERS=$(docker compose ps -a -q 2>/dev/null | wc -l | tr -d ' ')

if [[ -n "$ORPHAN_POSTGRES" || -n "$ORPHAN_BACKEND" || -n "$ORPHAN_FRONTEND" ]] && [[ "$OUR_CONTAINERS" -eq 0 ]]; then
    warn "Found containers from another project with same names"
    log "Removing orphan containers..."
    docker rm -f aida_postgres aida_backend aida_frontend 2>/dev/null || true
    log "Orphan containers removed"
fi

# Check if volume exists but belongs to another project - recreate it for this project
VOLUME_EXISTS=$(docker volume ls -q | grep "^aida_postgres_data$" || true)
if [[ -n "$VOLUME_EXISTS" ]]; then
    # Volume exists - check if it's labeled for another project
    VOLUME_PROJECT=$(docker volume inspect aida_postgres_data --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null || true)
    if [[ -n "$VOLUME_PROJECT" && "$VOLUME_PROJECT" != "aida" ]]; then
        log "Adopting existing postgres volume from project '$VOLUME_PROJECT'"
        # Remove old labels by recreating volume metadata (data preserved)
        # Docker compose will re-label it on next up
    fi
fi

# Check if images exist
BACKEND_IMAGE=$(docker images -q aida-backend 2>/dev/null)
FRONTEND_IMAGE=$(docker images -q aida-frontend 2>/dev/null)

if [[ -z "$BACKEND_IMAGE" ]] || [[ -z "$FRONTEND_IMAGE" ]] || [[ "$FORCE_BUILD" == "true" ]]; then
    log "Building Docker images..."
    docker compose build --quiet
    log "Images built"
else
    log "Docker images already exist (use --build to rebuild)"
fi

# ==============================================================================
# START CONTAINERS
# ==============================================================================

# Check current state
STOPPED_CONTAINERS=$(docker compose ps --status exited -q 2>/dev/null | wc -l | tr -d ' ')
RUNNING_CONTAINERS=$(docker compose ps --status running -q 2>/dev/null | wc -l | tr -d ' ')

if [[ "$RUNNING_CONTAINERS" -ge 3 ]]; then
    log "Containers already running"
elif [[ "$STOPPED_CONTAINERS" -gt 0 ]]; then
    log "Starting existing containers..."
    docker compose start 2>/dev/null
else
    log "Creating and starting containers..."
    # Suppress volume warning (cosmetic - data is preserved)
    docker compose up -d 2>&1 | grep -v "already exists but was created for project" || true
fi

# ==============================================================================
# WAIT FOR SERVICES
# ==============================================================================

section "Waiting for Services"

wait_for_service() {
    local name=$1
    local check_cmd=$2
    local max_wait=${3:-30}
    local i=0

    printf "  %-12s " "$name..."
    while ! eval "$check_cmd" &>/dev/null; do
        ((i++))
        if [[ $i -ge $max_wait ]]; then
            echo -e "${RED}TIMEOUT${NC}"
            return 1
        fi
        sleep 1
    done
    echo -e "${GREEN}Ready${NC}"
}

wait_for_service "PostgreSQL" "docker compose exec -T postgres pg_isready -U aida"
wait_for_service "Backend" "curl -sf http://localhost:8000/health"
wait_for_service "Frontend" "curl -sf http://localhost:5173"

# ==============================================================================
# FOLDER OPENER (Background helper)
# ==============================================================================

pkill -f "folder_opener.py" 2>/dev/null || true
if [[ -f "$SCRIPT_DIR/tools/folder_opener.py" ]]; then
    python3 "$SCRIPT_DIR/tools/folder_opener.py" &>/dev/null &
fi

# ==============================================================================
# EXEGOL SETUP (optional install when missing)
# ==============================================================================

# Resolve Exegol container short name (e.g. exegol-aida -> aida)
EXEGOL_NAME="aida"
if [[ -f backend/.env ]]; then
    EXEGOL_DEFAULT=$(grep -E "^DEFAULT_CONTAINER_NAME=" backend/.env 2>/dev/null | cut -d= -f2- | tr -d '"'\'' ')
    if [[ -n "$EXEGOL_DEFAULT" && "$EXEGOL_DEFAULT" == exegol-* ]]; then
        EXEGOL_NAME="${EXEGOL_DEFAULT#exegol-}"
    fi
fi

EXEGOL_EXISTS=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -i "^exegol-" || true)
EXEGOL_RUNNING=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i "^exegol-" || true)

install_exegol_cli() {
    if command -v exegol &>/dev/null; then return 0; fi
    log "Exegol CLI not found. Installing..."
    if command -v pipx &>/dev/null; then
        pipx install exegol && return 0
    fi
    if command -v pip3 &>/dev/null; then
        pip3 install --user exegol 2>/dev/null && return 0
    fi
    if command -v pip &>/dev/null; then
        pip install --user exegol 2>/dev/null && return 0
    fi
    # Ensure PATH includes user Python bin (e.g. ~/.local/bin)
    if [[ -d "$HOME/.local/bin" ]]; then
        export PATH="$HOME/.local/bin:$PATH"
        if command -v exegol &>/dev/null; then return 0; fi
    fi
    return 1
}

if [[ "$SKIP_CHECKS" == "false" ]] || [[ "$INSTALL_EXEGOL" == "true" ]]; then
    if [[ -z "$EXEGOL_EXISTS" ]] || [[ -n "$EXEGOL_EXISTS" && -z "$EXEGOL_RUNNING" ]]; then
        if install_exegol_cli; then
            if [[ -z "$EXEGOL_EXISTS" ]]; then
                echo ""
                log "No Exegol container found. Installing Exegol image (web profile, ~few GB)..."
                log "To install the full image (~40GB) later, run: exegol install full"
                if exegol install web 2>/dev/null; then
                    log "Exegol image installed"
                else
                    warn "Exegol image install failed or was skipped. Run manually: exegol install web"
                fi
            fi
            if [[ -z "$EXEGOL_RUNNING" ]] && command -v exegol &>/dev/null; then
                log "Starting Exegol container: exegol-$EXEGOL_NAME"
                if exegol start "$EXEGOL_NAME" 2>/dev/null; then
                    log "Exegol container started"
                else
                    warn "Could not start Exegol. Run manually: exegol start $EXEGOL_NAME"
                fi
            fi
        else
            if [[ -z "$EXEGOL_EXISTS" ]]; then
                echo ""
                warn "Exegol CLI could not be installed automatically."
                warn "Install it manually: pipx install exegol   (then: exegol install web && exegol start $EXEGOL_NAME)"
            fi
        fi
    fi
fi

EXEGOL_RUNNING=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -i "^exegol-" || true)
if [[ -z "$EXEGOL_RUNNING" ]]; then
    echo ""
    warn "No Exegol container running!"
    warn "AIDA needs Exegol for pentesting tools."
    warn "Install: pipx install exegol && exegol install web && exegol start $EXEGOL_NAME"
fi

# ==============================================================================
# SUCCESS
# ==============================================================================

section "AIDA Ready"

echo ""
log "Frontend:  http://localhost:5173"
log "Backend:   http://localhost:8000"
log "API Docs:  http://localhost:8000/docs"
echo ""
docker compose ps --format "table {{.Name}}\t{{.Status}}"
echo ""
