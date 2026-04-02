FROM alpine:3.21

# Install only what's needed: socat + openssh client + iproute2 (ss)
RUN apk add --no-cache \
    socat \
    openssh-client \
    shadow \
    iproute2

# Create a non-root user
RUN adduser -D -u 1000 -s /bin/sh sshrelay

# Switch to non-root user
USER sshrelay

# Create directories for SSH config and keys (owned by sshrelay)
RUN mkdir -p /home/sshrelay/.ssh && \
    chmod 700 /home/sshrelay/.ssh

# Copy entrypoint and config
COPY --chown=sshrelay:sshrelay entrypoint.sh /entrypoint.sh
COPY --chown=sshrelay:sshrelay tunnels.conf /etc/tunnels.conf

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]