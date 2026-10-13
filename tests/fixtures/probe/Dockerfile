FROM python:3.15-alpine@sha256:1afb480ba8d3b3b7a8439a84f2365ce5c75ac45a79cf07daa091b49235cbe27b

WORKDIR /app
COPY probe.py /app/probe.py

EXPOSE 53/udp 8080/tcp
ENTRYPOINT ["python", "/app/probe.py"]
