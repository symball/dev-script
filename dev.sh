#!/bin/bash
#!/
#!/# Author Simon Ball <open-source@simonball.me>
# A short shell script used to bootstrap services

#
# DEFAULTS. Should be no need to change these
#
red=`tput setaf 1`
green=`tput setaf 2`
blue=`tput setaf 4`
reset=`tput sgr0`
FOREGROUND=false
GROUP_ID=false
LAST_RUN_FILE=./.LAST_RUN
LOGS_ATTACH=false
PERFORM_SETUP=false
RUN_FIXTURES=false
RUNNING_LOCK=./.RUNNING
USER_ID=false
VERBOSE=true

#
# ENVIRONMENT SPECIFIC. This is the section you will want to change
#
REQUIRED_PROGRAMS="docker docker-compose"
REQUIRED_PORTS="3306 6379 7473 7474 7687"

#
# DATA UP
#
# Called either during setup or with the --database parameter
#
data_up()
{
  echo "${green}--=== DATA UP ===--${reset}"
  docker exec -it holitailor_api_server_dev_cli /bin/sh -c '
      ./bin/console doctrine:migrations:migrate -n && \
      echo "Running fixtures twice because doing hard drop on Graph DB as reset"
      ./bin/console doctrine:fixtures:load -n; \
      ./bin/console doctrine:fixtures:load -n'
}

#
# PRE SETUP
#
# If going to do something before starting up container / main env
# at setup time
#
pre_setup()
{
  echo "${green}--=== PRE SETUP ===--${reset}"
  echo "NA"
}
#
# SETUP
#
# Routine to perform once support services and env file managed
#
setup()
{
  echo "${green}--- SETUP${reset}"
  # Wait for Neo4J container to be up in order to run commands
  echo -ne "Waiting for Neo4J"
  until $(curl --output /dev/null --silent --head --fail http://localhost:7474); do
    echo -ne "."
    sleep 5
  done
  ok

  docker exec -it holitailor_neo4j_dev cypher-shell -u neo4j -p neo4j "CALL dbms.changePassword('control');"
  docker exec -it holitailor_neo4j_dev cypher-shell -u neo4j -p control "CALL dbms.security.createUser('development', 'temp')"
  docker exec -it holitailor_neo4j_dev cypher-shell -u development -p temp "CALL dbms.changePassword('development')"
  docker exec -it holitailor_api_server_dev_cli /bin/sh -c '
      composer install && \
      ./bin/console cache:clear'
  data_up
}
#
# UP
#
# Getting the main service to forefront in a non-destructive manner
#
up()
{
  echo "${green}--=== UP ===--${reset}"
  echo "Getting shell"
  docker exec -it holitailor_api_server_dev_cli bash
}
#
# DOWN
#
# Shutting down all services
#
down()
{
  echo "${green}--=== DOWN ===--${reset}"
  [ -f ./docker-compose.yml ] && docker-compose down
  rm $RUNNING_LOCK > /dev/null 2>&1
  halt "User stopped"
}
#
# END CUSTOMISATION
#

logo() {
  cat << "EOF"
 __                 _           _ _      
/ _\_   _ _ __ ___ | |__   ___ | (_) ___ 
\ \| | | | '_ ` _ \| '_ \ / _ \| | |/ __|
_\ \ |_| | | | | | | |_) | (_) | | | (__ 
\__/\__, |_| |_| |_|_.__/ \___/|_|_|\___|
    |___/ 

EOF
}

logo
echo "${green}--=== Symbolic Quick Script ===--${reset}"
echo ""

#
# HALT
#
# Safe method for stopping dev environment. If running the main
# process in foreground, will also shutdown services
#
halt() {
  echo "${red}--=== HALTING ===--${reset}"
  echo "$1"    
  exit 1
}

trap halt SIGHUP SIGINT SIGTERM

# Function to check whether command exists or not
exists()
{
  if command -v $1 &>/dev/null
    then return 0
    else return 1
  fi
}

ok() {
  echo -e " ${green}OK${reset}"
}

# Command help
display_usage() {
  echo "Get a basic environemnt up and running on a local device in a common format"
  echo ""
  echo " -c --command-line    Get a running shell on project"
  echo " -d --database        Run fixtures procedure"
  echo " -f --foreground      Run support services in foreground"
  echo " -h --help            Display this message and exit"
  echo " -s --initial-setup   Run a series off initiation procedures on the project"
  echo " -l --logs            Attach to the support service output"
  echo " -q --quiet           Minimal output"
  echo " -x --stop            Run the halt procedure"
  halt
}

# Parameter parsing
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      display_help
      ;;
    --database|-d)
      RUN_FIXTURES=true
      ;;
    --foreground|-f)
      FOREGROUND=true
      ;;
    --group|-g)
      GROUP_ID="${1#*=}"
      ;;
    --logs|-l)
      LOGS_ATTACH=true
      ;;
    --quiet|q)
      VERBOSE=false
      ;;
    --setup|-s)
      PERFORM_SETUP=true
      ;;
    --stop|-x)
      down
      ;;
  esac
  shift
done

#
# BASIC PREPARATION
#

# Check whether the required programs installed
[ "$VERBOSE" = true ] && echo "--- Checking required programs"
for PROGRAM in $REQUIRED_PROGRAMS; do
  if exists $PROGRAM; then
    [ "$VERBOSE" = true ] && echo -ne "$PROGRAM" && ok
  else halt "$PROGRAM Required"
  fi
done

# Are we looking at logs
if [ "$LOGS_ATTACH" = true ]; then
  if [ -f ./docker-compose.yml ]; then
    [ "$VERBOSE" = true ] && echo "--- Attaching to logs"
    docker-compose logs -f
    exit
  fi
fi

# Are we looking at logs
if [ "$RUN_FIXTURES" = true ]; then
  [ "$VERBOSE" = true ] && echo "--- Run data fixtures"
  data_up
  exit
fi

# If the script has never been run before, flip the initial setup condition
if [ ! -f $LAST_RUN_FILE ]; then
  [ "$VERBOSE" = true ] && echo "${green}First run detected${reset}"
  PERFORM_SETUP=true
fi

# The way of creating editable and runnable containers requires some user 
# mapping for the current account. On MAC OS, the default user groups are
# too low
[ "$VERBOSE" = true ] && echo "--- User Group"
if [ "$GROUP_ID" = false ]; then
  if [[ "$OSTYPE" == darwin* ]]; then
    [ "$VERBOSE" = true ] && echo "Running in a Mac environment"
    [ "$GROUP_ID" = false ] && GROUP_ID=$(python -c 'import grp; print(grp.getgrnam("shared_volume").gr_gid)')
    if [ "$GROUP_ID" = false ]; then
      echo "${red}Mac User Group Mapping Error${reset}"
      echo "In order to proceed, please provide a user group ID above 100 your account is in using -g"
      echo "Alternatively, create a user group shared_volume (including underscore), put yourself in it, and rerun"
      halt
    fi
  else
    GROUP_ID=$(id -g)
  fi
fi
[ "$VERBOSE" = true ] && echo "User Group: ${green}$GROUP_ID${reset}"

# Get the users ID to map
[ "$VERBOSE" = true ] && echo "--- User ID"
if [ "$USER_ID" = false ]; then
  USER_ID=$UID
  [ -z "$USER_ID" ] && USER_ID=$(id -u)
  [ -z "$USER_ID" ] && halt "Could not find User ID"
fi
[ "$VERBOSE" = true ] && echo "User ID: ${green}$USER_ID${reset}"

# Check whether ports are available
if [ ! -f $RUNNING_LOCK ]; then
  [ "$VERBOSE" = true ] && echo "--- Open Ports"
  for PORT in $REQUIRED_PORTS; do
    PORT_RESULT="$(lsof -i :${PORT})"
    if [ -z "$PORT_RESULT"]; then
      [ "$VERBOSE" = true ] && echo -ne "$PORT" && ok
    else
      halt "Port $PORT already in use"
    fi
  done
fi

#
# SERVICE STARTUP
#
echo "OK" > $LAST_RUN_FILE
if $PERFORM_SETUP ; then
  [ "$VERBOSE" = true ] && echo "--- Running Setup"
  if [ -f ./.env.dist ]; then
    echo "Copying environment file"
    cp .env.dist .env
  else 
   echo "" > .env
  fi
  tee -a .env > /dev/null <<EOT

USER_ID=$USER_ID
GROUP_ID=$GROUP_ID
EOT

  pre_setup
  if [ ! -f $RUNNING_LOCK ]; then
    if [ -f ./docker-compose.yml ]; then
      [ "$VERBOSE" = true ] && echo "Starting Docker"
      docker-compose up -d
      echo "OK" > $RUNNING_LOCK
    fi
  fi
  setup
  ok
else
  # Support services
  if [ ! -f $RUNNING_LOCK ]; then
    if [ -f ./docker-compose.yml ]; then
      [ "$VERBOSE" = true ] && echo "--- Running Docker support services"
      if [ "$FOREGROUND" = true ]; then
        docker-compose up
        echo "OK" > $RUNNING_LOCK
      else
        docker-compose up -d
        echo "OK" > $RUNNING_LOCK
      fi
    fi
  fi
fi
up
logo