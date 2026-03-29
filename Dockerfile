FROM alpine:3.21

# Install only what's needed: socat + openssh client
RUN apk add --no-cache \
    socat \
    openssh-client \
    shadow  # for user management if needed

# Create a non-root user for better security (recommended)
RUN adduser -D -u 1000 -s /bin/sh sshbridge

# Switch to non-root user
USER sshbridge

# Create directories for SSH config and keys (owned by sshbridge)
RUN mkdir -p /home/sshbridge/.ssh && \
    chmod 700 /home/sshbridge/.ssh

# Copy entrypoint and config
COPY --chown=sshbridge:sshbridge entrypoint.sh /entrypoint.sh
COPY --chown=sshbridge:sshbridge tunnels.conf /etc/tunnels.conf

RUN chmod +x /entrypoint.sh

# Expose nothing by default — we bind dynamically inside the container
#EXPOSE 10000-11000   # Optional: document the range you plan to use (adjust as needed)
EXPOSE 10001-10003

ENTRYPOINT ["/entrypoint.sh"]