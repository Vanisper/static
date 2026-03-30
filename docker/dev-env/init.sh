#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT_NAME="dev-env"

MYSQL_SERVICE="mysql"
MYSQL_PORT="3306"
WAIT_FOR_HEALTH=1
PULL_LATEST=0
PROFILE_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./init.sh [options]

Options:
  --mysql57   Start MySQL 5.7 instead of MySQL 8.4
  --no-wait   Do not wait for containers to become healthy
  --pull      Pull latest images before startup
  -h, --help  Show this help message
EOF
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

docker_compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

container_health() {
  local container_name="$1"
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || true
}

wait_for_container() {
  local container_name="$1"
  local label="$2"
  local timeout_seconds="${3:-180}"
  local elapsed=0
  local status

  printf 'Waiting for %s' "$label"
  while (( elapsed < timeout_seconds )); do
    status="$(container_health "$container_name")"
    case "$status" in
      healthy|running)
        echo " ready"
        return 0
        ;;
      unhealthy|exited|dead)
        echo
        echo "$label failed with status: $status" >&2
        docker ps -a --filter "name=^${container_name}$"
        return 1
        ;;
    esac

    printf '.'
    sleep 2
    elapsed=$((elapsed + 2))
  done

  echo
  echo "Timed out waiting for $label" >&2
  return 1
}

print_summary() {
  cat <<EOF

Dev environment is ready.

Services:
  MySQL    127.0.0.1:${MYSQL_PORT}  user=app  password=app123456  db=app
  Redis    127.0.0.1:6379
  RabbitMQ 127.0.0.1:5672  user=app  password=app123456
  RabbitMQ UI http://127.0.0.1:15672

Useful commands:
  docker compose -f ${COMPOSE_FILE} ps
  docker compose -f ${COMPOSE_FILE} logs -f
  docker compose -f ${COMPOSE_FILE} down
EOF
}

while (($# > 0)); do
  case "$1" in
    --mysql57)
      MYSQL_SERVICE="mysql57"
      MYSQL_PORT="3307"
      PROFILE_ARGS=(--profile mysql57)
      shift
      ;;
    --no-wait)
      WAIT_FOR_HEALTH=0
      shift
      ;;
    --pull)
      PULL_LATEST=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command docker

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is not available. Please install Docker Compose v2." >&2
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi

echo "Initializing dev environment from $COMPOSE_FILE"
echo "Project name: $PROJECT_NAME"
echo "Database service: $MYSQL_SERVICE"

if (( PULL_LATEST == 1 )); then
  docker_compose "${PROFILE_ARGS[@]}" pull "$MYSQL_SERVICE" redis rabbitmq
fi

compose_args=("${PROFILE_ARGS[@]}" up -d)
compose_args+=("$MYSQL_SERVICE" redis rabbitmq)

docker_compose "${compose_args[@]}"

if (( WAIT_FOR_HEALTH == 1 )); then
  wait_for_container "$MYSQL_SERVICE" "$MYSQL_SERVICE"
  wait_for_container "redis" "redis"
  wait_for_container "rabbitmq" "rabbitmq"
fi

print_summary
