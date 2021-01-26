#!/usr/bin/env sh
${VERBOSE} && set -x

# shellcheck source=staging/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

# shellcheck source=staging/hooks/pingstate.lib.sh
. "${HOOKS_DIR}/pingstate.lib.sh"
# shellcheck source=staging/hooks/pingsecrets.lib.sh
. "${HOOKS_DIR}/pingsecrets.lib.sh"

echo_green "Command: ${*}"

# Process secrets
process_secrets

# Capture environment variables and secrets state info
add_state_info "environment_variables"

HOSTNAME=$(hostname -f)
DOMAINNAME=$(hostname -d)

export HOSTNAME DOMAINNAME

echo_header "Ping Identity DevOps Docker Image" \
    " IMAGE_VERSION: ${IMAGE_VERSION}" \
    " IMAGE_GIT_REV: ${IMAGE_GIT_REV}" \
    "       STARTED: $(date)" \
    "      HOSTNAME: ${HOSTNAME}" \
    "    DOMAINNAME: ${DOMAINNAME}"

if test -z "${1}" -o "$1" = "start-server" ;
then
    test -n "${1}" && shift
    # First ensure the STAGING_DIR is clean, before copying in
    # or pulling the server profile. This method will remove any
    # files in STAGING_DIR that are not built into the image.
    if test "${CLEAN_STAGING_DIR}" = "true"
    then
        clean_staging_dir
    fi

    # If there are local IN_DIR files, this will copy them to a STAGING_DIRECTORY
    # overwriting any files that may alrady be in staging
    apply_local_server_profile

    # if a git repo is provided, it has not yet been cloned
    # the only way to provide this hook is via the IN_DIR volume
    # aka "local server-profile"
    # or a previous run of the container that would then checkout
    #
    run_hook "01-start-server.sh"
    # shellcheck disable=SC1090
    . "${CONTAINER_ENV}"

    case "${RUN_PLAN}" in
        START)
            # First run of the container
            run_hook "10-start-sequence.sh"
            ;;
        RESTART)
            # Restart of an existing container
            run_hook "20-restart-sequence.sh"
            ;;
        *)
            container_failure 90 "Unknown RUN_PLAN, unable to continue"
            ;;
    esac

    run_hook "50-before-post-start.sh"

    # The 80-post-start.sh is placed in the background, and technically runs
    # before the service is actually started.  The post start SHOULD
    # poll the service (i.e. curl commands or ldapsearch or ...) to verify it
    # is running before performing the actual post start tasks.
    run_hook "80-post-start.sh" &

    if test -n "${TAIL_LOG_FILES}" ;
    then
        echo "Tailing log files (${TAIL_LOG_FILES})"
        if test -n "${TAIL_LOG_PARALLEL}";
        then
            # shellcheck disable=SC2086
            parallel -j 0 --tagstring "{}:" --line-buffer tail -F {} ::: ${TAIL_LOG_FILES} 2>/dev/null &
        else
            # shellcheck disable=SC2086
            tail -F ${TAIL_LOG_FILES} 2>/dev/null &
        fi
    fi

    # If there is no startup command provided, provide error message and exit.
    if test -z "${STARTUP_COMMAND}" ;
    then
        echo_red "*** NO CONTAINER STARTUP COMMAND PROVIDED ***"
        echo_red "*** Please set the environment variable STARTUP_COMMAND with a command to run"
        echo_red "*** Example: STARTUP_COMMAND=/opt/out/instance/bin/start-server"
        exit 90
    fi

    # If a command is provided after the "start-server" on the container start, then
    # startup the server in the background and then run that command.  A good example
    # is to run a shell after the startup.
    #
    # Example:
    #   run docker ....                        # Starts server in foreground
    #   run docker .... start-server           # Starts server in foreground (same as previous)
    #   run docker .... start-server /bin/sh   # Starts server in background and runs shell
    #   run docker .... /bin/sh                # Doesn't start the server but drops into a shell
    if test -z "${*}" ;
    then
        # replace the shell with foreground server
        echo_green "Starting server in foreground: (${STARTUP_COMMAND} ${STARTUP_FOREGROUND_OPTS})"
        # shellcheck disable=SC2086
        exec "${STARTUP_COMMAND}" ${STARTUP_FOREGROUND_OPTS}
    else
        # start server in the background and execute the provided command (useful for self-test)
        echo_green "Starting server in background: (${STARTUP_COMMAND} ${STARTUP_BACKGROUND_OPTS})"
        # shellcheck disable=SC2086
        "${STARTUP_COMMAND}" ${STARTUP_BACKGROUND_OPTS} &
        echo_green "Running command: ${*}"
        exec "${@}"
    fi
else
    echo_green "Running command: ${*}"
    exec "${@}"
fi
