#!/bin/sh
# Mock IMDS server that handles both IMDSv1 and IMDSv2 requests
# Usage: imds-server.sh <imds_root_dir> <port>

IMDS_ROOT="${1:-/tmp/imds}"
PORT="${2:-80}"
TOKEN="mock-imds-token-12345"

serve_request() {
    while read -r line; do
        # Trim carriage return
        line=$(echo "${line}" | tr -d '\r')

        # Parse request line
        case "${line}" in
            GET\ /*)
                METHOD="GET"
                PATH=$(echo "${line}" | cut -d' ' -f2)
                ;;
            PUT\ /*)
                METHOD="PUT"
                PATH=$(echo "${line}" | cut -d' ' -f2)
                ;;
            "")
                # End of headers
                break
                ;;
        esac
    done

    # Handle token request (IMDSv2)
    if [ "${METHOD}" = "PUT" ] && [ "${PATH}" = "/latest/api/token" ]; then
        BODY="${TOKEN}"
        CONTENT_TYPE="text/plain"
    # Handle metadata requests
    elif [ "${METHOD}" = "GET" ]; then
        # Map URL path to file
        FILE_PATH="${IMDS_ROOT}${PATH}"

        # Check for index.html if path is a directory
        if [ -d "${FILE_PATH}" ]; then
            FILE_PATH="${FILE_PATH}/index.html"
        fi

        if [ -f "${FILE_PATH}" ]; then
            BODY=$(cat "${FILE_PATH}")
            CONTENT_TYPE="text/plain"
        else
            # 404 Not Found
            printf "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
            return
        fi
    else
        # 405 Method Not Allowed
        printf "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n"
        return
    fi

    # Send response
    CONTENT_LENGTH=$(echo -n "${BODY}" | wc -c)
    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: %s\r\n" "${CONTENT_TYPE}"
    printf "Content-Length: %d\r\n" "${CONTENT_LENGTH}"
    printf "\r\n"
    printf "%s" "${BODY}"
}

# Listen and serve
while true; do
    echo "Listening on ${PORT}..." >&2
    serve_request | nc -l -p "${PORT}" -q 0 > /dev/null 2>&1
done
