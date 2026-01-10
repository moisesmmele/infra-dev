FROM alpine:latest

# Install dependencies
RUN apk add --no-cache bash curl jq nss

# Install mkcert from the testing repository
RUN apk add --no-cache mkcert --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing