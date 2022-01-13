FROM alpine:latest

RUN apk add --no-cache \
    bash \
    jq \
    git \
    openssh-client

RUN apk add --no-cache hub --repository=http://dl-cdn.alpinelinux.org/alpine/edge/testing

ADD entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
