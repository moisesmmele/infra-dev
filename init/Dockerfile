FROM alpine:latest

# Install dependencies
RUN apk add --no-cache bash curl jq mkcert nss --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community

# Set working directory
WORKDIR /app

# The script will be mounted at /init.sh by docker-compose
CMD ["bash", "/init.sh"]
