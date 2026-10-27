FROM python:3.15-alpine@sha256:1b0796bb3b4390ceb717d9231fa2c4ee584948473724ad7ae252aa9bc2125c7e

WORKDIR /app
COPY probe.py /app/probe.py

EXPOSE 53/udp 8080/tcp
ENTRYPOINT ["python", "/app/probe.py"]
