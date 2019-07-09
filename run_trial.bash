#!/usr/bin/env bash
set -e 
TEAM_NAME=$1
TASK_NAME=$2
TRIAL_NUM=$3

# Constants.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NOCOLOR='\033[0m'

# Define usage function.
usage()
{
  echo "Usage: $0 <team_name> <task_name> <trial_num>"
  exit 1
}

# Call usage() function if arguments not supplied.
[[ $# -ne 3 ]] && usage

SERVER_CONTAINER_NAME=vrx-server-system
ROS_DISTRO=melodic
LOG_DIR=/vrx/logs
NETWORK=vrx-network

# Get directory of this file
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Create the directory that logs will be copied into. Since the userid of the user in the container
# might different to the userid of the user running this script, we change it to be public-writable.
HOST_LOG_DIR=${DIR}/logs/$(date +%Y-%m-%d.%H-%M-%S)_logs/${TEAM_NAME}/${TASK_NAME}/${TRIAL_NUM}
echo "Creating directory: ${HOST_LOG_DIR}"
mkdir -p ${HOST_LOG_DIR}
chmod 777 ${HOST_LOG_DIR}
echo -e "${GREEN}Done.${NOCOLOR}\n"

# Find wamv urdf and task world files
echo "Looking for generated files"
TEAM_GENERATED_DIR=${DIR}/team_generated/${TEAM_NAME}
if [ -f "${TEAM_GENERATED_DIR}/${TEAM_NAME}.urdf" ]; then
  echo "Successfully found: ${TEAM_GENERATED_DIR}/${TEAM_NAME}.urdf"
else
  echo -e "${RED}Err: ${TEAM_GENERATED_DIR}/${TEAM_NAME}.urdf not found."; exit 1;
fi

COMP_GENERATED_DIR=${DIR}/task_generated/${TASK_NAME}
if [ -f "${COMP_GENERATED_DIR}/worlds/world${TRIAL_NUM}.world" ]; then
  echo "Successfully found: ${COMP_GENERATED_DIR}/worlds/world${TRIAL_NUM}.world"
else
  echo -e "${RED}Err: ${COMP_GENERATED_DIR}/worlds/world${TRIAL_NUM}.world not found."; exit 1;
fi
echo -e "${GREEN}Done.${NOCOLOR}\n"

# Ensure any previous containers are killed and removed.
${DIR}/kill_vrx_containers.bash

# Create the network for the containers to talk to each other.
${DIR}/vrx_network.bash ${NETWORK}

# Start the competition server. When the trial ends, the container will be killed.
# The trial may end because of time-out, because of completion, or because the user called the
# /vrx/end_competition service.
SERVER_CMD="/run_vrx_trial.sh /team_generated/${TEAM_NAME}.urdf /task_generated/worlds/world${TRIAL_NUM}.world ${LOG_DIR}"
${DIR}/vrx_server/run_container.bash ${SERVER_CONTAINER_NAME} vrx-server-${ROS_DISTRO}:latest \
  "--net ${NETWORK} \
  -v ${TEAM_GENERATED_DIR}:/team_generated \
  -v ${COMP_GENERATED_DIR}:/task_generated \
  -v ${HOST_LOG_DIR}:${LOG_DIR} \
  -e vrx_EXIT_ON_COMPLETION=1" \
  "${SERVER_CMD}" &

# Wait until server starts before competitor code can be run
echo "Waiting for server to start up"
sleep 20s

echo "Looking for dockerhub_url.txt"
DOCKERHUB_URL_FILENAME=${DIR}/team_config/${TEAM_NAME}/dockerhub_url.txt
if [ -f "${DOCKERHUB_URL_FILENAME}" ]; then
  echo "Successfully found: ${DOCKERHUB_URL_FILENAME}"
  DOCKERHUB_URL=$(head -n 1 ${DOCKERHUB_URL_FILENAME})
  echo "Dockerhub url: ${DOCKERHUB_URL}"
else
  echo -e "${RED}Err: ${DOCKERHUB_URL_FILENAME} not found."; exit 1;
fi

# Start the competitors container and let it run in the background.
COMPETITOR_RUN_SYSTEM_CMD="/move_forward.sh"
docker login
docker run --rm \
    --net ${NETWORK} \
    --name vrx-competitor-test \
    --env ROS_HOSTNAME=vrx-competitor-test \
    --env ROS_MASTER_URI=http://${SERVER_CONTAINER_NAME}:11311 \
    --env ROS_IP=172.19.0.3 \
    ${DOCKERHUB_URL} \
    ${COMPETITOR_RUN_SYSTEM_CMD} &

# Run competition for set time TODO(tylerlum): Make this close down based on competition finishing
echo "Send competitor commands for 100s"
sleep 100s
echo "100s up. Moving files now"

# TODO(tylerlum): Check what other files must be logged
# Copy the ROS log files from the competitor's container.
echo "Copying ROS log files from competitor container..."
docker cp --follow-link vrx-competitor-test:/root/.ros/log $HOST_LOG_DIR/ros-competitor
echo -e "${GREEN}OK${NOCOLOR}"

# Copy the ROS log files from the server's container.
echo "Copying ROS log files from server container..."
docker cp --follow-link ${SERVER_CONTAINER_NAME}:/home/developer/.ros/log $HOST_LOG_DIR/ros-server
docker cp --follow-link ${SERVER_CONTAINER_NAME}:/home/developer/.ros/log/latest $HOST_LOG_DIR/ros-server-latest
docker cp --follow-link ${SERVER_CONTAINER_NAME}:/home/developer/vrx_task_info.bag $HOST_LOG_DIR/

echo -e "${GREEN}OK${NOCOLOR}"

echo "sleeping for 50s"
sleep 50s

# Kill and remove all containers before exit
# ./kill_vrx_containers.bash

exit 0
