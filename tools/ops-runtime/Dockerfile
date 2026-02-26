FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends git jq gh ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
