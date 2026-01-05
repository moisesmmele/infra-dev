FROM alpine:latest

# Install dependencies
RUN apk add --no-cache bash curl jq nss

# Install mkcert from the testing repository
RUN apk add --no-cache mkcert --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing

# Set working directory
WORKDIR /app

# The script will be mounted at /init.sh by docker-compose
CMD ["bash", "/init.sh"]